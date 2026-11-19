# Settings for running this project on ASU Sol.
#
# Read by slurm/sol/submit.sh and by every job script in slurm/sol/.
# The jobs are submitted with --export=NONE, so they do not inherit your
# shell's variables; they read this file instead.
#
# Optional: slurm/sol/config.local.sh (not tracked by git) is read last and
# can override any of these values.

# ---------------------------------------------------------------- account
# The real account is NOT stored here (this repository is public). Set it,
# and the QoS that goes with it, in slurm/sol/config.local.sh on Sol:
#   SOL_ACCOUNT="<account>"
#   SOL_QOS="<qos>"
# Find yours with: sacctmgr -n -P show assoc user=$USER format=account,partition,qos
# submit.sh refuses to submit while the account is still the placeholder.
SOL_ACCOUNT="REPLACE_WITH_APPROVED_ACCOUNT"
SOL_PARTITION="htc"
SOL_QOS="public"

# ---------------------------------------------------------------- paths
# Everything the jobs write goes under WORK. The repository itself can live
# anywhere (submit from its root).
WORK="/scratch/${USER}/hpc-scientific-packaging"
SIF="${WORK}/images/rdkit-descriptors-x86_64.sif"   # image built by GitHub Actions
ENV_PREFIX="${WORK}/envs/rdkit-descriptors"         # conda env rebuilt on a compute node
CONDA_PKGS="${WORK}/conda-pkgs"                     # package cache (keeps home quota free)
DATA="${WORK}/data/chembl_37_chemreps.txt.gz"
LOGDIR="${WORK}/logs"
RESULTS="${WORK}/results"

# ---------------------------------------------------------------- software
MAMBA_MODULE="mamba/latest"
# Leave empty if 'apptainer' is already on PATH on compute nodes; otherwise
# set it to a module name. Step 0 on the Sol login node (2026-11-18) found
# /usr/bin/apptainer 1.5.4 on PATH, and a module apptainer/1.4.5. The system
# 1.5.4 is used (closest to 1.5.5, which built the image); fixture.sbatch
# prints the version found on the compute node.
APPTAINER_MODULE=""

# ---------------------------------------------------------------- workload
TOTAL_MOLECULES=2897819   # data rows in chembl_37_chemreps.txt.gz (counted on the VM)
# QoS "class" limits seen on Sol (2026-11-18, sacctmgr show qos):
#   MaxWall 1-00:00:00, MaxJobsPU 2 (running at once), MaxSubmitPU 10 (in the queue).
# Each array task counts as one job, so a full run must be at most
# MAX_SUBMIT_JOBS jobs including the merge: 8 chunks + 1 merge = 9.
CHUNK_SIZE=400000         # molecules per array task in the full run (8 chunks); to be confirmed from step 3b
TEST_CHUNK_SIZE=200000    # step 3b: one task over rows 0-199,999, comparable with the VM result
MAX_PARALLEL=2            # array tasks running at the same time (%N); QoS allows 2
MAX_SUBMIT_JOBS=10        # QoS MaxSubmitPU

# ---------------------------------------------------------------- requests
# Starting values. ARRAY_* and MERGE_* are to be replaced with values based
# on the sacct numbers from the one-task test (step 3). Every request must
# stay under the 4-hour limit.
FIXTURE_CPUS=2;  FIXTURE_MEM=4G;  FIXTURE_TIME=00:45:00
FETCH_CPUS=1;    FETCH_MEM=1G;    FETCH_TIME=00:30:00
ARRAY_CPUS=1;    ARRAY_MEM=2G;    ARRAY_TIME=01:00:00
# Merge of all 2.9 million rows has not been measured. The VM merge of
# 200,000 rows peaked at 189,376 KB; scaled by 14.5x that is about 2.7 GB.
MERGE_CPUS=1;    MERGE_MEM=8G;    MERGE_TIME=00:30:00

# ---------------------------------------------------------------- local overrides
_cfg_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "${_cfg_dir}/config.local.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_cfg_dir}/config.local.sh"
fi
unset _cfg_dir
