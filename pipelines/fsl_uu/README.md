# FSL FEAT preprocessing bundle for the fMRI data

This pipeline is dedicated to processing Utrecht University (UU) Youth fMRI data. Whilst the repository is public, the datasets
are available only to UU researchers.

If you are interested in that kind of research or want to acquire more knowledge about pre-processing fMRI using FSL FEAT,
please have a look at our `fsl_openneuro` pipeline.

## Getting access to the data

WIP

## Pre-processing UU Youth data

### Check dataset artefacts

```shell
./pipelines/fsl_uu/run.sh \
                   --check \
                   --dataset-root path_to_data \
                   --output validation \
                   --jobs 4
```

### Execute pipeline

```shell
./pipelines/fsl_uu/run.sh \
                   --execute \
                   --dataset-root path_to_data \
                   --output validation \
                   --jobs 4
```

## Inspecting Results

WIP

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