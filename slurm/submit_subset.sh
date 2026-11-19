#!/usr/bin/env bash
#
# submit_subset.sh - queue the job array for the 200,000-molecule subset,
# then a merge job that runs only if every array task succeeds.
#
# Run from anywhere (it changes to the repository root itself):
#   bash slurm/submit_subset.sh
#
# The subset is the first 200,000 molecules (data rows) of
# data/chembl_37_chemreps.txt.gz.

set -euo pipefail

SUBSET=200000      # molecules to process
CHUNK_SIZE=10000   # molecules per array task
MAX_PARALLEL=4     # tasks running at once (the VM has 4 CPUs)
OUTDIR=results/subset200k

# Go to the repository root (the folder above this script), because the
# batch scripts use paths relative to the folder they were submitted from.
cd "$(dirname "$0")/.."

if (( SUBSET % CHUNK_SIZE != 0 )); then
    echo "ERROR: SUBSET ($SUBSET) must be a multiple of CHUNK_SIZE ($CHUNK_SIZE)" >&2
    exit 1
fi
N_CHUNKS=$(( SUBSET / CHUNK_SIZE ))

# Slurm does not create the folder for --output files; a missing logs/
# makes the jobs fail without writing any log.
mkdir -p logs

# --parsable makes sbatch print only the job ID (sometimes "ID;cluster").
array_id=$(sbatch --parsable \
    --array="0-$(( N_CHUNKS - 1 ))%${MAX_PARALLEL}" \
    --export=ALL,CHUNK_SIZE=${CHUNK_SIZE},OUTDIR=${OUTDIR}/chunks \
    slurm/run_array.sbatch)
array_id=${array_id%%;*}

# afterok:<array ID> waits for ALL tasks of the array and needs all of them
# to exit with code 0. If one fails, the dependency can never be met, and
# --kill-on-invalid-dep=yes makes Slurm cancel the merge job.
merge_id=$(sbatch --parsable \
    --dependency=afterok:${array_id} --kill-on-invalid-dep=yes \
    --export=ALL,EXPECTED_CHUNKS=${N_CHUNKS},CHUNKS_DIR=${OUTDIR}/chunks,OUTPUT=${OUTDIR}/descriptors.tsv \
    slurm/merge.sbatch)
merge_id=${merge_id%%;*}

echo "Array job: ${array_id} (${N_CHUNKS} tasks x ${CHUNK_SIZE} molecules, at most ${MAX_PARALLEL} at once)"
echo "Merge job: ${merge_id} (runs after all array tasks succeed)"
echo
echo "Watch:  squeue -u \$USER"
echo "After:  sacct -j ${array_id},${merge_id} --format=JobID,JobName,State,ExitCode,Elapsed,TotalCPU,ReqMem,MaxRSS"
