#!/bin/bash
#
# run_single.sbatch - compute descriptors for ONE chunk inside the container.
#
# Submit from the repository root (logs/ must exist first; Slurm does not
# create the folder for --output, and the job fails without it):
#   mkdir -p logs
#   sbatch slurm/run_single.sbatch
#
# Settings can be changed without editing this file, for example:
#   sbatch --export=ALL,CHUNK_SIZE=200000,OUTDIR=results/single_full slurm/run_single.sbatch
#
# The requests below were the starting point for the measured test run on the
# VM (generous on purpose). The array job's requests are based on that run;
# see docs/RESULTS.md.

#SBATCH --job-name=rdkit-single
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1        # compute_descriptors.py is single-threaded
#SBATCH --mem=2G
#SBATCH --time=00:15:00
#SBATCH --output=logs/%x_%j.out  # %x = job name, %j = job ID
#SBATCH --acctg-freq=task=1      # sample memory every 1 s (cluster default here is 30 s)

set -euo pipefail

# Settings (override with sbatch --export=ALL,NAME=value)
CHUNK_SIZE=${CHUNK_SIZE:-10000}
CHUNK_INDEX=${CHUNK_INDEX:-0}
INPUT=${INPUT:-data/chembl_37_chemreps.txt.gz}
IMAGE=${IMAGE:-container/rdkit-descriptors.sif}
OUTDIR=${OUTDIR:-results/single}

# Slurm starts the job in the folder it was submitted from; make that explicit.
cd "${SLURM_SUBMIT_DIR}"

for f in "$INPUT" "$IMAGE"; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found (submit from the repository root)" >&2; exit 1; }
done
mkdir -p "$OUTDIR"

INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
OUT_ABS=$(cd "$OUTDIR" && pwd)
printf -v CHUNK_NAME 'chunk_%04d' "$CHUNK_INDEX"

echo "Job ${SLURM_JOB_ID} on $(hostname) at $(date -Is)"
echo "CPUs: ${SLURM_CPUS_PER_TASK}  memory per node: ${SLURM_MEM_PER_NODE} MB"
echo "Chunk: index ${CHUNK_INDEX}, size ${CHUNK_SIZE}  input: ${INPUT}"
echo "$(apptainer --version)  image: ${IMAGE}"

# srun starts a job step, so sacct reports this step's time and memory
# separately from the batch script. /usr/bin/time -v prints the exact peak
# memory ("Maximum resident set size") to this log when the step ends.
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
