# HPC Scientific Packaging

Packages one scientific workload so it runs the same way everywhere: a
pinned conda environment, an Apptainer container, Slurm batch and array
jobs, an Lmod module, and a GitHub Actions build with a smoke test.

The workload uses [RDKit](https://www.rdkit.org/) to compute 12 molecular
descriptors (molecular weight, logP, TPSA, QED, ring counts, ...) for
compounds from the public [ChEMBL](https://www.ebi.ac.uk/chembl/) database,
release 37.

> **Where this has been tested.** Slurm, Apptainer and Lmod were run on a
> **single-node Slurm installation inside a Linux VM** (Lima, Ubuntu 24.04,
> aarch64, 4 CPUs, 7.9 GB memory, on a MacBook). That is one machine acting
> as both controller and compute node. **It is a test setup, not a
> production HPC cluster.** The container build and smoke test also run on
> GitHub Actions (x86_64). The workload was then rerun on the **ASU Sol
> supercomputer** with the x86_64 image, including the full dataset; each Sol
> job ran on a single node.

| Environment | What ran there |
|---|---|
| VM (single-node Slurm) | Everything: environment, tests, container, Slurm jobs, module |
| GitHub Actions (ubuntu-24.04, x86_64) | Container build, unit tests inside the image, smoke test on the test fixture |
| ASU Sol supercomputer | Image copied and checked; fixture job (container and rebuilt conda environment); one task on 200,000 molecules (byte-identical to the VM); full ChEMBL 37 run (2,897,819 molecules) as an 8-task job array + merge. See `docs/RESULTS.md` |

## What is in this repository

```
environment.yml              conda environment: the packages asked for, exact versions
conda-linux-64.lock          every package pinned by file and checksum (x86_64)
conda-linux-aarch64.lock     the same for aarch64 (ARM, e.g. Apple Silicon VMs)
scripts/
  fetch_data.py              download ChEMBL 37 and verify its SHA-256
  compute_descriptors.py     the workload: one chunk of molecules -> descriptor table
  merge_results.py           merge the chunk files of a job array into one table
  setup_vm.sh                set up a single-node test VM (Ubuntu 24.04; see below)
container/tool.def           Apptainer definition file
slurm/
  run_single.sbatch          one job, one chunk
  run_array.sbatch           job array: one task per chunk
  merge.sbatch               merge job, runs only if every array task succeeded
  submit_subset.sh           submits the array and the merge for 200,000 molecules
modules/rdkit-descriptors/   Lmod module file
bin/compute-descriptors      command the module provides (runs the container)
tests/                       unit tests and a 10-row hand-written test fixture
.github/workflows/build.yml  CI: build the x86_64 image, smoke test, keep the image
data/README.md               dataset source, checksum and license (the data itself is not in git)
docs/RESULTS.md              all measured results, labeled by environment
docs/MODULES.md              module usage; module vs conda environment vs container
TROUBLESHOOTING.md           real errors hit during this project, with cause and fix
```

## Requirements

- Linux on x86_64 or aarch64.
- [Miniforge](https://github.com/conda-forge/miniforge) (provides `conda` and `mamba`).
  Tested with Miniforge 26.9.4-2 (conda 26.9.4).
- [Apptainer](https://apptainer.org/), for steps 5 to 7. Tested with 1.5.5.
- Slurm, for step 6. Tested with 23.11.4 (single node, with accounting so
  that `sacct` works).
- GNU time (`/usr/bin/time`), for step 6: the batch scripts use it to log
  each job's exact peak memory. On Debian/Ubuntu it is the `time` package
  (`sudo apt-get install time`).
- Lmod, for step 7. Tested with 8.6.19.
- Internet access, and about 4 GB of free disk. Measured on the VM: conda
  environment 796 MB, conda package cache up to 1.4 GB, image 283 MB,
  dataset 279 MB, results 76 MB.

**No cluster? Use a throwaway VM.** `scripts/setup_vm.sh` turns a fresh
Ubuntu 24.04 machine into a single-node Slurm test system: it installs
MUNGE, MariaDB, Slurm (with `slurmdbd` accounting), Lmod, Apptainer and
Miniforge, and writes their configuration. It uses `sudo` and changes
system configuration, so only run it on a VM you can throw away, and read
it first. Run it as your normal user: `bash scripts/setup_vm.sh`.

## Quick start

Run every command from the repository root. Commands that need RDKit use
`mamba run -n rdkit-descriptors ...`, which runs one command inside the
environment and works in any shell. In your own terminal you can instead
run `conda activate rdkit-descriptors` once and then leave out the
`mamba run -n rdkit-descriptors` part.

### 1. Get the code

```bash
git clone https://github.com/MrDanIce/hpc-scientific-packaging.git
cd hpc-scientific-packaging
```

### 2. Create the conda environment

Use the lock file for your CPU (`uname -m` prints `x86_64` or `aarch64`).
The lock file pins every package to an exact file and checksum, so you get
the same environment that was tested.

```bash
uname -m
mamba create -n rdkit-descriptors --file conda-linux-64.lock        # x86_64
mamba create -n rdkit-descriptors --file conda-linux-aarch64.lock   # aarch64
```

Run only the line for your CPU. At the end, mamba suggests
`mamba activate rdkit-descriptors`; that only works if mamba's shell hook
is set up (see `TROUBLESHOOTING.md`). Use `conda activate` or `mamba run`
as described above instead. Then run the tests:

```bash
mamba run -n rdkit-descriptors python -m unittest discover -s tests -v
```

Expected: `Ran 23 tests` and `OK`.

### 3. Download the dataset

```bash
mamba run -n rdkit-descriptors python scripts/fetch_data.py
sha256sum data/chembl_37_chemreps.txt.gz
```

The script downloads `chembl_37_chemreps.txt.gz` (292,540,141 bytes) into
`data/` and ends with `Checksum OK` (this took about 2 minutes on the VM). `sha256sum` should print
`ea6181ce8dc7af41974e35b92e1febb0c9dcbe2c62f7ccc4a5d983ac19f696e7`.
Source, license and attribution are in [`data/README.md`](data/README.md).

### 4. Run the workload on a small sample

```bash
mamba run -n rdkit-descriptors python scripts/compute_descriptors.py \
    --input data/chembl_37_chemreps.txt.gz \
    --chunk-size 1000 --chunk-index 0 \
    --output results/sample_0000.tsv
sha256sum results/sample_0000.tsv
```

`--chunk-size N --chunk-index K` selects molecules K×N to (K+1)×N−1. The
script writes two files: `results/sample_0000.tsv` (descriptors, sorted by
ChEMBL ID, 4 decimal places) and `results/sample_0000.invalid.tsv`
(molecules RDKit could not read, with the reason; they do not stop the run).

On the VM this printed `1000 rows read, 1000 valid, 0 invalid` and the
SHA-256 `f20d37c61d3113e5cce4a2e3f517836ceb85b9503de042cf9ef7e5fa332e440b`.
(This sample has only been checked on aarch64.)

### 5. Build and run the container

```bash
apptainer build container/rdkit-descriptors.sif container/tool.def
```

The build creates the environment from the lock file for your CPU and runs
the 23 unit tests inside the image; it ends with `Build complete`. It does
not need root. On GitHub Actions the whole job, including the build, took
about 1 minute; on the VM, with conda packages already downloaded, the
build took 74 s. Then run the test fixture inside the container and compare
the output with the expected checksums:

```bash
mkdir -p results/container_check
apptainer exec --cleanenv \
    --bind "$PWD/tests/fixtures:/data:ro" \
    --bind "$PWD/results/container_check:/out" \
    container/rdkit-descriptors.sif \
    python /opt/app/scripts/compute_descriptors.py \
    --input /data/sample_chemreps.tsv --output /out/descriptors.tsv
(cd results/container_check && sha256sum -c ../../tests/fixtures/expected.sha256)
```

Expected: `descriptors.tsv: OK` and `descriptors.invalid.tsv: OK`.
`--bind host_folder:container_folder` makes a host folder visible inside
the container (`:ro` = read-only); `--cleanenv` keeps your shell's
environment variables out of the container.

An image only runs on the CPU type it was built for: build it on the
machine type where it will run.

### 6. Run it with Slurm

Slurm does not create the folder for job log files, so create it first.
The scripts use the cluster's default partition and account; on a cluster
that requires them, add `-p <partition>` and `-A <account>` to `sbatch`.

One job, one chunk of 10,000 molecules:

```bash
mkdir -p logs
sbatch slurm/run_single.sbatch       # prints: Submitted batch job <ID>
squeue                               # the job, state R while it runs
sacct -j <ID> --format=JobID,JobName,State,ExitCode,Elapsed,TotalCPU,ReqMem,MaxRSS
```

When it has finished, `sacct` shows `COMPLETED` and exit code `0:0`. The
log is `logs/rdkit-single_<ID>.out`.

The 200,000-molecule subset (the first 200,000 molecules of the file) as a
job array of 20 tasks × 10,000 molecules, at most 4 at a time, plus a merge
job that starts only if all 20 tasks succeed:

```bash
bash slurm/submit_subset.sh          # prints the array and merge job IDs
squeue                               # up to 4 tasks R, the rest PD, merge PD (Dependency)
sacct -j <array ID>,<merge ID> -X --format=JobID%10,JobName%12,State,ExitCode,Elapsed
sha256sum results/subset200k/descriptors.tsv
```

Waiting tasks show the reason `JobArrayTaskLimit` (held back by the
4-at-a-time limit) or `Resources` (no free CPU, for example while the
single job above is still running). The array takes about 2 minutes on
the VM. When `squeue` is empty, `sacct` should show every task and the
merge as `COMPLETED` `0:0`.

On the VM the merged file had the SHA-256
`5c792afc47a67acdb5d4f1c499f7f940cd883cd565d0df626cfeaefec8b3971f` in
two separate runs.

`run_array.sbatch` uses 4 tasks at a time because the test VM has 4 CPUs.
On a bigger system, change `MAX_PARALLEL` in `slurm/submit_subset.sh`.

### 7. Use the module

```bash
module use "$PWD/modules"
module avail                         # shows rdkit-descriptors/2026.09.2
module load rdkit-descriptors
module list
compute-descriptors --input tests/fixtures/sample_chemreps.tsv --output results/module_check.tsv
sha256sum results/module_check.tsv
module purge
```

Expected: `1) rdkit-descriptors/2026.09.2` from `module list`,
`10 rows read, 6 valid, 4 invalid` from `compute-descriptors`, and the
SHA-256 `b5f1ff3bccd476a0082703afa30a4d0845574d0a733d9d228a146dd60268e4b6`.
After `module purge`, `compute-descriptors` is no longer found.
`module use` only lasts for the current shell.

`compute-descriptors` runs the workload inside the image, so build the
image (step 5) first. See [`docs/MODULES.md`](docs/MODULES.md) for when a
module, a conda environment or a container is the better choice.

## Results

All measured results, with the commands and job IDs, are in
[`docs/RESULTS.md`](docs/RESULTS.md). Summary:

**VM (single-node Slurm)**, RDKit 2026.09.2, Apptainer 1.5.5, Slurm 23.11.4:

| Run | Result |
|---|---|
| Test run, 10,000 molecules, 1 job | 20 s wall time, 20.1 s CPU time, 110,208 KB peak memory (`sacct` MaxRSS) |
| 200,000 molecules, 1 job, 1 CPU | 5 min 20 s; 295,328 KB peak memory |
| 200,000 molecules, array of 20 tasks, 4 at a time, plus merge | 99 s from first task start to merged file; 108,492–112,268 KB peak memory per task |
| Array vs. one job | Byte-identical output (`5c792afc…`); 199,997 valid, 3 invalid molecules |
| Merge after a failed task | Merge job cancelled, never started (tested on purpose) |
| Native vs. container, fixture and first 1,000 molecules | Byte-identical output |

The array's resource requests (1 CPU, 512 MB, 5 minutes per task) were
chosen from the 10,000-molecule test run.

**GitHub Actions (ubuntu-24.04, x86_64):** the image builds from
`conda-linux-64.lock`, the 23 tests pass inside it, and the test fixture's
output matches the checksums produced on the VM (aarch64). So the fixture
gives byte-identical results on both CPU types. Larger inputs have not been
compared across CPU types.

## Limitations

- **Single-node Slurm in a VM, not a production cluster.** Job scheduling,
  arrays, dependencies and accounting are real Slurm, but there is one
  node, no shared file system and no network between nodes.
- **Memory limits are not enforced on the VM.** It has no cgroup task
  plugin, so `--mem` is used for scheduling only. A real cluster would kill
  a job that goes over its request.
- **Memory is sampled.** `sacct` MaxRSS comes from samples taken once per
  second (set with `--acctg-freq=task=1`); very short steps may show no
  value. The job logs also record the exact peak from `/usr/bin/time -v`.
- **The Slurm array covers the 200,000-molecule subset**, not all
  2,897,819 molecules in ChEMBL 37.
- **One image per CPU type.** The x86_64 image comes from CI; the aarch64
  image was built on the VM.
- **SMILES are used as given.** Salts and mixtures are not standardized, so
  their descriptors include every component.

## Data and license

The data comes from ChEMBL release 37 (EMBL-EBI) under
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). It is
downloaded by `scripts/fetch_data.py` and is not stored in this repository.
Descriptor tables computed from it are derived works under the same
license. See [`data/README.md`](data/README.md) for the checksum and the
required citation.

## Troubleshooting

[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) lists the real errors hit while
building this project, where each happened, its cause and its fix.
