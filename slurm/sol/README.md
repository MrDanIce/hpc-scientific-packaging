# Running on ASU Sol

Scripts for rerunning the workload on the ASU Sol supercomputer, using the
x86_64 image built by GitHub Actions (images are not built on Sol).

**Status:** prepared, not yet run on Sol. The scripts were rehearsed on the
VM (single-node Slurm) with a local override of the settings; that checked
the scripts, not Sol. Sol results go in the "ASU Sol" section of
`docs/RESULTS.md` only after they have really been produced there.

## Files

| File | What it does |
|---|---|
| `config.sh` | All settings: account (placeholder), partition `htc`, QoS, paths under `/scratch/$USER/hpc-scientific-packaging`, chunk size, tasks at once, resource requests |
| `submit.sh` | The only way to submit. Adds `--account`, `--partition`, `--qos`, `--export=NONE` and the requests from `config.sh`. Refuses while the account is the placeholder or a time request is not under 4 hours |
| `common.sh` | Shared start of every job script |
| `fixture.sbatch` | Image tests and fixture in the container; conda environment rebuilt on the compute node with `module load mamba/latest`, its tests and the fixture. Both fixture outputs are checked against `tests/fixtures/expected.sha256` (the checksums from GitHub Actions and the VM) |
| `fetch.sbatch` | Downloads ChEMBL 37 on a compute node and verifies its SHA-256 |
| `array.sbatch` | One array task = one chunk, inside the image |
| `merge.sbatch` | Merges chunk files; queued with `afterok`, so it runs only if every array task succeeded |

Login nodes only run `submit.sh` (checks, `mkdir`, `sbatch`), `squeue`,
`sacct`, file copies and `less`. Everything else runs in jobs. No job
script uses `sleep`.

## Step 0 findings (ASU Sol login node `sol-login01`, 2026-11-18)

Read-only checks, run by hand on the login node:

| Check | Output |
|---|---|
| Architecture | `x86_64` |
| `/scratch/$USER` | exists (`drwxr-x---`) |
| Apptainer | `/usr/bin/apptainer`, `apptainer version 1.5.4-1.el8`; module `apptainer/1.4.5` also available |
| mamba | module `mamba/latest` available |
| Partition `htc` | `up`, time limit `4:00:00`, 212 nodes, 48+ CPUs, 513000+ MB |
| `/usr/bin/time` | present |
| Slurm associations | only a class account, QoS `class`; no association with QoS `public` |
| QoS `class` limits | MaxWall `1-00:00:00`, **MaxJobsPU 2** (running at once), **MaxSubmitPU 10** (in the queue) |

The project owner chose to run on that class account with QoS `class`
(2026-11-18). The account and QoS are set in `slurm/sol/config.local.sh`
on Sol, which git ignores, so the account name is not published:

```bash
SOL_ACCOUNT="<account>"
SOL_QOS="<qos>"
```

## Steps

| Step | Where | Command |
|---|---|---|
| 0. Checks | Sol login node | read-only commands: Apptainer, mamba module, partition, accounts, `/scratch` |
| 1. Image | VM, then Sol | download the GitHub Actions image, copy it to `$WORK/images/`, compare SHA-256 on both sides |
| 2. Fixture | Sol job | `bash slurm/sol/submit.sh fixture` |
| 3a. Data | Sol job | `bash slurm/sol/submit.sh fetch` |
| 3b. One task | Sol job | `bash slurm/sol/submit.sh one-task`: one task over molecules 0–199,999; its output is compared with the VM result for the same rows (`5c792afc…`) |
| — | | set `CHUNK_SIZE` and the `ARRAY_*` requests in `config.sh` from step 3b's `sacct` numbers |
| 4. Full release | Sol jobs | `bash slurm/sol/submit.sh full`: all chunks (8 × 400,000 by default) and the merge |

Submit from the repository root on Sol. `--export=NONE` means jobs do not
inherit your shell's variables; they read `config.sh` instead. Inside the
jobs, `SLURM_EXPORT_ENV=ALL` is set so that `srun` steps keep the `PATH`
from `module load`.

Because of MaxSubmitPU 10 (each array task counts as one job), a full run
is at most 9 jobs: 8 array tasks and the merge. `submit.sh` refuses a run
that would exceed `MAX_SUBMIT_JOBS`. MaxJobsPU 2 is why `MAX_PARALLEL` is 2.
