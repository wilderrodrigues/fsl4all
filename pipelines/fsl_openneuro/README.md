# FSL FEAT pre-processing bundle for the OpenNeuro THINGS-fMRI data

This bundle uses [FSL](https://fsl.fmrib.ox.ac.uk/fsl/docs/) to pre-processes the [OpenNeuro THINGS-fMRI dataset](https://openneuro.org/datasets/ds004192/versions/1.0.7/download) downloaded localizers.
One can either download the whole dataset, or simply give the pre-processing script a try with a sub-set first [recommended].

Please, follow the instructions on the OpenNeuro website on how to get the dataset downloaded. If you are a Linux / Mac user,
the snippets below will help you get started with a sub-set of the data:

## Installing Deno/DataLad & Fetching the data

### Installation

* MacOS (if you don't have Home-Brew, please check the official site.)
```shell
brew install datalad
brew install deno
```

* Linux
```shell
sudo apt-get install datalad
curl -fsSL https://deno.land/install.sh | sh
```

The support Windows as well. Please feel free to check that for yourself: [DataLad Installation](https://handbook.datalad.org/en/latest/intro/installation.html)

### Fetching the Data

If you don't want to change the `config.env` file a lot, make sure you fetch the data under `datasets/openneuro`.

```shell
cd datasets/openneuro

datalad clone git@github.com:OpenNeuroDatasets/ds004192.git
```

The data contains symlinks only. This means you will have to fetch the real files after the cloning operation. The command
below does it for a single sub-set.

```shell
datalad get \
  sub-01/ses-localizer1/anat/*_T1w.nii.gz \
  sub-01/ses-localizer1/func/*task-6cat*_bold.nii.gz \
  sub-01/ses-localizer1/func/*task-pRF*_bold.nii.gz
```

The `sub-01` has approximately 1GB of fMRI data read to be used with FSL.

If you want to run experiments with the whole THINGS-fMRI data, please refer to the download script provided by OpenNeuro. 

## Foundational understanding prior to running

### Task, run, session, and TR concepts

The BIDS filenames encode several kinds of information. For example:

```text
sub-01_ses-localizer1_task-6cat_run-01_bold.nii.gz
```

- `sub-01`: participant 01.
- `ses-localizer1`: the first localizer scanning session.
- `task-6cat`: the paradigm performed during the scan.
- `run-01`: the first repetition of that paradigm in this session.
- `bold`: a BOLD-sensitive functional MRI time series.

`TR` means *repetition time*: in functional MRI (fMRI) it is the time interval between consecutive radiofrequency (RF)
excitation pulses applied to the same brain slice, or the time it takes to acquire a full 3D volume of brain images.
These runs have a TR of 1.5 seconds. The script reads it from the BIDS JSON and verifies that it
matches the NIfTI header.

### Which `--task` values can I use?

With the current `config.env`, the valid values are:

| `--task` | Meaning | Runs downloaded |
|---|---|---|
| `6cat` | Six-category functional localizer | `01`, `02` |
| `pRF` | Population receptive-field/retinotopic localizer | `01`, `02` |

Although two other task labels exist elsewhere in the complete `ds00XXXX` datasets,
they are not inputs to this configured localizer pipeline:

| Dataset task | Meaning | Why it is not currently selected |
|---|---|---|
| `things` | Main experiment presenting images from the THINGS object database | Located in `ses-things01`through`ses-things12`; those BOLD payloads were not selected for this localizer example. |
| `rest` | Acquisition without an external visual task | The localizer filename uses `acq-reversePE` and has no `run-XX` entity, so it needs separate filename and distortion-correction decisions. |

### What does `6cat` measure?

The six-category task is a block-design functional localizer. Its `events.tsv` files show 15-second blocks from six visual categories:

1. body parts
2. faces
3. objects
4. scenes
5. scrambled images
6. words

Contrasting these categories later in a first-level statistical model can identify category-selective regions. Examples
include stronger responses to faces, scenes, bodies, words, or intact objects relative to control stimuli.
This bundle performs only pre-processing; it does not yet build those contrasts.

### What does `pRF` measure?

`pRF` means *population Receptive Field*. The paradigm presents visual input  at a sequence of positions while moving
across the visual field. The event labels encode directions such as:

- `LR` / `RL`: left-to-right / right-to-left
- `TB` / `BT`: top-to-bottom / bottom-to-top
- `TLBR`, `BRTL`, `TRBL`, `BLTR`: diagonal sweeps

The later pRF model uses the known stimulus position over time to estimate which part of the visual field drives each
voxel, commonly including the  voxel's preferred visual-field position and receptive-field size. FEAT pre-processing
prepares the time series but does not perform the pRF model.

### What is the `things` task?

This is the main THINGS-fMRI experiment. Participants viewed naturalistic object images sampled from the THINGS database.
Its event files distinguish experimental images, repeated test images, and catch trials, and include object category and
exemplar identifiers. It is much larger than the localizer data and would normally be processed after validating the
workflow on a small run.

### What is the `rest` task?

No explicit stimulus paradigm is presented during rest. The data can be used to study spontaneous BOLD correlations and
functional connectivity. In these localizer sessions the acquisition is labelled `reversePE`, meaning its phase-encoding
polarity differs from the main task runs. It should not be added to the current command merely by typing `--task rest`;
handling it properly requires a separate input pattern and an explicit distortion-correction plan.

## What the preprocessing pipeline does

The processing order and purpose are:

1. **MCFLIRT motion correction** estimates rigid head movement and aligns the functional volumes to a reference volume.
2. **Slice-timing correction** accounts for the fact that the 60 slices were acquired at different times within each
   1.5-second TR. The Deno script converts BIDS times in seconds into FEAT fractional-TR shifts.
3. **BET functional brain extraction** creates the functional brain mask.
4. **6 mm FWHM spatial smoothing** improves signal-to-noise at the cost of spatial precision.
5. **0.01 Hz high-pass filtering** removes very slow drift. FEAT expresses this as a 100-second cutoff because `1 / 0.01 Hz = 100 s`.
6. **Functional to T1 registration** uses rigid Boundary-Based Registration (BBR).
7. **T1 to MNI152 registration** uses FLIRT initialization followed by FNIRT non-linear warping.
8. **`applywarp`** combines the functional-to-T1 matrix and T1-to-MNI warp to create one pre-processed 4D series in MNI152 space.

The pipeline is preprocessing-only. The `events.tsv` files are needed later for task modelling, not for these preprocessing
steps. Physiological files would be needed for physiological-noise modelling, which is also outside this initial specification.

Field-map correction is intentionally disabled because it was not in the specified processing list. The dataset contains
field-map metadata, but using it correctly requires a deliberate FSL field-map preparation step rather than silently enabling it.

### Pipeline files

- `config.env`: dataset selection and preprocessing parameters.
- `run.sh`: checks inputs, prepares files, runs FEAT, waits for completion, and invokes `applywarp`.
- `build_design.ts`: validates JSON/NIfTI metadata, converts slice timings, and writes a run-specific `.fsf`.
- `preprocessing.fsf.template`: readable FEAT preprocessing template.

Generated material goes under `pipelines/fsl_openneuro/output/`.

## Running the Pipeline

### 1. Check which task labels are supported

```bash
./pipelines/fsl_openneuro/run.sh --list-tasks
```

This command only prints the distinction between the configured localizer tasks and the other tasks in the dataset.

### 2. Check an input run

```bash
./pipelines/fsl_openneuro/run.sh --check --task 6cat --run 01 --jobs 2
```

The `--check` command is read-only. It verifies that the BOLD, JSON, and T1 payloads are available and reports image
dimensions, volume count, TR, and planned processing parameters.

You can check every downloaded run:

```bash
./pipelines/fsl_openneuro/run.sh --check --task 6cat --run 01 --jobs 2
./pipelines/fsl_openneuro/run.sh --check --task 6cat --run 02 --jobs 2
./pipelines/fsl_openneuro/run.sh --check --task pRF  --run 01 --jobs 2
./pipelines/fsl_openneuro/run.sh --check --task pRF  --run 02 --jobs 2
```

### 3. Prepare without launching FEAT

```bash
./pipelines/fsl_openneuro/run.sh --prepare --task 6cat --run 01 --jobs 2
```

`--prepare` does three things:

1. Runs structural BET once and retains both whole-head and `_brain` versions because BBR and FNIRT need them.
2. Generates a 60-line custom slice-timing file from the run's JSON.
3. Generates a run-specific preprocessing-only `.fsf`.

### 4. Inspect structural BET before expensive processing

The resulting material will be stored under the `output` directory of the `fsl_openneuro` pipeline. The sub-directories
will be named after the datasets that have been pre-processed. Since we are working with `ds004192`, the path used with
FSLEyes should be as below:

```bash
fsleyes \
  ./pipelines/fsl_openneuro/output/ds004192/work/sub-01/ses-localizer1/anat/sub-01_ses-localizer1_acq-prescannormalized_rec-pydeface_T1w.nii.gz \
  ./pipelines/fsl_openneuro/output/ds004192/work/sub-01/ses-localizer1/anat/sub-01_ses-localizer1_acq-prescannormalized_rec-pydeface_T1w_brain.nii.gz
```

Within FSLEyes you can check that cortex and cerebellum were retained and that scalp, skull, eyes, and
neck were excluded. You can adjust BET settings in `config.env` if the extraction is poor. For new parameters attempts,
please use a different `OUTPUT_ROOT` directory.

### 5. Execute one pilot run

This is were we get things done. After the run is complete, look further down for more details about how to analyse and 
understand the results.

```bash
../pipelines/fsl_openneuro/run.sh --execute --task 6cat --run 01 --jobs 2
```

This rechecks the inputs, reuses the prepared files, starts FEAT, waits for the FEAT report to finish, checks the
expected registration products, and runs `applywarp`. FEAT and FNIRT can take a while.

The important results will be:

```text
./pipelines/fsl_openneuro/output/ds004192/sub-01/ses-localizer1/func/
  sub-01_ses-localizer1_task-6cat_run-01_bold.feat/
    filtered_func_data.nii.gz
    filtered_func_data_standard.nii.gz
    report.html
    mc/
    reg/
```

- `filtered_func_data.nii.gz`: pre-processed data in native functional space.
- `filtered_func_data_standard.nii.gz`: same pre-processed 4D data resampled to MNI152 space.
- `report.html`: FEAT processing and quality-control report.
- `mc/`: motion estimates and plots.
- `reg/`: BBR/FNIRT transformations and registration QC.

### Opening `.nii.gz` files with FSLeyes

A `.nii.gz` file is a compressed NIfTI neuroimaging file. FSL reads it directly, so do not decompress it. Use **FSLeyes**
for visual inspection; use FEAT to run the analysis described by an `.fsf` file.

For example, given a `.nii.gz`, you can use FSLeyes the terminal:

```bash
fsleyes /path/to/image.nii.gz
```

When several files are listed, the first is normally the background and later files are overlays. In the overlay list
you can toggle visibility and adjust colour, brightness, and opacity. Keep the orientation labels visible: `L`, `R`, `A`,
`P`, `S`, and `I` mean left, right, anterior, posterior, superior, and inferior.

### 3D anatomy and 4D functional data

A T1 anatomical scan is normally 3D: one detailed anatomical volume. A BOLD fMRI scan is 4D: a series of 3D volumes
acquired over time. FSLeyes shows a volume/time control for a 4D image; inspect several time points rather than
only volume 0.

You can check the number of volumes without a GUI:

```bash
fslval /path/to/image.nii.gz dim4
```

## Visualizing the results

Pay good attention to the next sections and the commands you have to run. If you open a new terminal where the environment
variables are not defined, things might not work as expected. To troubleshoot, please check the `config.env` and the `run.sh` files.

### Inspect the pilot run

Open the FEAT report in a browser or navigate to it from Finder:

```text
./pipelines/fsl_openneuro/output/ds004192/sub-01/ses-localizer1/func/sub-01_ses-localizer1_task-6cat_run-01_bold.feat/report.html
```

Inspect the standard-space time series:

```bash
fsleyes \
  "${FSLDIR}/data/standard/MNI152_T1_2mm.nii.gz" \
  ./pipelines/fsl_openneuro/output/ds004192/sub-01/ses-localizer1/func/sub-01_ses-localizer1_task-6cat_run-01_bold.feat/filtered_func_data_standard.nii.gz
```

To be able to execute the command depicted in the next sections, please define the required environment variables:

```bash
export DATASET="./datasets/openneuro/ds004192"
export OUTPUT="./pipelines/fsl_openneuro/output/ds004192"
export FEATDIR="${OUTPUT}/sub-01/ses-localizer1/func/sub-01_ses-localizer1_task-6cat_run-01_bold.feat"
```

### Original whole-head T1

```bash
fsleyes "${DATASET}/sub-01/ses-localizer1/anat/sub-01_ses-localizer1_acq-prescannormalized_rec-pydeface_T1w.nii.gz"
```

This is the high-resolution 0.8 mm anatomical scan. White matter is relatively bright, grey matter darker, and
cerebro-spinal fluid dark. It supplies detailed anatomy for BBR and FNIRT. The face was removed by the dataset authors for
privacy.

### Structural BET result and mask

```bash
T1_WORK="${OUTPUT}/work/sub-01/ses-localizer1/anat/sub-01_ses-localizer1_acq-prescannormalized_rec-pydeface_T1w"

fsleyes \
  "${T1_WORK}.nii.gz" \
  "${T1_WORK}_brain.nii.gz" \
  "${T1_WORK}_brain_mask.nii.gz"
```

- `${T1_WORK}.nii.gz`: whole-head T1 retained for FNIRT.
- `${T1_WORK}_brain.nii.gz`: T1 after BET removed non-brain tissue; supplied to FEAT and BBR.
- `${T1_WORK}_brain_mask.nii.gz`: binary mask, with brain voxels equal to 1.

Give the mask a bright colour and partial opacity. It should retain cortex and cerebellum while excluding skull, scalp,
eyes, and neck. Check axial, coronal, and sagittal views because BET errors can affect registration.

### Original raw 4D BOLD data

```bash
fsleyes "${DATASET}/sub-01/ses-localizer1/func/sub-01_ses-localizer1_task-6cat_run-01_bold.nii.gz"
```

This is the original EPI/BOLD series before pre-processing. It is lower resolution and has less anatomical contrast
than the T1. Move through time and look for abrupt head displacement, ghosting, missing slices, bright spikes, or large
regions with no signal. Some distortion and signal loss near inferior frontal and temporal regions is common in EPI data.

### Native-space FEAT images

After `--execute` completes:

```bash
fsleyes "${FEATDIR}/example_func.nii.gz"
fsleyes "${FEATDIR}/filtered_func_data.nii.gz"
fsleyes "${FEATDIR}/example_func.nii.gz" "${FEATDIR}/mask.nii.gz"
```

- `example_func.nii.gz`: one 3D functional reference volume used by MCFLIRT and registration.
- `filtered_func_data.nii.gz`: the main 4D output after motion correction, slice timing, masking, 6 mm smoothing, 
   and 100-second high-pass filtering. It is still on the subject's native functional grid.
- `mask.nii.gz`: binary functional brain mask used by FEAT.

The filtered brain should remain stable while moving through time. The functional mask should cover brain signal
without excluding cortex or adding large non-brain regions.

### BBR functional-to-T1 registration

```bash
fsleyes \
  "${FEATDIR}/reg/highres.nii.gz" \
  "${FEATDIR}/reg/example_func2highres.nii.gz"
```

`highres` is the brain-extracted T1. `example_func2highres` is the functional reference resampled into T1 space by BBR.
Toggle the functional overlay or change its opacity. The EPI is blurrier, so intensities will not match; judge the cortical
boundary, ventricles, and major anatomical contours. You can also inspect the BBR boundary overlay in the FEAT registration report.

### FNIRT T1-to-MNI152 registration

```bash
fsleyes \
  "${FEATDIR}/reg/standard.nii.gz" \
  "${FEATDIR}/reg/highres2standard.nii.gz"
```

`standard` is the MNI152 template. `highres2standard` is the participant's T1 warped to MNI152 by FNIRT. Toggle the warped
T1 and check the outer surface, ventricles, corpus callosum, cerebellum, and major sulci. Here you can also inspect for
gross displacement, clipping, implausible stretching, or folding.

### Final 4D data in MNI152 space

```bash
fsleyes \
  "${FSLDIR}/data/standard/MNI152_T1_2mm.nii.gz" \
  "${FEATDIR}/filtered_func_data_standard.nii.gz"
```

`filtered_func_data_standard.nii.gz` is the pre-processed native time series after the BBR matrix and FNIRT warp were
combined and applied with `applywarp`. It is a 4D image on the 2 mm MNI152 grid for common-space comparison.

Confirm its length:

```bash
fslval "${FEATDIR}/filtered_func_data_standard.nii.gz" dim4
```

The pilot 6cat result should have 180 volumes because `DELETE_VOLUMES=0`.

### Files that are not ordinary images

The extensions below are either not supported by FSLEyes or wouldn't work due to structural incompatibilities. 

- `*.json`: acquisition metadata; open in a text editor.
- `*_events.tsv`: stimulus timing and conditions; open in a spreadsheet or text editor.
- `*.fsf`: FEAT configuration; open as text or pass to `feat`.
- `*.mat` in `reg/`: FLIRT affine transformation matrices, stored as text.
- `*_warp.nii.gz`: NIfTI displacement fields encoding nonlinear transforms; direct grayscale viewing is generally not useful.

### 7. Execute the other downloaded runs

For the default dataset we used, the following run are also available. Feel free those after you are done with the `6cat` sub-set 01:

```bash
./pipelines/fsl_openneuro/run.sh --execute --task 6cat --run 02 --jobs 2
./pipelines/fsl_openneuro/run.sh --execute --task pRF  --run 01 --jobs 2
./pipelines/fsl_openneuro/run.sh --execute --task pRF  --run 02 --jobs 2
```

The brain-extracted T1 is reused. Every functional run receives its own slice-timing file, `.fsf`, `.feat` directory,
motion report, registration report, and standard-space 4D result.

## Mandatory QC checklist

For every run, inspect:

1. MCFLIRT rotations, translations, and relative displacement under `mc/`.
2. Functional BET coverage for lost cortex or retained non-brain signal.
3. BBR functional-to-T1 boundary alignment in `reg/`.
4. FNIRT T1-to-MNI alignment in `reg/`.
5. Several volumes of `filtered_func_data_standard.nii.gz` over MNI152.
6. The FEAT report for warnings or failed commands.

Successful command completion does not by itself establish scientifically acceptable preprocessing.

## Citation

If you use this pipeline, please cite:

```bibtex
@software{rodrigues_van_rooij_2026_fsl,
  author      = {Rodrigues, Wilder and van Rooij, Daan},
  title       = {A reusable {FSL} pipeline for {fMRI} data processing},
  year        = {2026},
  institution = {Utrecht University},
  organization = {Faculty of Social Sciences},
  address     = {The Netherlands},
  url         = {https://github.com/wilderrodrigues/fsl4all},
  note        = {GitHub repository}
}
