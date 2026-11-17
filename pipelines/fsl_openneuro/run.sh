#!/usr/bin/env bash
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${PIPELINE_DIR}/../.." && pwd)"

# shellcheck source=config.env
source "${PIPELINE_DIR}/config.env"

MODE="check"
TASK="${DEFAULT_TASK}"
RUN_ID="${DEFAULT_RUN}"
JOBS="${DEFAULT_JOBS}"
DATASET_SELECTOR=""
INTERNAL_WORKER=0
WORKER_DATASET=""

usage() {
  printf '%s\n' \
    "Usage: ./run.sh [--check|--prepare|--execute] [--task LABEL] [--run ID] [--jobs N] [--dataset dsXXXXXX]" \
    "" \
    "  --check     Validate inputs and metadata; write nothing (default)." \
    "  --prepare   Create a T1 brain extraction, slice timings, and FEAT design." \
    "  --execute   Prepare, run FEAT, then create the standard-space 4D image." \
    "  --task      BIDS task label: 6cat or pRF for this localizer session." \
    "  --run       BIDS run label: 01 or 02 for this localizer session." \
    "  --jobs      Maximum concurrent datasets (default: ${DEFAULT_JOBS})." \
    "  --dataset   Process one dsXXXXXX directory instead of every match." \
    "  --list-tasks  Explain the task labels without running anything."
}

print_tasks() {
  printf '%s\n' \
    "Tasks supported by this configured pipeline:" \
    "  6cat  Six-category functional localizer (body parts, faces, objects," \
    "        scenes, scrambled images, and words)." \
    "  pRF   Population receptive-field/retinotopic mapping task." \
    "" \
    "Other task labels present elsewhere in ds004192:" \
    "  things  Main THINGS object-image experiment in ses-thingsXX." \
    "  rest    No-stimulus acquisition; localizer files use acq-reversePE." \
    "" \
    "TR is a scan parameter, not a task. The selected runs have TR=1.5 s."
}

while (($#)); do
  case "$1" in
    --check) MODE="check"; shift ;;
    --prepare) MODE="prepare"; shift ;;
    --execute) MODE="execute"; shift ;;
    --task) TASK="${2:?--task requires a value}"; shift 2 ;;
    --run) RUN_ID="${2:?--run requires a value}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
    --dataset) DATASET_SELECTOR="${2:?--dataset requires a value}"; shift 2 ;;
    --list-tasks) MODE="list-tasks"; shift ;;
    --internal-worker) INTERNAL_WORKER=1; shift ;;
    --dataset-path) WORKER_DATASET="${2:?--dataset-path requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${MODE}" == "list-tasks" ]]; then
  print_tasks
  exit 0
fi

case "${TASK}" in
  6cat|pRF) ;;
  *)
    printf 'ERROR: Unsupported task for %s: %s\n' "${SESSION}" "${TASK}" >&2
    printf 'Use --task 6cat or --task pRF. TR is not a task label.\n' >&2
    printf 'Run ./run.sh --list-tasks for an explanation.\n' >&2
    exit 2
    ;;
esac

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'ERROR: --jobs must be a positive integer.\n' >&2
  exit 2
}

if [[ "${INTERNAL_WORKER}" -eq 0 ]]; then
  if [[ ! -d "${DATASET_ROOT}" ]]; then
    printf 'ERROR: OpenNeuro dataset root is unavailable: %s\n' "${DATASET_ROOT}" >&2
    exit 1
  fi

  DATASET_DIRS=()
  if [[ -n "${DATASET_SELECTOR}" ]]; then
    if [[ ! "${DATASET_SELECTOR}" =~ ^ds[0-9]{6}$ ]]; then
      printf 'ERROR: --dataset must match ds followed by exactly six digits.\n' >&2
      exit 2
    fi
    if [[ ! -d "${DATASET_ROOT}/${DATASET_SELECTOR}" ]]; then
      printf 'ERROR: Dataset is unavailable: %s/%s\n' "${DATASET_ROOT}" "${DATASET_SELECTOR}" >&2
      exit 1
    fi
    DATASET_DIRS+=("${DATASET_ROOT}/${DATASET_SELECTOR}")
  else
    for candidate in "${DATASET_ROOT}"/ds??????; do
      [[ -d "${candidate}" ]] || continue
      candidate_name="$(basename "${candidate}")"
      [[ "${candidate_name}" =~ ^ds[0-9]{6}$ ]] || continue
      DATASET_DIRS+=("${candidate}")
    done
  fi

  if [[ "${#DATASET_DIRS[@]}" -eq 0 ]]; then
    printf 'ERROR: No immediate ds[0-9]{6} directories found under %s\n' "${DATASET_ROOT}" >&2
    exit 1
  fi

  printf 'Discovered %s OpenNeuro dataset(s); rolling concurrency=%s\n' \
    "${#DATASET_DIRS[@]}" "${JOBS}"
  MODE_FLAG="--${MODE}"
  if printf '%s\0' "${DATASET_DIRS[@]}" | \
    xargs -0 -n 1 -P "${JOBS}" \
      "${PIPELINE_DIR}/run.sh" --internal-worker "${MODE_FLAG}" \
      --task "${TASK}" --run "${RUN_ID}" --dataset-path; then
    printf 'All selected OpenNeuro workers completed successfully.\n'
    exit 0
  else
    printf 'ERROR: One or more OpenNeuro workers failed.\n' >&2
    exit 1
  fi
fi

if [[ -z "${WORKER_DATASET}" ]]; then
  printf 'ERROR: Internal worker has no dataset path.\n' >&2
  exit 1
fi
DATASET_ID="$(basename "${WORKER_DATASET}")"
if [[ ! "${DATASET_ID}" =~ ^ds[0-9]{6}$ || ! -d "${WORKER_DATASET}" ]]; then
  printf 'ERROR: Invalid worker dataset directory: %s\n' "${WORKER_DATASET}" >&2
  exit 1
fi
DATASET_OUTPUT_ROOT="${OUTPUT_ROOT}/${DATASET_ID}"

if [[ -z "${FSLDIR:-}" ]]; then
  FSL_COMMAND="$(command -v fsl || true)"
  if [[ -z "${FSL_COMMAND}" ]]; then
    printf 'ERROR: FSLDIR is not set. Source your FSL configuration first.\n' >&2
    exit 1
  fi
  FSL_BIN_DIR="$(cd "$(dirname "${FSL_COMMAND}")" && pwd)"
  if [[ "${FSL_BIN_DIR}" == */share/fsl/bin ]]; then
    export FSLDIR="${FSL_BIN_DIR%/share/fsl/bin}"
  else
    printf 'ERROR: Cannot infer FSLDIR from %s. Source your FSL configuration first.\n' \
      "${FSL_COMMAND}" >&2
    exit 1
  fi
elif [[ "${FSLDIR}" == */share/fsl/bin ]]; then
  export FSLDIR="${FSLDIR%/share/fsl/bin}"
fi
export PATH="${FSLDIR}/share/fsl/bin:${FSLDIR}/bin:${PATH}"
export FSLOUTPUTTYPE="NIFTI_GZ"
export OMP_NUM_THREADS="${THREADS_PER_WORKER}"
export OPENBLAS_NUM_THREADS="${THREADS_PER_WORKER}"
export MKL_NUM_THREADS="${THREADS_PER_WORKER}"

if [[ -z "${DENO_BIN:-}" ]]; then
  DENO_BIN="$(command -v deno || true)"
  if [[ -z "${DENO_BIN}" ]]; then
    printf 'ERROR: Deno is unavailable. Set DENO_BIN or add deno to PATH.\n' >&2
    exit 1
  fi
  export DENO_BIN
fi

for executable in fslval bet feat applywarp; do
  if ! command -v "${executable}" >/dev/null 2>&1; then
    printf 'ERROR: Required FSL command is unavailable: %s\n' "${executable}" >&2
    exit 1
  fi
done

BOLD_STEM="${SUBJECT}_${SESSION}_task-${TASK}_run-${RUN_ID}_bold"
BOLD_FILE="${WORKER_DATASET}/${SUBJECT}/${SESSION}/func/${BOLD_STEM}.nii.gz"
BOLD_JSON="${WORKER_DATASET}/${SUBJECT}/${SESSION}/func/${BOLD_STEM}.json"
T1_HEAD_SOURCE="${WORKER_DATASET}/${T1W_RELATIVE_PATH}"

require_payload() {
  local target="$1"
  if [[ ! -e "${target}" ]]; then
    printf 'ERROR: Required payload is unavailable: %s\n' "${target}" >&2
    if [[ -L "${target}" ]]; then
      printf 'The Git-annex link exists, but its content has not been retrieved.\n' >&2
    fi
    exit 1
  fi
}

require_payload "${BOLD_FILE}"
require_payload "${BOLD_JSON}"
require_payload "${T1_HEAD_SOURCE}"

DIM1="$(fslval "${BOLD_FILE}" dim1)"
DIM2="$(fslval "${BOLD_FILE}" dim2)"
DIM3="$(fslval "${BOLD_FILE}" dim3)"
DIM4="$(fslval "${BOLD_FILE}" dim4)"
HEADER_TR="$(fslval "${BOLD_FILE}" pixdim4)"

printf '[%s] Input check passed\n' "${DATASET_ID}"
printf '  BOLD: %s\n' "${BOLD_FILE}"
printf '  T1:   %s\n' "${T1_HEAD_SOURCE}"
printf '  Size: %sx%sx%sx%s; header TR=%ss\n' "${DIM1}" "${DIM2}" "${DIM3}" "${DIM4}" "${HEADER_TR}"
printf '  Processing: MCFLIRT, slice timing, BET, %smm smoothing, %ss high-pass, BBR, FNIRT\n' \
  "${SMOOTH_FWHM_MM}" "$(awk -v hz="${HIGHPASS_HZ}" 'BEGIN { print 1 / hz }')"

if [[ "${MODE}" == "check" ]]; then
  exit 0
fi

ANAT_WORK="${DATASET_OUTPUT_ROOT}/work/${SUBJECT}/${SESSION}/anat"
DESIGN_DIR="${DATASET_OUTPUT_ROOT}/designs/${SUBJECT}/${SESSION}"
RESULTS_DIR="${DATASET_OUTPUT_ROOT}/${SUBJECT}/${SESSION}/func"
mkdir -p "${ANAT_WORK}" "${DESIGN_DIR}" "${RESULTS_DIR}"

T1_NAME="$(basename "${T1_HEAD_SOURCE}")"
T1_BASE="${T1_NAME%.nii.gz}"
T1_WORK_HEAD="${ANAT_WORK}/${T1_BASE}.nii.gz"
T1_WORK_BRAIN="${ANAT_WORK}/${T1_BASE}_brain.nii.gz"

if [[ ! -e "${T1_WORK_HEAD}" && ! -L "${T1_WORK_HEAD}" ]]; then
  ln -s "${T1_HEAD_SOURCE}" "${T1_WORK_HEAD}"
elif [[ ! -e "${T1_WORK_HEAD}" ]]; then
  printf 'ERROR: Existing T1 work link is broken; refusing to replace it: %s\n' "${T1_WORK_HEAD}" >&2
  exit 1
fi

if [[ ! -e "${T1_WORK_BRAIN}" ]]; then
  printf 'Running structural BET...\n'
  bet "${T1_WORK_HEAD}" "${T1_WORK_BRAIN}" -R \
    -f "${BET_FRACTIONAL_INTENSITY}" -g "${BET_VERTICAL_GRADIENT}" -m
else
  printf 'Reusing existing brain-extracted T1: %s\n' "${T1_WORK_BRAIN}"
fi

DESIGN_FILE="${DESIGN_DIR}/${BOLD_STEM}.fsf"
SLICE_FILE="${DESIGN_DIR}/${BOLD_STEM}_slice-timing.txt"
FEAT_DIR="${RESULTS_DIR}/${BOLD_STEM}.feat"

if [[ ! -e "${DESIGN_FILE}" && ! -e "${SLICE_FILE}" ]]; then
  "${DENO_BIN}" run --allow-read --allow-write --allow-run --allow-env=FSLDIR \
    "${PIPELINE_DIR}/build_design.ts" \
    --bold "${BOLD_FILE}" \
    --metadata "${BOLD_JSON}" \
    --t1-brain "${T1_WORK_BRAIN}" \
    --template "${PIPELINE_DIR}/preprocessing.fsf.template" \
    --design-output "${DESIGN_FILE}" \
    --slice-output "${SLICE_FILE}" \
    --feat-output "${FEAT_DIR}" \
    --smooth-fwhm "${SMOOTH_FWHM_MM}" \
    --highpass-hz "${HIGHPASS_HZ}" \
    --fnirt-warp-resolution "${FNIRT_WARP_RESOLUTION_MM}" \
    --delete-volumes "${DELETE_VOLUMES}"
elif [[ ! -e "${DESIGN_FILE}" || ! -e "${SLICE_FILE}" ]]; then
  printf 'ERROR: Only one generated design file exists; refusing to replace either file.\n' >&2
  exit 1
else
  printf 'Reusing existing FEAT design: %s\n' "${DESIGN_FILE}"
fi

printf 'Prepared\n'
printf '  Design:       %s\n' "${DESIGN_FILE}"
printf '  Slice timing: %s\n' "${SLICE_FILE}"
printf '  T1 brain:     %s\n' "${T1_WORK_BRAIN}"

if [[ "${MODE}" == "prepare" ]]; then
  exit 0
fi

if [[ -e "${FEAT_DIR}" || -L "${FEAT_DIR}" ]]; then
  printf 'ERROR: FEAT output already exists; refusing to overwrite or remove it: %s\n' "${FEAT_DIR}" >&2
  exit 1
fi

printf 'Starting FEAT...\n'
feat "${DESIGN_FILE}"

REPORT_FILE="${FEAT_DIR}/report.html"
DEADLINE=$((SECONDS + MAX_WAIT_HOURS * 3600))
LAST_UPDATE=0
while true; do
  if [[ -f "${REPORT_FILE}" ]] && grep -q 'Finished at' "${REPORT_FILE}"; then
    break
  fi
  if ((SECONDS >= DEADLINE)); then
    printf 'ERROR: Timed out waiting for FEAT after %s hours. Output was preserved at %s\n' \
      "${MAX_WAIT_HOURS}" "${FEAT_DIR}" >&2
    exit 1
  fi
  if ((SECONDS - LAST_UPDATE >= 60)); then
    printf 'Still waiting for FEAT: %s\n' "${FEAT_DIR}"
    LAST_UPDATE=${SECONDS}
  fi
  sleep 10
done

if grep -qiE 'Errors occured|FATAL ERROR' "${REPORT_FILE}" "${FEAT_DIR}/report_log.html" 2>/dev/null; then
  printf 'ERROR: FEAT reported an error. Inspect %s/report_log.html\n' "${FEAT_DIR}" >&2
  exit 1
fi

FILTERED="${FEAT_DIR}/filtered_func_data.nii.gz"
FUNC_TO_T1="${FEAT_DIR}/reg/example_func2highres.mat"
T1_TO_STANDARD="${FEAT_DIR}/reg/highres2standard_warp.nii.gz"
STANDARD_REF="${FEAT_DIR}/reg/standard.nii.gz"
STANDARD_4D="${FEAT_DIR}/filtered_func_data_standard.nii.gz"

for required in "${FILTERED}" "${FUNC_TO_T1}" "${T1_TO_STANDARD}" "${STANDARD_REF}"; do
  require_payload "${required}"
done
if [[ -e "${STANDARD_4D}" || -L "${STANDARD_4D}" ]]; then
  printf 'ERROR: Standard-space output already exists; refusing to overwrite it: %s\n' "${STANDARD_4D}" >&2
  exit 1
fi

printf 'Applying the BBR and FNIRT transforms to the preprocessed 4D series...\n'
applywarp \
  --ref="${STANDARD_REF}" \
  --in="${FILTERED}" \
  --out="${STANDARD_4D}" \
  --premat="${FUNC_TO_T1}" \
  --warp="${T1_TO_STANDARD}" \
  --interp=trilinear

EXPECTED_VOLUMES=$((DIM4 - DELETE_VOLUMES))
ACTUAL_VOLUMES="$(fslval "${STANDARD_4D}" dim4)"
if [[ "${ACTUAL_VOLUMES}" -ne "${EXPECTED_VOLUMES}" ]]; then
  printf 'ERROR: Standard-space output has %s volumes; expected %s. Output was preserved.\n' \
    "${ACTUAL_VOLUMES}" "${EXPECTED_VOLUMES}" >&2
  exit 1
fi

printf 'Completed successfully\n'
printf '  Native preprocessed 4D:   %s\n' "${FILTERED}"
printf '  Standard-space 4D:        %s\n' "${STANDARD_4D}"
printf '  FEAT/QC report:           %s\n' "${FEAT_DIR}/report.html"
