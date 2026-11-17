# FSL FEAT pre-processing bundle for the fMRI data

This project focuses on how to use [FSL](https://fsl.fmrib.ox.ac.uk/fsl/docs/) to process and analyse fMRI data. It works
out of the box with the [OpenNeuro Things-fMRI dataset](https://openneuro.org/datasets/ds004192/versions/1.0.7/download).

The tooling and structure of the repository was further extended to support the pre-processing of the Utrecht University (UU)
Youth fMRI data. The UU data is not publicly available. However, the code has been made open to facilitate the adoption
by other university staff members and researchers.

## Project Structure

The project contains two mains sub-directories under the `pipelines` directory:

* `fsl_openneuro`: Where the script and artefacts to process OpenNeuro Things-fMRI are located.
* `fsl_uu`: Where the script and artefacts to process the Utrecht University Youth fMRI data are located.

Please, follow the instructions on the OpenNeuro website on how to get the dataset downloaded. If you are a Mac user, the
snippets below will help to get started with a sub-set of the data:

Ech pipeline contains its own README.md file. Please, refer to those files for further instructions.

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