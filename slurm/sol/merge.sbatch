#!/bin/bash -l
#
# merge.sbatch - merge chunk files into one sorted table, inside the image.
# merge_results.py fails without writing anything if any of the expected
# chunk files is missing or if the headers differ.
#
# Arguments: 1 = number of chunks expected (chunk_0000 .. chunk_N-1)
#            2 = folder with the chunk files
#            3 = merged output file (the .invalid.tsv file goes next to it)
#
# submit.sh queues this with --dependency=afterok:<array job ID>
# --kill-on-invalid-dep=yes, so it starts only if EVERY array task exited
# with code 0, and is cancelled if any task fails.

#SBATCH --job-name=rdkit-sol-merge
# Account, partition and QoS come from config.sh / config.local.sh via
# submit.sh. The placeholder makes a direct `sbatch` of this file fail.
#SBATCH --account=REPLACE_WITH_APPROVED_ACCOUNT
#SBATCH --partition=htc
#SBATCH --export=NONE
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=00:30:00

cd "${SLURM_SUBMIT_DIR}"
source slurm/sol/common.sh

EXPECTED=${1:?usage: merge.sbatch <chunks expected> <chunks folder> <output file>}
CHUNKS_DIR=${2:?missing chunks folder}
OUTPUT=${3:?missing output file}

job_header
echo "Merging ${EXPECTED} chunks from ${CHUNKS_DIR} into ${OUTPUT}"
require_file "$SIF" "Copy the GitHub Actions image there first (step 1)."
mkdir -p "$(dirname "$OUTPUT")"

srun "${TIMER[@]}" apptainer exec --cleanenv \
    --bind "${CHUNKS_DIR}:/chunks:ro" \
    --bind "$(dirname "$OUTPUT"):/out" \
    "$SIF" \
    python /opt/app/scripts/merge_results.py \
        --chunks-dir /chunks --expected "$EXPECTED" \
        --output "/out/$(basename "$OUTPUT")"

sha256sum "$OUTPUT" "${OUTPUT%.tsv}.invalid.tsv"
wc -l "$OUTPUT" "${OUTPUT%.tsv}.invalid.tsv"
echo "Finished at $(date -Is)"
