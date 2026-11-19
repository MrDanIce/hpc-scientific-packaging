# Shared setup for the job scripts in slurm/sol/. Sourced at the start of
# each job (on the compute node), after `cd "$SLURM_SUBMIT_DIR"`.

set -euo pipefail

# shellcheck source=slurm/sol/config.sh
source slurm/sol/config.sh

# Jobs are submitted with --export=NONE. Slurm then also sets
# SLURM_EXPORT_ENV=NONE inside the job, and `srun` would start each step
# without the PATH changes made by `module load` below. ALL makes srun pass
# this script's environment on to its steps.
export SLURM_EXPORT_ENV=ALL

if [[ -n "${APPTAINER_MODULE}" ]]; then
    module load "${APPTAINER_MODULE}"
fi

# Use GNU time for an exact peak-memory figure in the log, if the node has it.
TIMER=()
if [[ -x /usr/bin/time ]]; then
    TIMER=(/usr/bin/time -v)
fi

job_header() {
    echo "Job ${SLURM_JOB_ID} (${SLURM_JOB_NAME}) on $(hostname) at $(date -Is)"
    echo "Account ${SLURM_JOB_ACCOUNT:-?}, partition ${SLURM_JOB_PARTITION:-?}, QoS ${SLURM_JOB_QOS:-?}"
    echo "Architecture $(uname -m), CPUs allocated ${SLURM_CPUS_PER_TASK:-?}, memory ${SLURM_MEM_PER_NODE:-?} MB"
    if command -v apptainer >/dev/null 2>&1; then
        echo "$(apptainer --version)"
    else
        echo "apptainer: not on PATH"
    fi
    [[ ${#TIMER[@]} -gt 0 ]] || echo "/usr/bin/time not found; exact peak memory will not be logged"
}

require_file() {
    [[ -f "$1" ]] || { echo "ERROR: $1 not found. $2" >&2; exit 1; }
}
