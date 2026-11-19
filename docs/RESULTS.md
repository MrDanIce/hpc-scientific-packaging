# Results

Real measurements only. Every number says where it was measured.
VM, GitHub Actions and ASU Sol results are kept in separate sections and
never combined.

## VM (single-node Slurm)

Lima VM, Ubuntu 24.04, aarch64, 4 CPUs, 7,922 MB memory, on a MacBook.
Slurm 23.11.4 (one node, `lima-hpc`, partition `debug`), Apptainer 1.5.5,
RDKit 2026.09.2. Accounting: `jobacct_gather/linux`; jobs set
`--acctg-freq=task=1` (memory sampled every second instead of every 30 s).
No cgroup task plugin, so memory requests are used for scheduling but not
enforced.

Dataset: ChEMBL 37 `chembl_37_chemreps.txt.gz` (2,897,819 molecules). The
"200,000-molecule subset" is its first 200,000 data rows.

### Test run used to choose resource requests (2026-11-18)

`sbatch slurm/run_single.sbatch` (job 3): one chunk of 10,000 molecules,
1 CPU, `--mem=2G`, `--time=00:15:00`.

| Measure | Value | Source |
|---|---|---|
| State | COMPLETED, exit code 0:0 | `sacct` |
| Wall time | 00:00:20 | `sacct` Elapsed |
| Wall time | 0:19.70 | `/usr/bin/time -v` |
| CPU time | 00:20.128 | `sacct` TotalCPU |
| Time inside the script | 18.0 s (the rest is container start-up plus loading Python and RDKit, not measured separately) | script summary |
| Peak memory, job step | 110,208 KB | `sacct` MaxRSS, step `3.0` |
| Peak memory, largest process | 68,764 KB | `/usr/bin/time -v` "Maximum resident set size" |
| Rows | 10,000 valid, 0 invalid | script summary |

The two memory numbers differ because `sacct` adds up all processes in the
step (`time`, Apptainer's starter, Python), while `/usr/bin/time` reports the
single largest process. Requests are based on the larger number.

### Requests chosen for each array task

| Request | Value | Reason |
|---|---|---|
| `--cpus-per-task` | 1 | CPU time (20.1 s) ≈ wall time (20 s): the script uses one CPU |
| `--mem` | 512M | ~4.7× the measured 108 MB, for larger molecules in later chunks |
| `--time` | 00:05:00 | 15× the measured 20 s; later chunks skip further into the compressed file |
| `--array` | `0-19%4` | 20 chunks of 10,000; at most 4 at once (4 CPUs) |

### Job array + merge: 200,000-molecule subset (2026-11-18)

`bash slurm/submit_subset.sh`: array job 6 (`--array=0-19%4`, 20 tasks x
10,000 molecules) and merge job 7 (`--dependency=afterok:6
--kill-on-invalid-dep=yes`). All 20 tasks and the merge: COMPLETED, exit 0:0.

| Measure | Value | Source |
|---|---|---|
| First task start → last task end | 21:05:52 → 21:07:29 = **97 s** | `sacct` Start/End |
| Merge start → end | 21:07:30 → 21:07:31 (started 1 s after the last task) | `sacct` Start/End |
| Submit-to-merged-file, wall clock | 21:05:52 → 21:07:31 = **99 s** | `sacct` Start/End |
| Per-task wall time | 16–24 s, mean 17.9 s | `sacct` Elapsed (20 tasks) |
| Sum of task wall times | 357 s (≈ 3.7× the 97 s array wall time, with 4 at once) | `sacct` Elapsed |
| Sum of task CPU time | 351.3 s | `sacct` TotalCPU |
| Per-task peak memory, job step | 108,492–112,268 KB | `sacct` MaxRSS, steps `6_*.0` |
| Per-task peak memory, largest process | 67,708–68,808 KB | `/usr/bin/time -v` in the task logs |
| Merge wall time | 0:00.76 | `/usr/bin/time -v` |
| Merge peak memory | 189,376 KB | `/usr/bin/time -v` (`sacct` MaxRSS was blank: the step ended before the first 1 s sample) |
| Rows | 200,000 read: 199,997 valid, 3 invalid | task logs and merge log |
| Merged output | `descriptors.tsv` 25 MB, 199,998 lines (with header) | `wc -l`, `du -h` |
| SHA-256 `descriptors.tsv` | `5c792afc47a67acdb5d4f1c499f7f940cd883cd565d0df626cfeaefec8b3971f` | `sha256sum` |
| SHA-256 `descriptors.invalid.tsv` | `91bcb991bcd95ee91306448513c5bee4e96431a75529da1be102cf4f922a520b` | `sha256sum` |

The 3 invalid records (all rejected by RDKit for an impossible valence;
recorded, not fatal):

| Line | ChEMBL ID | Reason |
|---|---|---|
| 41190 | CHEMBL4298947 | `Explicit valence for atom # 13 P, 7, is greater than permitted` (hexafluorophosphate written as `F[PH](F)(F)(F)(F)F`) |
| 52502 | CHEMBL4299174 | `Explicit valence for atom # 29 P, 7, is greater than permitted` (same anion) |
| 54956 | CHEMBL4299170 | `Explicit valence for atom # 91 P, 7, is greater than permitted` (same anion) |

Checks against the requests: peak memory per task (≤ 112,268 KB) used about
21% of the 512M request; the slowest task (24 s) used 8% of the 5-minute
limit. The merge used 189,376 KB and under 1 s, so its requests were
lowered from the initial estimate (1G, 10 min) to 512M and 5 min.

### Failure test: merge must not run if a task fails (2026-11-18)

Array job 28 on the 10-row test fixture (`CHUNK_SIZE=3`, `--array=0-4`), so
task 4 asks for rows 12 to 14, past the end of the file. Merge job 29 queued
with `--dependency=afterok:28 --kill-on-invalid-dep=yes`.

| Job | State | Exit code |
|---|---|---|
| 28_0 to 28_3 | COMPLETED | 0:0 |
| 28_4 | FAILED | 2:0 (`ERROR: chunk 4 (rows 12 to 14) is past the end of /data/sample_chemreps.tsv`) |
| 29 (merge) | CANCELLED | 0:0 (never started: no log file, no merged output) |

### One job vs. job array on the same 200,000 molecules (2026-11-18)

`sbatch --export=ALL,CHUNK_SIZE=200000,OUTDIR=results/single_200k slurm/run_single.sbatch`
(job 34): the whole subset as one chunk on 1 CPU. COMPLETED, exit 0:0.

| Measure | One job (job 34) | Array + merge (jobs 6, 7) | Source |
|---|---|---|---|
| Wall time | 00:05:20 (5:20.32) | 97 s array, 99 s including merge | `sacct` Elapsed (`/usr/bin/time`); `sacct` Start/End |
| CPU time | 05:20.691 | 351.3 s (sum of 20 tasks) | `sacct` TotalCPU |
| Peak memory, job step | 295,328 KB | 108,492–112,268 KB per task | `sacct` MaxRSS |
| Peak memory, largest process | 263,276 KB | 67,708–68,808 KB per task | `/usr/bin/time -v` |
| Rows | 199,997 valid, 3 invalid | 199,997 valid, 3 invalid | script summary / merge log |
| SHA-256 descriptors | `5c792afc…3971f` | `5c792afc…3971f` | `sha256sum` |
| SHA-256 invalid | `91bcb991…a520b` | `91bcb991…a520b` | `sha256sum` |

The outputs are byte-identical. With 4 tasks at once, the array finished in
99 s instead of 320 s (about 3.2× faster), at the cost of about 31 s more CPU
time in total (each of the 20 tasks starts its own container and skips to its
rows in the compressed file). One job holds all rows in memory, so its peak
memory is higher than any single array task's.

The script's own timer printed 320.8 s, slightly more than `/usr/bin/time`'s
5:20.32; the numbers above are copied as reported.

### Second run, from a clean clone, following the README (2026-11-18)

Still the VM (single-node Slurm). Fresh `git clone` of commit `8334413`
from GitHub into a new folder, with the new README.md and
TROUBLESHOOTING.md copied in, then every README step in order. The conda
environment was named `rdkit-descriptors-clean` so the existing one was
not touched, and removed afterwards. Conda packages were already in the
VM's package cache, so this did not test a fresh package download.

| README step | Result |
|---|---|
| 2. Environment from `conda-linux-aarch64.lock` | Created in 5.3 s (packages cached); `Ran 23 tests`, `OK` |
| 3. Download | 1 min 53 s; SHA-256 `ea6181ce…` |
| 4. First 1,000 molecules | 1000 valid, 0 invalid, 2.2 s; SHA-256 `f20d37c61d3113e5cce4a2e3f517836ceb85b9503de042cf9ef7e5fa332e440b` (same as the Milestone 2 run and its rerun) |
| 5. Image build | 1 min 13.6 s, `Ran 23 tests`, `OK`, `Build complete`; fixture `descriptors.tsv: OK`, `descriptors.invalid.tsv: OK` |
| 6. Single job (job 35) | COMPLETED 0:0, 00:00:20, MaxRSS 111,520 KB |
| 6. Array + merge (jobs 36, 37) | All 21 COMPLETED. First task start 22:15:16 → merge end 22:16:59 (103 s; the single job shared the CPUs at the start) |
| 6. Merged output | `descriptors.tsv` `5c792afc…`, `descriptors.invalid.tsv` `91bcb991…`: **identical to the first run (jobs 6, 7)** |
| 7. Module | `module avail`/`load`/`list`/`purge` worked from the new location; fixture SHA-256 `b5f1ff3b…` |

## GitHub Actions (ubuntu-24.04 runner, x86_64)

Workflow `.github/workflows/build.yml`, run 44462201596, triggered by the
push of commit `e7b6ba9` on 2026-11-19. Conclusion: success. Whole run
05:00:56Z → 05:02:03Z (67 s, from GitHub's run timestamps).

| Check | Result |
|---|---|
| Architecture | `uname -m`: x86_64 |
| Apptainer | 1.5.5, official `.deb`; checksum `25095d37…` verified (`OK`) |
| Lock file used in the build | `conda-linux-64.lock` (first real use of the x86_64 lock file) |
| Tests inside the image (`%test`) | RDKit 2026.09.2, `Ran 23 tests`, `OK` |
| Image size | 289,558,528 bytes (VM aarch64 image: 282,734,592 bytes) |
| Fixture run | 10 rows read, 6 valid, 4 invalid |
| `descriptors.tsv` SHA-256 | `b5f1ff3b…e4b6`: `OK` against `tests/fixtures/expected.sha256` |
| `descriptors.invalid.tsv` SHA-256 | `91f651e7…7292`: `OK` |
| Artifacts (kept until 2026-12-03) | `rdkit-descriptors-x86_64-sif` (289,558,684 bytes), `smoke-test-output` (863 bytes) |

The expected checksums were produced on the VM (aarch64), so the fixture
gives byte-identical output on aarch64 (VM) and x86_64 (GitHub Actions).
This covers the 10-row fixture only; the 200,000-molecule subset has not
been run on x86_64.

## ASU Sol

ASU Sol supercomputer, x86_64, run from login node `sol-login01`. Jobs are
submitted with `slurm/sol/submit.sh`. The account is a class account and is
not written here. Commands were run by the project owner on Sol; the output
was copied back by hand.

### Step 1: image copied from the VM (2026-11-18)

The GitHub Actions x86_64 image was copied from the VM to Sol with `scp`.

| Where | Size (bytes) | SHA-256 |
|---|---|---|
| VM copy, before `scp` | 289,558,528 | `80ca8f94…f93f7dc` |
| ASU Sol, `$WORK/images/rdkit-descriptors-x86_64.sif` | 289,558,528 | `80ca8f94…f93f7dc` |

The size is the same as the image size in the GitHub Actions run above.

### Step 2: fixture job (2026-11-18)

`bash slurm/sol/submit.sh fixture`, job 1991853, node `sc007`, 2 CPUs,
`--mem=4G`, QoS `class`. Requested partition `htc`: `sacct` SubmitLine shows
`--partition=htc`, but `sacct` and the job log show partition `public`. Sol
moved the job; `slurm/sol/config.sh` now asks for `public`.

| Check | Result | Source |
|---|---|---|
| State | COMPLETED, exit code 0:0 | `sacct` |
| Wall time, whole job | 00:02:39 (pending time not included) | `sacct` Elapsed |
| Apptainer | 1.5.4-1.el8 (`/usr/bin/apptainer`, no module loaded) | job log |
| Image checksum inside the job | `80ca8f94…f93f7dc` | job log |
| A2. Tests inside the image | RDKit 2026.09.2, `Ran 23 tests`, `OK` (12 s step) | job log, `sacct` step `.0` |
| A3. Fixture in the container | 10 rows read, 6 valid, 4 invalid; wall time 0:01.42; peak memory 60,476 KB | `/usr/bin/time -v` |
| A3. `descriptors.tsv` / `descriptors.invalid.tsv` | `b5f1ff3b…e4b6` `OK`, `91f651e7…7292` `OK` | `sha256sum -c` |
| B1. Environment rebuilt from `conda-linux-64.lock` | `module load mamba/latest` (mamba 2.9.0); 109 packages; "Environment created in 109 s"; Python 3.13.18, RDKit 2026.09.2 | job log |
| B1. Download | `Total download: 0 B`: the packages were already in the package cache, so 109 s does not include downloading | mamba output |
| B2. Tests in the rebuilt environment | `Ran 23 tests`, `OK` | job log |
| B3. Fixture in the rebuilt environment | 10 rows read, 6 valid, 4 invalid; `b5f1ff3b…e4b6` `OK`, `91f651e7…7292` `OK` | `sha256sum -c` |

The fixture output on Sol, both from the image and from the rebuilt conda
environment, is byte-identical to the VM (aarch64) and GitHub Actions
(x86_64) output. This covers the 10-row fixture only; ChEMBL data has not
been run on Sol yet.

### Step 3a: ChEMBL 37 download (2026-11-18)

`bash slurm/sol/submit.sh fetch`, job 1993260, node `sc006`, 1 CPU,
`--mem=1G` (from commit `38098d1`; `sbatch` noted that this is below Sol's
2048 MB per CPU minimum and used it as given). Requested partition `htc`;
`squeue` showed `public`.

| Measure | Value | Source |
|---|---|---|
| State | COMPLETED, exit code 0:0 | `sacct` |
| Wall time, whole job | 00:05:28 | `sacct` Elapsed |
| Download step | 5:21.01 wall time, 0.71 s user + 1.13 s system CPU | `/usr/bin/time -v` |
| Size | 292,540,141 bytes | `fetch_data.py` progress |
| SHA-256 | `ea6181ce…f696e7`, `Checksum OK`; matches the checksum pinned in `scripts/fetch_data.py` | job log |
| Peak memory, largest process | 27,716 KB | `/usr/bin/time -v` |
| Peak memory, job step | 30,520 KB | `sacct` MaxRSS, step `.0` |

The download speed depends on the network at that moment; the time is one
measurement, not a benchmark. Peak memory was far below 1G, so the new 2G
request in `config.sh` is only there to meet Sol's minimum.

### Step 3b: one array task over the first 200,000 molecules (2026-11-19)

`bash slurm/sol/submit.sh one-task` (commit `d142691`), array job 1999573,
task 0 (`--array=0%1`, `CHUNK_SIZE=200000`), node `sc006`, 1 CPU, `--mem=2G`,
`--time=01:00:00`, inside the image.

| Measure | Value | Source |
|---|---|---|
| State | COMPLETED, exit code 0:0 | `sacct` |
| Wall time, task | 00:07:08 | `sacct` Elapsed |
| Wall time, workload step | 7:02.01 (00:07:03 in `sacct`); script timer 417.4 s | `/usr/bin/time -v`, script summary |
| CPU time | 06:54.033 (374.25 s user + 39.56 s system, 98% of one CPU) | `sacct` TotalCPU, `/usr/bin/time -v` |
| Peak memory, job step | 324,880 KB | `sacct` MaxRSS, step `.0` |
| Peak memory, largest process | 264,944 KB | `/usr/bin/time -v` |
| Rows | 200,000 read: 199,997 valid, 3 invalid | script summary |
| SHA-256 `chunk_0000.tsv` | `5c792afc47a67acdb5d4f1c499f7f940cd883cd565d0df626cfeaefec8b3971f` | `sha256sum` |
| SHA-256 `chunk_0000.invalid.tsv` | `91bcb991bcd95ee91306448513c5bee4e96431a75529da1be102cf4f922a520b` | `sha256sum` |

Both checksums are identical to the VM output for the same 200,000 rows
(VM jobs 6, 7 and 34 above): the x86_64 image on Sol and the aarch64 image
on the VM give byte-identical results on real data, not only on the fixture.

For comparison only (different machines, one run each): the same rows as
one job on the VM (job 34) took 5:20.32 and peaked at 263,276 KB (largest
process). The cause of the time difference was not measured.

### Requests for the full run, from step 3b

| Setting | Value | Reason |
|---|---|---|
| `CHUNK_SIZE` | 400,000 (8 tasks: 7 × 400,000 + 1 × 97,819) | 8 tasks + 1 merge = 9 jobs, under QoS MaxSubmitPU 10 |
| `ARRAY_CPUS` | 1 | 98% of one CPU used |
| `ARRAY_MEM` | 2G | Memory grows with chunk size (one 200,000-row chunk: 324,880 KB job step), so 400,000 rows is expected near 650 MB; 2G is about 3× that and is also Sol's 2048 MB per CPU minimum |
| `ARRAY_TIME` | 01:00:00 | 200,000 rows took about 7 minutes, so 400,000 is expected near 15 minutes, plus time to skip further into the compressed file for later chunks; 1 hour is about 4× |
| `MAX_PARALLEL` | 2 | QoS MaxJobsPU 2 |

These are estimates from one task; the full run is the check.

### Step 4: full ChEMBL 37 run, job array + merge (2026-11-19)

`bash slurm/sol/submit.sh full`: array job 2001853 (`--array=0-7%2`, 8 tasks,
`CHUNK_SIZE=400000`, 1 CPU, `--mem=2G`, `--time=01:00:00` each, inside the
image) and merge job 2001881 (`--dependency=afterok:2001853
--kill-on-invalid-dep=yes`, 1 CPU, `--mem=8G`, `--time=00:30:00`). Partition
`public`, nodes `sc006` and `sc007`. Each job ran on one node.

All 8 tasks and the merge: COMPLETED, exit code 0:0.

| Task | Rows | Valid | Invalid | Wall time (`sacct`) | CPU time (`sacct`) | Peak memory, job step (`sacct` MaxRSS) | Node |
|---|---|---|---|---|---|---|---|
| 0 | 400,000 | 399,997 | 3 | 00:14:51 | 14:32.900 | 520,532 KB | sc006 |
| 1 | 400,000 | 400,000 | 0 | 00:18:52 | 18:33.952 | 521,652 KB | sc006 |
| 2 | 400,000 | 399,996 | 4 | 00:14:27 | 14:13.192 | 518,340 KB | sc007 |
| 3 | 400,000 | 399,997 | 3 | 00:15:16 | 15:02.924 | 520,236 KB | sc006 |
| 4 | 400,000 | 399,999 | 1 | 00:15:42 | 15:15.170 | 520,304 KB | sc006 |
| 5 | 400,000 | 400,000 | 0 | 00:14:49 | 14:33.151 | 520,968 KB | sc006 |
| 6 | 400,000 | 399,999 | 1 | 00:15:01 | 14:47.992 | 520,312 KB | sc007 |
| 7 | 97,819 | 97,816 | 3 | 00:03:57 | 03:50.698 | 209,360 KB | sc006 |
| **Total** | **2,897,819** | **2,897,804** | **15** | 6,775 s summed | 6,650.0 s summed | | |

Row counts are from the task logs (`grep "rows read"`); the logs were read
in file-name order, task 0 to 7.

| Measure | Value | Source |
|---|---|---|
| First task start → last task end | 00:19:45 → 01:19:47 = **1:00:02** (2 tasks at once) | `sacct` Start/End |
| Merge start | 01:19:47, the same second the last task ended | `sacct` Start |
| First task start → merged file | 00:19:45 → 01:20:07 = **1:00:22** (queue time before the first task not included) | `sacct` Start/End |
| Merge wall time | 0:13.58 (job 00:00:20) | `/usr/bin/time -v`, `sacct` |
| Merge peak memory | 2,566,960 KB job step; 2,539,580 KB largest process | `sacct` MaxRSS, `/usr/bin/time -v` |
| `descriptors.tsv` | 389,083,107 bytes, 2,897,805 lines (2,897,804 rows + header) | `ls -l`, `wc -l` |
| `descriptors.invalid.tsv` | 2,229 bytes, 16 lines (15 rows + header) | `ls -l`, `wc -l` |
| SHA-256 `descriptors.tsv` | `ee791e241e3f4ae0aa6c29169f0fb57152b9843bc7065d7f03fd92b82db3a611` | merge log |
| SHA-256 `descriptors.invalid.tsv` | `f67c0e4a37e859890a5768391c5965f513953ec3744da56ef514f7f48c3f5b4d` | merge log |

Checks:

- Rows read add up to 2,897,819, the number of data rows in the file
  (`TOTAL_MOLECULES` in `config.sh`, counted on the VM). Valid + invalid =
  2,897,804 + 15 = 2,897,819.
- Task 0 covers rows 0–399,999 and has 3 invalid rows, the same 3 found in
  rows 0–199,999 in step 3b and on the VM.
- Requests against use: array tasks peaked at 521,652 KB (about 25% of 2G)
  and the slowest took 18:52 (31% of 1 hour). The merge used 2.5 GB (31% of
  8G) and 20 s of 30 minutes. The estimates from step 3b (about 650 MB,
  about 15 minutes) were close for time and high for memory. Task 1 was
  about 4 minutes slower than the others; why was not checked.
- The full dataset has not been run on the VM or on GitHub Actions, so these
  checksums have nothing to be compared with yet. They are the result of one
  run on ASU Sol.
