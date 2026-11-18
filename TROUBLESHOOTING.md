# Troubleshooting

Real errors hit while building this project, with their cause and fix.
Each entry says where it happened:

- **VM (single-node Slurm):** Lima VM running Ubuntu 24.04 (aarch64) on a MacBook.
- **ASU Sol:** the ASU Sol supercomputer.

| Environment | Error (exact) | Cause | Fix |
|---|---|---|---|
| VM (single-node Slurm) | After installing only the `slurm-client` package, `sinfo` failed with `fetch_config: DNS SRV lookup failed` and `Could not establish a configuration source` | Slurm had no configuration on this VM. With no `slurm.conf` file, the client tries to find a controller through a DNS SRV record, and none exists. | Ran `scripts/setup_vm.sh`, which installs and configures single-node Slurm. Afterwards `sinfo`, `srun` and `sacct` worked. |
| VM (single-node Slurm) | `SyntaxError: invalid character '│' (U+2502)` when running a `python -c "..."` check through `mamba run`. Pasting a block of several commands the same way also gave `remove: The following argument was not expected: │` from `mamba env remove`. | The commands were copied from a terminal window where they had wrapped across lines. The copy included the window's border character `│` (U+2502) and line breaks, which became extra arguments or part of the Python code. The `mamba env remove` failed, so the environment was never removed and the "rebuild" test did not really run. | Type commands by hand or copy them from a plain-text source, one command at a time, and keep `python -c` one-liners short enough not to wrap. Check `mamba env list` afterwards to confirm what really happened. Not a problem with the environment itself. |
