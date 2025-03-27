project_root=/cbica/projects/grmpy
cd ${project_root}/data/BABS/derivatives
export TEMPLATEFLOW_HOME=${PWD}/templateflow_home
mkdir -p ${TEMPLATEFLOW_HOME}
babs init \
     ${PWD}/mriqc \
     --datasets BIDS=${project_root}/data/bids_datalad/ \
     --container-ds ${project_root}/data/BABS/apptainer-datasets/mriqc-24-0-2-ds \
     --container-name mriqc-24-0-2 \
     --container-config ${project_root}/code/curation/05_babs/mriqc-24-0-2.yaml \
     --processing-level subject \
     --queue slurm