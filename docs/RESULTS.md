# Results

Real measurements only. Every number says where it was measured.
VM and ASU Sol results are kept in separate sections and never combined.

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
