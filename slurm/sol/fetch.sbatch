#!/bin/bash -l
#
# fetch.sbatch - Sol step 3a: download ChEMBL 37 chemreps to ${WORK}/data
# on a compute node and verify its SHA-256 (scripts/fetch_data.py).
# Uses the Python of the environment rebuilt by fixture.sbatch.
#
# Submit with: bash slurm/sol/submit.sh fetch

#SBATCH --job-name=rdkit-sol-fetch
# Account, partition and QoS come from config.sh / config.local.sh via
# submit.sh. The placeholder makes a direct `sbatch` of this file fail.
#SBATCH --account=REPLACE_WITH_APPROVED_ACCOUNT
#SBATCH --partition=htc
#SBATCH --export=NONE
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:30:00

cd "${SLURM_SUBMIT_DIR}"
source slurm/sol/common.sh
job_header

require_file "${ENV_PREFIX}/bin/python" "Run the fixture step first; it builds the environment."
srun "${TIMER[@]}" "${ENV_PREFIX}/bin/python" scripts/fetch_data.py --dest-dir "$(dirname "$DATA")"
sha256sum "$DATA"
echo "Finished at $(date -Is)"
