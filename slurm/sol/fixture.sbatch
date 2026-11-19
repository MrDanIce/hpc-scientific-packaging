#!/bin/bash -l
#
# fixture.sbatch - Sol step 2: check the GitHub Actions image and a conda
# environment rebuilt on this compute node, using the 10-row test fixture.
#
#   A. Container: `apptainer test` (unit tests inside the image), then the
#      fixture through the image, compared with tests/fixtures/expected.sha256
#      (the checksums GitHub Actions and the VM produced).
#   B. Native: rebuild the conda environment from the lock file for this
#      CPU (conda-linux-64.lock on x86_64) with `module load mamba/latest`,
#      run the unit tests, then the fixture, compared with the same
#      checksums.
#
# Submit with: bash slurm/sol/submit.sh fixture
# (submit.sh adds --account, --output and the resource requests from config.sh)

#SBATCH --job-name=rdkit-sol-fixture
# Account, partition and QoS come from config.sh / config.local.sh via
# submit.sh. The placeholder makes a direct `sbatch` of this file fail.
#SBATCH --account=REPLACE_WITH_APPROVED_ACCOUNT
#SBATCH --partition=htc
#SBATCH --export=NONE
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:45:00

cd "${SLURM_SUBMIT_DIR}"
source slurm/sol/common.sh
job_header

require_file "$SIF" "Copy the GitHub Actions image there first (step 1)."
OUT="${RESULTS}/fixture"
mkdir -p "${OUT}/container" "${OUT}/native"
FIXTURES="${SLURM_SUBMIT_DIR}/tests/fixtures"

echo
echo "== A1. Image checksum"
sha256sum "$SIF"

echo
echo "== A2. Unit tests inside the image (apptainer test)"
srun apptainer test "$SIF"

echo
echo "== A3. Fixture in the container"
srun "${TIMER[@]}" apptainer exec --cleanenv \
    --bind "${FIXTURES}:/data:ro" \
    --bind "${OUT}/container:/out" \
    "$SIF" \
    python /opt/app/scripts/compute_descriptors.py \
        --input /data/sample_chemreps.tsv --output /out/descriptors.tsv
(cd "${OUT}/container" && sha256sum descriptors.tsv descriptors.invalid.tsv \
    && sha256sum -c "${FIXTURES}/expected.sha256")

echo
case "$(uname -m)" in
    x86_64)  LOCK=conda-linux-64.lock ;;
    aarch64) LOCK=conda-linux-aarch64.lock ;;
    *) echo "ERROR: no lock file for $(uname -m)" >&2; exit 1 ;;
esac
echo "== B1. Rebuild the conda environment from ${LOCK}"
if [[ -n "${MAMBA_MODULE}" ]]; then
    module load "${MAMBA_MODULE}"
fi
echo "$(mamba --version | head -n1)  (module ${MAMBA_MODULE})"
export CONDA_PKGS_DIRS="${CONDA_PKGS}"
# Remove any earlier copy so this is a rebuild from scratch.
case "${ENV_PREFIX}" in
    "${WORK}"/envs/*) rm -rf "${ENV_PREFIX}" ;;
    *) echo "ERROR: refusing to delete ${ENV_PREFIX} (not under ${WORK}/envs)" >&2; exit 1 ;;
esac
start=$(date +%s)
srun mamba create --yes --prefix "${ENV_PREFIX}" --file "${LOCK}"
echo "Environment created in $(( $(date +%s) - start )) s at ${ENV_PREFIX}"
"${ENV_PREFIX}/bin/python" -c "import sys, rdkit; print('Python', sys.version.split()[0], 'RDKit', rdkit.__version__)"

echo
echo "== B2. Unit tests in the rebuilt environment"
PYTHONNOUSERSITE=1 srun "${ENV_PREFIX}/bin/python" -m unittest discover -s tests

echo
echo "== B3. Fixture in the rebuilt environment"
PYTHONNOUSERSITE=1 srun "${ENV_PREFIX}/bin/python" scripts/compute_descriptors.py \
    --input tests/fixtures/sample_chemreps.tsv --output "${OUT}/native/descriptors.tsv"
(cd "${OUT}/native" && sha256sum descriptors.tsv descriptors.invalid.tsv \
    && sha256sum -c "${FIXTURES}/expected.sha256")

echo
echo "All fixture checks passed at $(date -Is)"
