#!/usr/bin/env bash
#
# reface_anatomicals.sh - Deface T1w and T2w anatomical images in a BIDS dataset
# ============================================================================
#
# DESCRIPTION:
#   This script processes T1w and T2w anatomical images in a BIDS dataset to
#   remove facial features for privacy protection. It uses AFNI's refacer for
#   T1w images and pydeface for T2w images. The script creates a SLURM array
#   job where each task processes one anatomical image.
#
# USAGE:
#   bash reface_anatomicals.sh BIDS_DIR LOG_DIR
#
# ARGUMENTS:
#   BIDS_DIR  - Path to the BIDS dataset directory (required)
#   LOG_DIR   - Path to store log files (required)
#
# EXAMPLES:
#   bash ./reface_anatomicals.sh /data/myproject/bids /data/myproject/logs/reface
#
# OUTPUTS:
#   - Creates defaced versions of anatomical images with "rec-refaced" (T1w) or "rec-defaced" (T2w) in the filename
#   - Removes original images after processing
#   - Logs are stored in LOG_DIR
#
# REQUIREMENTS:
#   - SLURM job scheduler
#   - AFNI (for T1w defacing)
#   - pydeface (for T2w defacing) installed in a micromamba environment
#
# NOTES:
#   - The script automatically determines the array size based on the number of files
#   - Only processes files that don't already have "rec-defaced" or "rec-refaced" in their name
#   - If performing on a datalad dataset, you will need to run a datalad save command after checking
#     outputs. e.g. `datalad save -d BIDS_DIR -m "Reface T1w images with afni_refacer_run and deface
#     T2w images with pydeface"`
#
# ============================================================================

# First argument is the BIDS root directory
bids_root="$1"

# Second argument is the base path for logs
log_base_path="$2"

# Ensure log directory exists
mkdir -p "${log_base_path}"

# Create a temporary file with the list of files to process
temp_file_list="${log_base_path}/anat_files_to_process.txt"

# Find files and save to the temporary file - using -L to follow symlinks
find -L "${bids_root}"/sub-* -type f \
  \( -name "*_T1w.nii.gz" -o -name "*_T2w.nii.gz" \) \
  | grep -v -e "rec-defaced" -e "rec-refaced" | sort > "${temp_file_list}"

# Count the files
file_count=$(wc -l < "${temp_file_list}")

# Subtract 1 for zero-based array indexing
max_array=$((file_count - 1))

if [ $max_array -lt 0 ]; then
  echo "No files found to process. Exiting."
  exit 1
fi

echo "Found $file_count files to process. Setting array size to 0-$max_array."
echo "File list saved to: ${temp_file_list}"

# Submit the job with the calculated array size
sbatch --array=0-$max_array \
  --output="${log_base_path}/reface_%A_%a.out" \
  --error="${log_base_path}/reface_%A_%a.err" \
  --export=ALL,BIDS_ROOT="${bids_root}",FILE_LIST="${temp_file_list}" <<'SBATCH_SCRIPT'
#!/usr/bin/env bash
#SBATCH --job-name=reface
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G

set -eux

# Load AFNI (for T1w refacing)
module add afni/2022_05_03

# Get the BIDS directory from the environment variable
bids_root="${BIDS_ROOT}"
file_list="${FILE_LIST}"

echo "SLURM_ARRAY_TASK_ID: ${SLURM_ARRAY_TASK_ID}"
echo "BIDS root: ${bids_root}"
echo "File list: ${file_list}"

# Check if file list exists
if [ ! -f "${file_list}" ]; then
  echo "ERROR: File list not found: ${file_list}"
  exit 1
fi

# Get the file for this array task
ANAT=$(sed -n "$((SLURM_ARRAY_TASK_ID+1))p" "${file_list}")

# Check if we got a valid file
if [ -z "${ANAT}" ]; then
  echo "ERROR: No file found for index ${SLURM_ARRAY_TASK_ID}"
  echo "File list contents:"
  cat "${file_list}"
  exit 1
fi

echo "Processing file: ${ANAT}"

ANAT_DIR="$(dirname "$ANAT")"
ANAT_BASENAME="$(basename "$ANAT")"

# Move to the directory containing the file
cd "$ANAT_DIR" || { echo "ERROR: Could not change to directory: $ANAT_DIR"; exit 1; }

# Determine suffix (_T1w.nii.gz or _T2w.nii.gz) and rec label based on the NIfTI filename
if [[ "$ANAT_BASENAME" == *"_T1w.nii.gz" ]]; then
  NIFTI_SUFFIX="_T1w.nii.gz"
  REC_LABEL="_rec-refaced"
elif [[ "$ANAT_BASENAME" == *"_T2w.nii.gz" ]]; then
  NIFTI_SUFFIX="_T2w.nii.gz"
  REC_LABEL="_rec-defaced"
else
  echo "ERROR: Unrecognized NIfTI file type: $ANAT_BASENAME"
  exit 1
fi

# Extract base part of the NIfTI filename (without suffix)
BASE_PART="${ANAT_BASENAME%$NIFTI_SUFFIX}"

# Check if a rec- entity already exists
if [[ "$BASE_PART" == *"_rec-"* ]]; then
  # Existing rec- found, append refaced/defaced
  MODIFIER="${REC_LABEL#_rec-}" # "refaced" or "defaced"
  echo "Existing rec- entity found. Appending '${MODIFIER}'."

  # Extract parts: prefix, existing label, remainder
  PREFIX="${BASE_PART%%_rec-*}" # Part before the first _rec-
  TEMP_SUFFIX="${BASE_PART#*_rec-}" # Part starting with the label after _rec-
  EXISTING_LABEL="${TEMP_SUFFIX%%_*}" # The actual label (e.g., 'orig')
  REMAINDER="${TEMP_SUFFIX#$EXISTING_LABEL}" # Rest of the filename after the label (e.g., '_run-1') or empty

  NEW_REC_LABEL="_rec-${EXISTING_LABEL}${MODIFIER}" # e.g., _rec-origrefaced

  DEFACED_BASENAME="${PREFIX}${NEW_REC_LABEL}${REMAINDER}${NIFTI_SUFFIX}"

else
  # No existing rec-, insert the new REC_LABEL (_rec-refaced or _rec-defaced) at the correct spot
  echo "No existing rec- entity found. Inserting ${REC_LABEL}."
  # Find the insertion point: before run, echo, part, chunk, or suffix
  INSERTION_POINT=""
  if [[ "$BASE_PART" == *"_run-"* ]]; then
    BEFORE="${BASE_PART%_run-*}"
    AFTER="${BASE_PART#$BEFORE}"
    INSERTION_POINT="_run-"
  elif [[ "$BASE_PART" == *"_echo-"* ]]; then
    BEFORE="${BASE_PART%_echo-*}"
    AFTER="${BASE_PART#$BEFORE}"
    INSERTION_POINT="_echo-"
  elif [[ "$BASE_PART" == *"_part-"* ]]; then
    BEFORE="${BASE_PART%_part-*}"
    AFTER="${BASE_PART#$BEFORE}"
    INSERTION_POINT="_part-"
  elif [[ "$BASE_PART" == *"_chunk-"* ]]; then
    BEFORE="${BASE_PART%_chunk-*}"
    AFTER="${BASE_PART#$BEFORE}"
    INSERTION_POINT="_chunk-"
  else
    # No subsequent entities found, insert before suffix
    BEFORE="$BASE_PART"
    AFTER=""
    INSERTION_POINT="suffix"
  fi

  DEFACED_BASENAME="${BEFORE}${REC_LABEL}${AFTER}${NIFTI_SUFFIX}"
fi

echo "SLURM_ARRAY_TASK_ID:   $SLURM_ARRAY_TASK_ID"
echo "Anatomical directory:  $ANAT_DIR"
echo "Anatomical file:       $ANAT_BASENAME"
echo "Defaced file:          $DEFACED_BASENAME"

# Decide which defacing tool to use
if [[ "$ANAT_BASENAME" == *"_T1w.nii.gz" ]]; then
  echo "Using @afni_refacer_run (AFNI) for T1w"
  @afni_refacer_run \
    -input "$ANAT_BASENAME" \
    -mode_reface_plus \
    -prefix "$DEFACED_BASENAME"

elif [[ "$ANAT_BASENAME" == *"_T2w.nii.gz" ]]; then
  echo "Using pydeface for T2w"
  # Use micromamba to run pydeface in the appropriate environment
  eval "$(micromamba shell hook --shell bash)"
  micromamba activate babs # [FIX ME] change to the appropriate environment where you pip installed pydeface
  pydeface --outfile "$DEFACED_BASENAME" "$ANAT_BASENAME"
  micromamba deactivate

fi

# Remove the original NIfTI file
rm "${ANAT_BASENAME}"

# Handle the JSON sidecar (if it exists)
JSON_BASENAME="${ANAT_BASENAME%.nii.gz}.json"
if [ -f "$JSON_BASENAME" ]; then
  echo "Found JSON sidecar: $JSON_BASENAME"
  # Determine JSON suffix (_T1w.json or _T2w.json) and rec label (reuse from NIfTI)
  if [[ "$JSON_BASENAME" == *"_T1w.json" ]]; then
    JSON_SUFFIX="_T1w.json"
    # REC_LABEL already set based on NIfTI type
  elif [[ "$JSON_BASENAME" == *"_T2w.json" ]]; then
    JSON_SUFFIX="_T2w.json"
    # REC_LABEL already set based on NIfTI type
  else
    echo "WARNING: Could not determine suffix type for JSON file: $JSON_BASENAME. Attempting rename based on NIfTI."
    # Fallback: Construct potential defaced name based on NIfTI's defaced name
    DEFACED_JSON_FALLBACK="${DEFACED_BASENAME%.nii.gz}.json"
    echo "Attempting to rename JSON to: $DEFACED_JSON_FALLBACK"
    mv "$JSON_BASENAME" "$DEFACED_JSON_FALLBACK" || echo "WARNING: Failed to rename JSON sidecar $JSON_BASENAME"
    # Skip further specific JSON logic for this file if suffix unknown
    # Note: Depending on cleanup logic, this might leave the incorrectly named JSON
  fi

  # If suffix was determined, proceed with structured rename
  if [[ -n "$JSON_SUFFIX" ]]; then
    # Extract base part of the JSON filename (without suffix)
    JSON_BASE_PART="${JSON_BASENAME%$JSON_SUFFIX}"

    # Check if a rec- entity already exists in the JSON filename
    if [[ "$JSON_BASE_PART" == *"_rec-"* ]]; then
      # Existing rec- found, append refaced/defaced
      MODIFIER="${REC_LABEL#_rec-}" # "refaced" or "defaced" (use the one determined from NIfTI)
      echo "Existing rec- entity found in JSON. Appending '${MODIFIER}'."

      # Extract parts: prefix, existing label, remainder
      JSON_PREFIX="${JSON_BASE_PART%%_rec-*}"
      JSON_TEMP_SUFFIX="${JSON_BASE_PART#*_rec-}"
      JSON_EXISTING_LABEL="${JSON_TEMP_SUFFIX%%_*}"
      JSON_REMAINDER="${JSON_TEMP_SUFFIX#$JSON_EXISTING_LABEL}"

      JSON_NEW_REC_LABEL="_rec-${JSON_EXISTING_LABEL}${MODIFIER}"

      DEFACED_JSON_BASENAME="${JSON_PREFIX}${JSON_NEW_REC_LABEL}${JSON_REMAINDER}${JSON_SUFFIX}"

    else
      # No existing rec-, insert the new REC_LABEL (_rec-refaced or _rec-defaced) at the correct spot
      echo "No existing rec- entity found in JSON. Inserting ${REC_LABEL}."
      # Find the insertion point: before run, echo, part, chunk, or suffix
      JSON_INSERTION_POINT=""
      if [[ "$JSON_BASE_PART" == *"_run-"* ]]; then
        JSON_BEFORE="${JSON_BASE_PART%_run-*}"
        JSON_AFTER="${JSON_BASE_PART#$JSON_BEFORE}"
        JSON_INSERTION_POINT="_run-"
      elif [[ "$JSON_BASE_PART" == *"_echo-"* ]]; then
        JSON_BEFORE="${JSON_BASE_PART%_echo-*}"
        JSON_AFTER="${JSON_BASE_PART#$JSON_BEFORE}"
        JSON_INSERTION_POINT="_echo-"
      elif [[ "$JSON_BASE_PART" == *"_part-"* ]]; then
        JSON_BEFORE="${JSON_BASE_PART%_part-*}"
        JSON_AFTER="${JSON_BASE_PART#$JSON_BEFORE}"
        JSON_INSERTION_POINT="_part-"
      elif [[ "$JSON_BASE_PART" == *"_chunk-"* ]]; then
        JSON_BEFORE="${JSON_BASE_PART%_chunk-*}"
        JSON_AFTER="${JSON_BASE_PART#$JSON_BEFORE}"
        JSON_INSERTION_POINT="_chunk-"
      else
        # No subsequent entities found, insert before suffix
        JSON_BEFORE="$JSON_BASE_PART"
        JSON_AFTER=""
        JSON_INSERTION_POINT="suffix"
      fi

      # Construct the new defaced JSON filename
      DEFACED_JSON_BASENAME="${JSON_BEFORE}${REC_LABEL}${JSON_AFTER}${JSON_SUFFIX}"
    fi

    # Rename the JSON file
    echo "Renaming JSON sidecar: $JSON_BASENAME -> $DEFACED_JSON_BASENAME"
    mv "$JSON_BASENAME" "$DEFACED_JSON_BASENAME" || echo "WARNING: Failed to rename JSON sidecar $JSON_BASENAME to $DEFACED_JSON_BASENAME"
  fi
fi # end JSON check

# Clean up only if T1w (AFNI refacer leaves extra files)
if [[ "$ANAT_BASENAME" == *"_T1w.nii.gz" ]]; then
  # Use the actual defaced filename base for cleanup
  DEFACED_BASE="${DEFACED_BASENAME%.nii.gz}"
  echo "Cleaning up AFNI temporary files for base: ${DEFACED_BASE}"
  rm -f "${DEFACED_BASE}"*face_plus*
  rm -rf "${DEFACED_BASE}"_QC/
fi

echo "Done processing $ANAT_BASENAME"
SBATCH_SCRIPT

echo "Job submitted with:"
echo "  BIDS directory: $bids_root"
echo "  Log directory: $log_base_path"
echo "  File list: ${temp_file_list}"
echo "Remember to datalad save your changes after reviewing. e.g."
echo "datalad save -d BIDS_DIR -m "Reface T1w images with afni_refacer_run and deface T2w images with pydeface""
