#!/bin/bash
#
# run_array.sbatch - job array: each task computes descriptors for one chunk.
#
# Task K processes data rows K*CHUNK_SIZE to (K+1)*CHUNK_SIZE - 1, so the
# default 20 tasks x 10,000 rows cover the first 200,000 molecules.
# "%4" runs at most 4 tasks at the same time (the VM has 4 CPUs).
#
# Usually submitted by slurm/submit_subset.sh, which also queues the merge.
# To submit on its own, from the repository root:
#   mkdir -p logs
#   sbatch slurm/run_array.sbatch
#
# Requests are based on the measured test run on the VM (job 3: 10,000
# molecules, 20 s wall time, 20.1 s CPU time, 110,208 KB MaxRSS); see
# docs/RESULTS.md for the reasoning.

#SBATCH --job-name=rdkit-array
#SBATCH --array=0-19%4
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1        # single-threaded: CPU time = wall time in the test run
#SBATCH --mem=512M               # measured peak ~108 MB; headroom for larger molecules
#SBATCH --time=00:05:00          # measured 20 s per 10,000 molecules
#SBATCH --output=logs/%x_%A_%a.out  # %A = array job ID, %a = task ID
#SBATCH --acctg-freq=task=1      # sample memory every 1 s (cluster default here is 30 s)

set -euo pipefail

# Settings (override with sbatch --export=ALL,NAME=value)
CHUNK_SIZE=${CHUNK_SIZE:-10000}
INPUT=${INPUT:-data/chembl_37_chemreps.txt.gz}
IMAGE=${IMAGE:-container/rdkit-descriptors.sif}
OUTDIR=${OUTDIR:-results/subset200k/chunks}

# Each task gets its own number in SLURM_ARRAY_TASK_ID; use it as the chunk.
CHUNK_INDEX=${SLURM_ARRAY_TASK_ID:?this script must be run as a job array (sbatch --array=...)}

cd "${SLURM_SUBMIT_DIR}"

for f in "$INPUT" "$IMAGE"; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found (submit from the repository root)" >&2; exit 1; }
done
mkdir -p "$OUTDIR"

INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
OUT_ABS=$(cd "$OUTDIR" && pwd)
printf -v CHUNK_NAME 'chunk_%04d' "$CHUNK_INDEX"

echo "Array job ${SLURM_ARRAY_JOB_ID}, task ${SLURM_ARRAY_TASK_ID} (job ${SLURM_JOB_ID}) on $(hostname) at $(date -Is)"
echo "Chunk: index ${CHUNK_INDEX}, size ${CHUNK_SIZE}  input: ${INPUT}"

srun /usr/bin/time -v \
    apptainer exec --cleanenv \
        --bind "${INPUT_DIR}:/data:ro" \
        --bind "${OUT_ABS}:/out" \
        "$IMAGE" \
        python /opt/app/scripts/compute_descriptors.py \
            --input "/data/$(basename "$INPUT")" \
            --chunk-size "$CHUNK_SIZE" --chunk-index "$CHUNK_INDEX" \
            --output "/out/${CHUNK_NAME}.tsv"

echo "Finished at $(date -Is)"
