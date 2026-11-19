#!/bin/bash -l
#
# array.sbatch - one array task = one chunk of CHUNK_SIZE molecules,
# computed inside the GitHub Actions image.
#
# Task K processes data rows K*CHUNK_SIZE to (K+1)*CHUNK_SIZE - 1 of
# ${DATA}. The last chunk may be shorter.
#
# Argument 1: folder for the chunk files (chunk_NNNN.tsv, chunk_NNNN.invalid.tsv)
# Argument 2: chunk size (optional; default CHUNK_SIZE from config.sh)
#
# Submit with: bash slurm/sol/submit.sh one-task   (step 3b, a single task)
#              bash slurm/sol/submit.sh full       (step 4, all chunks + merge)
# submit.sh sets --array (with a %N limit on tasks running at once) and the
# requests from config.sh.

#SBATCH --job-name=rdkit-sol-array
# Account, partition and QoS come from config.sh / config.local.sh via
# submit.sh. The placeholder makes a direct `sbatch` of this file fail.
#SBATCH --account=REPLACE_WITH_APPROVED_ACCOUNT
#SBATCH --partition=public
#SBATCH --export=NONE
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=01:00:00

cd "${SLURM_SUBMIT_DIR}"
source slurm/sol/common.sh

OUTDIR=${1:?usage: array.sbatch <chunks folder> [chunk size]}
CHUNK_SIZE=${2:-$CHUNK_SIZE}
CHUNK_INDEX=${SLURM_ARRAY_TASK_ID:?must be submitted as a job array}

job_header
echo "Array job ${SLURM_ARRAY_JOB_ID}, task ${CHUNK_INDEX}: rows $(( CHUNK_INDEX * CHUNK_SIZE )) to $(( (CHUNK_INDEX + 1) * CHUNK_SIZE - 1 ))"

require_file "$SIF" "Copy the GitHub Actions image there first (step 1)."
require_file "$DATA" "Run the fetch step first (step 3a)."
mkdir -p "$OUTDIR"
printf -v CHUNK_NAME 'chunk_%04d' "$CHUNK_INDEX"

srun "${TIMER[@]}" apptainer exec --cleanenv \
    --bind "$(dirname "$DATA"):/data:ro" \
    --bind "${OUTDIR}:/out" \
    "$SIF" \
    python /opt/app/scripts/compute_descriptors.py \
        --input "/data/$(basename "$DATA")" \
        --chunk-size "$CHUNK_SIZE" --chunk-index "$CHUNK_INDEX" \
        --output "/out/${CHUNK_NAME}.tsv"

echo "Finished at $(date -Is)"
