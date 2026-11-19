# Modules, conda environments and containers

## Using the module

The repository includes an Lmod module, `rdkit-descriptors/2026.09.2`
(`modules/rdkit-descriptors/2026.09.2.lua`). Loading it gives you one
command, `compute-descriptors`, which runs the workload inside the
Apptainer image (`bin/compute-descriptors` calls `apptainer run`). The
version is the RDKit version inside the image.

Build the image first (see `container/tool.def`), then, from the repository root:

```bash
module use "$PWD/modules"       # add this repository's modules to MODULEPATH
module avail                    # lists rdkit-descriptors/2026.09.2
module load rdkit-descriptors
module list                     # 1) rdkit-descriptors/2026.09.2
compute-descriptors --input tests/fixtures/sample_chemreps.tsv --output results/module_fixture.tsv
module purge                    # unload everything; compute-descriptors is gone from PATH
```

`module use` only lasts for the current shell. To make it permanent, add
the `module use` line to `~/.bashrc`.

The module adds the repository's `bin/` folder to `PATH` and sets
`RDKIT_DESCRIPTORS_SIF` to the image's path. It finds the repository from
its own location, so it works wherever the repository is cloned. Loading
fails with a clear message if the image has not been built yet.

Input and output files must be in a folder the container can see. Apptainer
mounts your home folder, `/tmp` and the current folder by default. For
other folders, list them in `APPTAINER_BIND`, for example
`export APPTAINER_BIND=/scratch/$USER`.

**Tested on:** VM (single-node Slurm), Lmod 8.6.19, Apptainer 1.5.5:
`module avail`, `load`, `list` and `purge` worked as shown above, and
`compute-descriptors` on the test fixture gave the expected output
(SHA-256 `b5f1ff3b…`, the same as `tests/fixtures/expected_descriptors.tsv`).
Not yet tested on ASU Sol or inside a Slurm job.

## Which one to use

These are three different tools, and this project uses all three:

| | What it is | In this project |
|---|---|---|
| **Module (Lmod)** | A small file that changes your shell's environment (`PATH`, variables) when loaded, and undoes it when unloaded. It does not contain software; it points to software installed somewhere else. | `rdkit-descriptors` puts `compute-descriptors` on `PATH` |
| **Conda environment** | A folder with its own Python and packages, installed by conda/mamba. | `rdkit-descriptors`, built from the lock files |
| **Container (Apptainer)** | One image file holding a whole Linux userland: the OS libraries, the conda environment and the scripts. | `container/rdkit-descriptors.sif`, built from the same lock files |

So a module is an **interface** (how users find and switch software),
while a conda environment and a container are ways of **installing** it.
Here the module is a front end to the container.

### Measured on the VM (single-node Slurm)

| | Conda environment | Container image |
|---|---|---|
| Size | 796 MB (`du -sh`) | 282,734,592 bytes (compressed SquashFS) |
| Number of files | 21,784 (`find \| wc -l`) | 1 |
| Time outside the script's own timer | (not measured) | about 1.7 s: job 3 took 19.70 s in total, the script reported 18.0 s. This covers container start-up **and** loading Python and RDKit; the two were not measured separately |
| Output on the fixture and on the first 1,000 ChEMBL molecules | identical | identical |

Starting 20 containers for the 20 array tasks cost CPU time: the array used
351.3 s of CPU time in total against 320.7 s for one job over the same
200,000 molecules. Part of that difference is container start-up and part
is each task skipping to its rows in the compressed file; the two were not
measured separately. See `docs/RESULTS.md`.

### When each is the better choice

**Module** is the better choice when:
- The cluster's staff have built the software for that machine, for example
  MPI, CUDA or compilers built for the cluster's network and CPUs. A
  container cannot easily match a build that is tuned to the hardware it
  runs on.
- Users need to switch between versions (`module load tool/1.2` vs
  `tool/1.3`) or combine several tools in one shell.
- You want to give users a short command and hide how it is installed,
  as the module here does for the container.

**Conda environment** is the better choice when:
- You are developing: you change code or packages often and want to see
  the result straight away, without rebuilding an image.
- The cluster has no Apptainer, or you cannot build images.
- Start-up time matters for many very short runs.

Its weaknesses: 21,784 small files is hard on shared parallel file systems
(every Python start reads many of them), it counts against home-folder
quotas, and it only stays reproducible if it is rebuilt from the lock file.

**Container** is the better choice when:
- Results must be reproducible across machines: the same image file gives
  the same software everywhere it runs (here: byte-identical output inside
  and outside the container).
- The software needs OS libraries or a Linux version the cluster does not
  have.
- Many jobs start at once: one 270 MB file is easier on a shared file system
  than 21,784 small files.
- You want to hand the whole tool to someone else, or keep an exact copy of
  what produced a published result.

Its weaknesses: an image built for one CPU architecture does not run on the
other (the VM's image is aarch64; Sol needs x86_64), every change needs a
rebuild, and each run has a start-up cost (not measured on its own here;
container start-up plus loading Python and RDKit took about 1.7 s).

**In this project:** the conda environment is for development and tests,
the container is what Slurm jobs run, and the module gives users one
command without needing to know about Apptainer.
