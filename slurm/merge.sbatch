#!/bin/bash
#
# merge.sbatch - merge the array's chunk files into one sorted file.
#
# Meant to be queued by slurm/submit_subset.sh with
#   --dependency=afterok:<array job ID> --kill-on-invalid-dep=yes
# so it starts only if EVERY array task finished with exit code 0, and is
# cancelled (instead of waiting forever) if any task fails.
#
# merge_results.py also checks that all EXPECTED_CHUNKS files exist and have
# the same header, and writes nothing if they do not.
#
# Requests are based on the measured merge of the 200,000-molecule subset
# on the VM (job 7: 0.76 s wall time, 189,376 KB peak memory; docs/RESULTS.md).

#SBATCH --job-name=rdkit-merge
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#SBATCH --time=00:05:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --acctg-freq=task=1

set -euo pipefail

EXPECTED_CHUNKS=${EXPECTED_CHUNKS:-20}
CHUNKS_DIR=${CHUNKS_DIR:-results/subset200k/chunks}
OUTPUT=${OUTPUT:-results/subset200k/descriptors.tsv}
IMAGE=${IMAGE:-container/rdkit-descriptors.sif}

cd "${SLURM_SUBMIT_DIR}"

[[ -d "$CHUNKS_DIR" ]] || { echo "ERROR: $CHUNKS_DIR not found" >&2; exit 1; }
CHUNKS_ABS=$(cd "$CHUNKS_DIR" && pwd)
mkdir -p "$(dirname "$OUTPUT")"
OUT_DIR_ABS=$(cd "$(dirname "$OUTPUT")" && pwd)

echo "Merge job ${SLURM_JOB_ID} on $(hostname) at $(date -Is)"
echo "Expecting ${EXPECTED_CHUNKS} chunks in ${CHUNKS_DIR}"

srun /usr/bin/time -v \
    apptainer exec --cleanenv \
        --bind "${CHUNKS_ABS}:/chunks:ro" \
        --bind "${OUT_DIR_ABS}:/out" \
        "$IMAGE" \
        python /opt/app/scripts/merge_results.py \
            --chunks-dir /chunks --expected "$EXPECTED_CHUNKS" \
            --output "/out/$(basename "$OUTPUT")"

echo "Finished at $(date -Is)"
