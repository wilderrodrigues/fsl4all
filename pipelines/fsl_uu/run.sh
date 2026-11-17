#!/usr/bin/env bash
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${PIPELINE_DIR}/../.." && pwd)"

# shellcheck source=config.env
source "${PIPELINE_DIR}/config.env"

MODE="check"
JOBS="${DEFAULT_JOBS}"
DATASET_ROOT_OVERRIDE=""
OUTPUT_RELATIVE=""
INTERNAL_WORKER=0
WORKER_ARCHIVE=""
RESOLVED_OUTPUT_ROOT=""
BATCH_DIR=""

usage() {
  printf '%s\n' \
    "Usage: ./run.sh [--check|--prepare|--execute] [--dataset-root PATH] --output REL_PATH [--jobs N]" \
    "" \
    "  --check          Validate the selected source archives; write nothing." \
    "  --prepare        Stage inputs, run T1 BET, and create a FEAT design." \
    "  --execute        Prepare, run FEAT, then create the MNI152 4D image." \
    "  --dataset-root   Archive directory/root; overrides DATASET_ROOT from config.env." \
    "  --output         Mandatory relative path beneath OUTPUT_ROOT." \
    "  --jobs           Maximum concurrent archives (default: ${DEFAULT_JOBS})." \
    "" \
    "The source metadata has no SliceTiming. See config.env and README.md."
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

require_file() {
  [[ -f "$1" ]] || fail "Required file is unavailable: $1"
}

unique_archive_member() {
  local archive="$1"
  local pattern="$2"
  local description="$3"
  local members
  local count

  members="$(tar -tzf "${archive}" | awk -v pattern="${pattern}" '$0 ~ pattern { print }')"
  count="$(printf '%s\n' "${members}" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "${count}" -ne 1 ]]; then
    fail "Expected exactly one ${description} in ${archive}; found ${count}"
  fi
  printf '%s\n' "${members}"
}

find_deno() {
  if [[ -z "${DENO_BIN:-}" ]]; then
    DENO_BIN="$(command -v deno || true)"
  fi
  [[ -n "${DENO_BIN:-}" && -x "${DENO_BIN}" ]] || \
    fail "Deno is unavailable. Set DENO_BIN or add deno to PATH."
  export DENO_BIN
}

setup_fsl() {
  local fsl_command
  local fsl_bin_dir

  if [[ -z "${FSLDIR:-}" ]]; then
    fsl_command="$(command -v fsl || true)"
    [[ -n "${fsl_command}" ]] || \
      fail "FSLDIR is not set and the fsl launcher is not available on PATH."
    fsl_bin_dir="$(cd "$(dirname "${fsl_command}")" && pwd)"
    case "${fsl_bin_dir}" in
      */share/fsl/bin) export FSLDIR="${fsl_bin_dir%/share/fsl/bin}" ;;
      *) fail "Cannot infer FSLDIR from ${fsl_command}; source the FSL configuration first." ;;
    esac
  elif [[ "${FSLDIR}" == */share/fsl/bin ]]; then
    export FSLDIR="${FSLDIR%/share/fsl/bin}"
  fi
  export PATH="${FSLDIR}/share/fsl/bin:${FSLDIR}/bin:${PATH}"
  export FSLOUTPUTTYPE="NIFTI_GZ"
  export OMP_NUM_THREADS="${THREADS_PER_WORKER}"
  export OPENBLAS_NUM_THREADS="${THREADS_PER_WORKER}"
  export MKL_NUM_THREADS="${THREADS_PER_WORKER}"

  local executable
  for executable in fslval bet feat applywarp; do
    command -v "${executable}" >/dev/null 2>&1 || \
      fail "Required FSL command is unavailable: ${executable}"
  done
}

validate_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || fail "$2 must be a positive integer"
}

validate_relative_output() {
  local value="$1"
  local component
  local old_ifs

  [[ -n "${value}" ]] || fail "--output is mandatory"
  [[ "${value}" != /* ]] || fail "--output must be relative, not absolute"
  [[ "${value}" != "." && "${value}" != ".." ]] || \
    fail "--output must name a directory beneath OUTPUT_ROOT"
  old_ifs="${IFS}"
  IFS='/'
  read -r -a output_components <<< "${value}"
  IFS="${old_ifs}"
  for component in "${output_components[@]}"; do
    [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] || \
      fail "--output contains an empty, current-directory, or parent-directory component"
  done
}

resolve_directory() {
  local directory="$1"
  local description="$2"
  [[ -d "${directory}" ]] || fail "${description} is unavailable: ${directory}"
  (cd "${directory}" && pwd -P)
}

parse_archive_identity() {
  local archive="$1"
  local filename
  local raw_task

  filename="$(basename "${archive}")"
  if [[ ! "${filename}" =~ ^(A[0-9]{5})_([0-9]+y)_([[:alnum:]]+mriscan)_([0-9]{8})_verNifti\.(tgz|tar\.gz)$ ]]; then
    fail "Unsupported UU archive name: ${filename}"
  fi
  SUBJECT_ID="${BASH_REMATCH[1]}"
  AGE_LABEL="${BASH_REMATCH[2]}"
  SOURCE_SERIES="${BASH_REMATCH[3]}"
  SCAN_DATE="${BASH_REMATCH[4]}"
  raw_task="${SOURCE_SERIES%mriscan}"
  TASK_LABEL="$(printf '%s' "${raw_task}" | tr '[:upper:]' '[:lower:]')"
  SUBJECT_LABEL="sub-${SUBJECT_ID}"
  SESSION_LABEL="ses-${AGE_LABEL}"
  BOLD_STEM="${SUBJECT_LABEL}_${SESSION_LABEL}_task-${TASK_LABEL}_acq-${SCAN_DATE}_bold"
  ARCHIVE_KEY="${filename%.tar.gz}"
  ARCHIVE_KEY="${ARCHIVE_KEY%.tgz}"
}

stage_nifti() {
  local archive="$1"
  local member="$2"
  local target="$3"
  case "${member}" in
    *.nii.gz) tar -xOf "${archive}" "${member}" > "${target}" ;;
    *.nii) tar -xOf "${archive}" "${member}" | gzip -c > "${target}" ;;
    *) fail "Unsupported NIfTI archive member: ${member}" ;;
  esac
}

find_t1_source() {
  local functional_archive="$1"
  local functional_dir
  local search_root
  local candidate
  local candidate_name
  local members
  local member_count
  local candidates=()
  local candidate_members=()

  functional_dir="$(dirname "${functional_archive}")"
  for search_root in "${functional_dir}" "$(dirname "${functional_dir}")"; do
    candidates=()
    candidate_members=()
    while IFS= read -r candidate; do
      candidate_name="$(basename "${candidate}")"
      [[ "${candidate_name}" == *"${SUBJECT_ID}"* ]] || continue
      [[ "${candidate_name}" == *"${AGE_LABEL}"* ]] || continue
      members="$(tar -tzf "${candidate}" | awk '
        tolower($0) ~ /(^|\/)[^\/]*(t1w|t1|anatom|struct)[^\/]*\.nii(\.gz)?$/ { print }
      ')"
      member_count="$(printf '%s\n' "${members}" | \
        awk 'NF { count += 1 } END { print count + 0 }')"
      if [[ "${member_count}" -gt 1 ]]; then
        fail "Archive contains multiple possible T1 images: ${candidate}"
      elif [[ "${member_count}" -eq 1 ]]; then
        candidates+=("${candidate}")
        candidate_members+=("${members}")
      fi
    done < <(find "${search_root}" -type f \
      \( -name '*.tgz' -o -name '*.tar.gz' \) -print | LC_ALL=C sort)

    if [[ "${#candidates[@]}" -eq 1 ]]; then
      T1_ARCHIVE="${candidates[0]}"
      T1_MEMBER="${candidate_members[0]}"
      return 0
    elif [[ "${#candidates[@]}" -gt 1 ]]; then
      fail "Expected one T1 archive for ${SUBJECT_ID}/${AGE_LABEL} near ${functional_dir}; found ${#candidates[@]}"
    fi
  done

  fail "No T1 archive found for ${SUBJECT_ID}/${AGE_LABEL} near ${functional_dir}"
}

process_archive() {
  local functional_archive="$1"
  local bold_pattern
  local json_pattern
  local bold_member
  local bold_json_member
  local metadata_summary
  local scope_dir
  local staged_anat_dir staged_func_dir staged_t1 staged_bold staged_json
  local staged_count staged_file
  local dim1 dim2 dim3 dim4 header_tr
  local anat_work design_dir results_dir t1_stem t1_work_brain
  local design_file slice_file feat_dir slice_file_required
  local custom_timing_path
  local report_file deadline last_update
  local filtered func_to_t1 t1_to_standard standard_ref standard_4d
  local required_output expected_output_volumes actual_volumes

  require_file "${functional_archive}"
  parse_archive_identity "${functional_archive}"
  find_deno
  tar -tzf "${functional_archive}" >/dev/null

  bold_pattern="(^|/)_?${SOURCE_SERIES}_[^/]*\\.nii(\\.gz)?$"
  json_pattern="(^|/)_?${SOURCE_SERIES}_[^/]*\\.json$"
  bold_member="$(unique_archive_member "${functional_archive}" "${bold_pattern}" 'functional NIfTI')"
  bold_json_member="$(unique_archive_member "${functional_archive}" "${json_pattern}" 'functional JSON')"
  find_t1_source "${functional_archive}"

  metadata_summary="$(
    tar -xOf "${functional_archive}" "${bold_json_member}" | \
      "${DENO_BIN}" eval '
        const text = await new Response(Deno.stdin.readable).text();
        const data = JSON.parse(text);
        console.log(`TR=${data.RepetitionTime ?? "missing"}s; TE=${data.EchoTime ?? "missing"}s; series=${data.SeriesDescription ?? "missing"}; SliceTiming=${Array.isArray(data.SliceTiming) ? data.SliceTiming.length + " entries" : "missing"}`);
      '
  )"

  printf '[%s] Source check passed\n' "${ARCHIVE_KEY}"
  printf '[%s] Functional archive: %s\n' "${ARCHIVE_KEY}" "${functional_archive}"
  printf '[%s] T1 archive:         %s\n' "${ARCHIVE_KEY}" "${T1_ARCHIVE}"
  printf '[%s] Metadata: %s\n' "${ARCHIVE_KEY}" "${metadata_summary}"
  if [[ "${SLICE_TIMING_MODE}" == "none" ]]; then
    printf '[%s] WARNING: slice-timing correction is disabled.\n' "${ARCHIVE_KEY}"
  fi

  if [[ "${MODE}" == "check" ]]; then
    return 0
  fi

  setup_fsl
  scope_dir="${SUBJECT_LABEL}/${SESSION_LABEL}/task-${TASK_LABEL}/acq-${SCAN_DATE}"
  staged_anat_dir="${RESOLVED_OUTPUT_ROOT}/staged/${scope_dir}/anat"
  staged_func_dir="${RESOLVED_OUTPUT_ROOT}/staged/${scope_dir}/func"
  staged_t1="${staged_anat_dir}/${SUBJECT_LABEL}_${SESSION_LABEL}_T1w.nii.gz"
  staged_bold="${staged_func_dir}/${BOLD_STEM}.nii.gz"
  staged_json="${staged_func_dir}/${BOLD_STEM}.json"

  staged_count=0
  for staged_file in "${staged_t1}" "${staged_bold}" "${staged_json}"; do
    if path_exists "${staged_file}"; then
      staged_count=$((staged_count + 1))
    fi
  done
  if [[ "${staged_count}" -eq 0 ]]; then
    mkdir -p "${staged_anat_dir}" "${staged_func_dir}"
    stage_nifti "${T1_ARCHIVE}" "${T1_MEMBER}" "${staged_t1}"
    stage_nifti "${functional_archive}" "${bold_member}" "${staged_bold}"
    tar -xOf "${functional_archive}" "${bold_json_member}" > "${staged_json}"
  elif [[ "${staged_count}" -eq 3 ]]; then
    printf '[%s] Reusing complete staged inputs.\n' "${ARCHIVE_KEY}"
  else
    fail "Only ${staged_count} of 3 staged inputs exist for ${ARCHIVE_KEY}; refusing to overwrite any"
  fi
  for staged_file in "${staged_t1}" "${staged_bold}" "${staged_json}"; do
    [[ -s "${staged_file}" ]] || fail "Staged file is missing or empty: ${staged_file}"
  done

  dim1="$(fslval "${staged_bold}" dim1)"
  dim2="$(fslval "${staged_bold}" dim2)"
  dim3="$(fslval "${staged_bold}" dim3)"
  dim4="$(fslval "${staged_bold}" dim4)"
  header_tr="$(fslval "${staged_bold}" pixdim4)"
  printf '[%s] Staged BOLD: %sx%sx%sx%s; TR=%ss\n' \
    "${ARCHIVE_KEY}" "${dim1}" "${dim2}" "${dim3}" "${dim4}" "${header_tr}"

  anat_work="${RESOLVED_OUTPUT_ROOT}/work/${scope_dir}/anat"
  design_dir="${RESOLVED_OUTPUT_ROOT}/designs/${scope_dir}"
  results_dir="${RESOLVED_OUTPUT_ROOT}/${SUBJECT_LABEL}/${SESSION_LABEL}/func"
  mkdir -p "${anat_work}" "${design_dir}" "${results_dir}"

  t1_stem="${SUBJECT_LABEL}_${SESSION_LABEL}_T1w"
  t1_work_brain="${anat_work}/${t1_stem}_brain.nii.gz"
  if ! path_exists "${t1_work_brain}"; then
    printf '[%s] Running structural BET...\n' "${ARCHIVE_KEY}"
    bet "${staged_t1}" "${t1_work_brain}" -R \
      -f "${BET_FRACTIONAL_INTENSITY}" -g "${BET_VERTICAL_GRADIENT}" -m
  else
    [[ -s "${t1_work_brain}" ]] || fail "Existing T1 brain output is empty: ${t1_work_brain}"
  fi

  design_file="${design_dir}/${BOLD_STEM}.fsf"
  slice_file="${design_dir}/${BOLD_STEM}_slice-timing.txt"
  feat_dir="${results_dir}/${BOLD_STEM}.feat"
  slice_file_required=0
  if [[ "${SLICE_TIMING_MODE}" == "metadata" || "${SLICE_TIMING_MODE}" == "custom" ]]; then
    slice_file_required=1
  fi

  if ! path_exists "${design_file}"; then
    path_exists "${slice_file}" && \
      fail "Slice-timing output exists without a design: ${slice_file}"
    BUILD_ARGS=(
      --bold "${staged_bold}"
      --metadata "${staged_json}"
      --t1-brain "${t1_work_brain}"
      --template "${PIPELINE_DIR}/preprocessing.fsf.template"
      --design-output "${design_file}"
      --slice-output "${slice_file}"
      --feat-output "${feat_dir}"
      --slice-timing-mode "${SLICE_TIMING_MODE}"
      --smooth-fwhm "${SMOOTH_FWHM_MM}"
      --highpass-hz "${HIGHPASS_HZ}"
      --fnirt-warp-resolution "${FNIRT_WARP_RESOLUTION_MM}"
      --delete-volumes "${DELETE_VOLUMES}"
    )
    if [[ "${SLICE_TIMING_MODE}" == "custom" ]]; then
      [[ -n "${CUSTOM_SLICE_TIMING_FILE}" ]] || \
        fail "SLICE_TIMING_MODE=custom requires CUSTOM_SLICE_TIMING_FILE"
      custom_timing_path="${CUSTOM_SLICE_TIMING_FILE}"
      [[ "${custom_timing_path}" == /* ]] || \
        custom_timing_path="${PIPELINE_DIR}/${custom_timing_path}"
      BUILD_ARGS+=(--custom-slice-timing "${custom_timing_path}")
    fi
    "${DENO_BIN}" run --allow-read --allow-write --allow-run --allow-env=FSLDIR \
      "${PIPELINE_DIR}/build_design.ts" "${BUILD_ARGS[@]}"
  else
    grep -Fq "# Slice timing mode: ${SLICE_TIMING_MODE}" "${design_file}" || \
      fail "Existing design uses different slice-timing settings: ${design_file}"
    if [[ "${slice_file_required}" -eq 1 ]] && ! path_exists "${slice_file}"; then
      fail "Generated slice-timing file is missing: ${slice_file}"
    fi
  fi

  printf '[%s] Prepared: %s\n' "${ARCHIVE_KEY}" "${design_file}"
  if [[ "${MODE}" == "prepare" ]]; then
    return 0
  fi

  path_exists "${feat_dir}" && \
    fail "FEAT output already exists; refusing to overwrite it: ${feat_dir}"
  printf '[%s] Starting FEAT...\n' "${ARCHIVE_KEY}"
  feat "${design_file}"

  report_file="${feat_dir}/report.html"
  deadline=$((SECONDS + MAX_WAIT_HOURS * 3600))
  last_update=0
  while true; do
    if [[ -f "${report_file}" ]] && grep -q 'Finished at' "${report_file}"; then
      break
    fi
    if ((SECONDS >= deadline)); then
      fail "Timed out waiting for FEAT after ${MAX_WAIT_HOURS} hours: ${feat_dir}"
    fi
    if ((SECONDS - last_update >= 60)); then
      printf '[%s] Still waiting for FEAT...\n' "${ARCHIVE_KEY}"
      last_update=${SECONDS}
    fi
    sleep 10
  done
  if grep -qiE 'Errors occurred|Errors occured|FATAL ERROR' \
    "${report_file}" "${feat_dir}/report_log.html" 2>/dev/null; then
    fail "FEAT reported an error. Inspect ${feat_dir}/report_log.html"
  fi

  filtered="${feat_dir}/filtered_func_data.nii.gz"
  func_to_t1="${feat_dir}/reg/example_func2highres.mat"
  t1_to_standard="${feat_dir}/reg/highres2standard_warp.nii.gz"
  standard_ref="${feat_dir}/reg/standard.nii.gz"
  standard_4d="${feat_dir}/filtered_func_data_standard.nii.gz"
  for required_output in "${filtered}" "${func_to_t1}" "${t1_to_standard}" "${standard_ref}"; do
    [[ -s "${required_output}" ]] || fail "Expected FEAT output is unavailable: ${required_output}"
  done
  path_exists "${standard_4d}" && \
    fail "Standard-space output already exists: ${standard_4d}"

  applywarp \
    --ref="${standard_ref}" \
    --in="${filtered}" \
    --out="${standard_4d}" \
    --premat="${func_to_t1}" \
    --warp="${t1_to_standard}" \
    --interp=trilinear

  expected_output_volumes=$((dim4 - DELETE_VOLUMES))
  actual_volumes="$(fslval "${standard_4d}" dim4)"
  [[ "${actual_volumes}" -eq "${expected_output_volumes}" ]] || \
    fail "Standard-space output has ${actual_volumes} volumes; expected ${expected_output_volumes}"
  printf '[%s] Completed successfully: %s\n' "${ARCHIVE_KEY}" "${standard_4d}"
}

run_internal_worker() {
  local log_file
  local status_prefix
  local worker_exit

  parse_archive_identity "${WORKER_ARCHIVE}"
  if [[ -z "${BATCH_DIR}" ]]; then
    process_archive "${WORKER_ARCHIVE}"
    return
  fi

  log_file="${BATCH_DIR}/logs/${ARCHIVE_KEY}.log"
  status_prefix="${BATCH_DIR}/status/${ARCHIVE_KEY}"
  if (process_archive "${WORKER_ARCHIVE}") >"${log_file}" 2>&1; then
    printf 'success\n' > "${status_prefix}.success"
    return 0
  else
    worker_exit=$?
    printf 'exit_code=%s\n' "${worker_exit}" > "${status_prefix}.failed"
    return "${worker_exit}"
  fi
}

while (($#)); do
  case "$1" in
    --check) MODE="check"; shift ;;
    --prepare) MODE="prepare"; shift ;;
    --execute) MODE="execute"; shift ;;
    --dataset-root) DATASET_ROOT_OVERRIDE="${2:?--dataset-root requires a value}"; shift 2 ;;
    --output) OUTPUT_RELATIVE="${2:?--output requires a value}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
    --internal-worker) INTERNAL_WORKER=1; shift ;;
    --archive) WORKER_ARCHIVE="${2:?--archive requires a value}"; shift 2 ;;
    --resolved-output-root) RESOLVED_OUTPUT_ROOT="${2:?--resolved-output-root requires a value}"; shift 2 ;;
    --batch-dir) BATCH_DIR="${2:?--batch-dir requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

validate_positive_integer "${JOBS}" "--jobs"
case "${SLICE_TIMING_MODE}" in
  none|regular-up|regular-down|interleaved|metadata|custom) ;;
  *) fail "Invalid SLICE_TIMING_MODE in config.env: ${SLICE_TIMING_MODE}" ;;
esac

if [[ "${INTERNAL_WORKER}" -eq 1 ]]; then
  [[ -n "${WORKER_ARCHIVE}" ]] || fail "Internal worker has no archive path"
  [[ -n "${RESOLVED_OUTPUT_ROOT}" ]] || fail "Internal worker has no resolved output root"
  run_internal_worker
  exit $?
fi

validate_relative_output "${OUTPUT_RELATIVE}"
if [[ -n "${DATASET_ROOT_OVERRIDE}" ]]; then
  RESOLVED_DATASET_ROOT="$(resolve_directory "${DATASET_ROOT_OVERRIDE}" "Dataset root")"
else
  RESOLVED_DATASET_ROOT="$(resolve_directory "${DATASET_ROOT}" "Dataset root")"
fi

RESOLVED_OUTPUT_ROOT="${OUTPUT_ROOT%/}/${OUTPUT_RELATIVE}"

ARCHIVES=()
while IFS= read -r archive; do
  [[ -n "${archive}" ]] || continue
  parse_archive_identity "${archive}"
  ARCHIVES+=("${archive}")
done < <(find "${RESOLVED_DATASET_ROOT}" -type f \
  \( -name 'A*_verNifti.tgz' -o -name 'A*_verNifti.tar.gz' \) -print | LC_ALL=C sort)

[[ "${#ARCHIVES[@]}" -gt 0 ]] || \
  fail "No A#####_<age>_<series>_<date>_verNifti archive files found under ${RESOLVED_DATASET_ROOT}"

WORK_KEYS=()
for archive in "${ARCHIVES[@]}"; do
  parse_archive_identity "${archive}"
  work_key="${SUBJECT_ID}|${AGE_LABEL}|${SOURCE_SERIES}|${SCAN_DATE}"
  for existing_key in "${WORK_KEYS[@]-}"; do
    [[ -n "${existing_key}" ]] || continue
    [[ "${existing_key}" != "${work_key}" ]] || \
      fail "Duplicate subject/series/date input discovered: ${work_key}"
  done
  WORK_KEYS+=("${work_key}")
done

printf 'Discovered %s UU functional archive(s); rolling concurrency=%s\n' \
  "${#ARCHIVES[@]}" "${JOBS}"
printf 'Dataset root: %s\n' "${RESOLVED_DATASET_ROOT}"
printf 'Output root: %s\n' "${RESOLVED_OUTPUT_ROOT}"

MODE_FLAG="--${MODE}"
if [[ "${MODE}" != "check" ]]; then
  BATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  BATCH_DIR="${RESOLVED_OUTPUT_ROOT}/_batches/${BATCH_ID}"
  mkdir -p "${BATCH_DIR}/logs" "${BATCH_DIR}/status"
  printf 'Batch logs: %s\n' "${BATCH_DIR}"
fi

BATCH_EXIT=0
if [[ -n "${BATCH_DIR}" ]]; then
  if ! printf '%s\0' "${ARCHIVES[@]}" | \
    xargs -0 -n 1 -P "${JOBS}" \
      "${PIPELINE_DIR}/run.sh" --internal-worker "${MODE_FLAG}" \
      --resolved-output-root "${RESOLVED_OUTPUT_ROOT}" \
      --batch-dir "${BATCH_DIR}" --archive; then
    BATCH_EXIT=1
  fi
else
  if ! printf '%s\0' "${ARCHIVES[@]}" | \
    xargs -0 -n 1 -P "${JOBS}" \
      "${PIPELINE_DIR}/run.sh" --internal-worker "${MODE_FLAG}" \
      --resolved-output-root "${RESOLVED_OUTPUT_ROOT}" \
      --archive; then
    BATCH_EXIT=1
  fi
fi

if [[ -n "${BATCH_DIR}" ]]; then
  SUCCEEDED="$(find "${BATCH_DIR}/status" -type f -name '*.success' | wc -l | tr -d '[:space:]')"
  FAILED="$(find "${BATCH_DIR}/status" -type f -name '*.failed' | wc -l | tr -d '[:space:]')"
  printf 'Batch complete: %s succeeded, %s failed\n' "${SUCCEEDED}" "${FAILED}"
  if [[ "${FAILED}" -gt 0 ]]; then
    printf 'Failed-worker logs are under %s/logs\n' "${BATCH_DIR}"
    BATCH_EXIT=1
  fi
fi

exit "${BATCH_EXIT}"

