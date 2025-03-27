project_root=/cbica/projects/yourproject # [FIX ME] your project directory on cubic
cd ${project_root}/path/to/derivatives # [FIX ME] your path to where you want BABS derivatives to live
export TEMPLATEFLOW_HOME=${PWD}/templateflow_home
mkdir -p ${TEMPLATEFLOW_HOME}
babs init \
     ${PWD}/projectname \ # [FIX ME] the name of your babs project (e.g. mriqc, fmriprepANAT, etc.)
     --datasets BIDS=${project_root}/path/to/input/data/ \ # [FIX ME] path to your input bids data
     --container-ds ${project_root}/path/to/apptainer/ds \ # [FIX ME] path to your dataladed apptainer container (e.g. mriqc-24-0-2-ds)
     --container-name container-name \ #[FIX ME] (e.g. mriqc-24-0-2)
     --container-config ${project_root}/path/to/config/yaml \ # [FIX ME] e.g. mriqc-24-0-2.yaml
     --processing-level subject \ # [FIX ME] set to subject for single-session datasets or session for longitudinal datasets
     --queue slurm