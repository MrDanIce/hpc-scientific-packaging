#!/usr/bin/env bash
#
# submit.sh - submit one step of the ASU Sol run. Runs on the login node and
# only does light work there: checks, mkdir and sbatch.
#
#   bash slurm/sol/submit.sh fixture    step 2:  image + rebuilt env on the test fixture
#   bash slurm/sol/submit.sh fetch      step 3a: download ChEMBL 37 on a compute node
#   bash slurm/sol/submit.sh one-task   step 3b: a single array task (the last full chunk)
#   bash slurm/sol/submit.sh full       step 4:  every chunk + merge (+ 200,000-row comparison merge)
#
# All settings, including the account and resource requests, are in
# slurm/sol/config.sh.

set -euo pipefail

cd "$(dirname "$0")/../.."          # repository root
source slurm/sol/config.sh

die() { echo "ERROR: $*" >&2; exit 1; }

step=${1:-}
[[ -n "$step" ]] || die "usage: bash slurm/sol/submit.sh fixture|fetch|one-task|full"

if [[ -z "$SOL_ACCOUNT" || "$SOL_ACCOUNT" == "REPLACE_WITH_APPROVED_ACCOUNT" ]]; then
    die "SOL_ACCOUNT is still the placeholder. Set SOL_ACCOUNT and SOL_QOS in slurm/sol/config.local.sh (see slurm/sol/README.md)."
fi

# Every request must be under 4 hours (HH:MM:SS).
for t in "$FIXTURE_TIME" "$FETCH_TIME" "$ARRAY_TIME" "$MERGE_TIME"; do
    [[ "$t" =~ ^([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]] || die "time '$t' must be HH:MM:SS"
    secs=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
    (( secs < 4 * 3600 )) || die "time '$t' is not under 4 hours"
done

mkdir -p "$LOGDIR"

COMMON=(--parsable --account="$SOL_ACCOUNT" --partition="$SOL_PARTITION"
        --qos="$SOL_QOS" --export=NONE)

# submit <sbatch options and script> -> prints the job ID
submit() {
    local out
    out=$(sbatch "${COMMON[@]}" "$@")
    echo "${out%%;*}"
}

N_CHUNKS=$(( (TOTAL_MOLECULES + CHUNK_SIZE - 1) / CHUNK_SIZE ))
SACCT_FMT="JobID%16,JobName%18,State,ExitCode,Start,End,Elapsed,TotalCPU,ReqCPUS,ReqMem,MaxRSS,NodeList"

case "$step" in
fixture)
    [[ -f "$SIF" ]] || die "image not found: $SIF (step 1)"
    id=$(submit --cpus-per-task="$FIXTURE_CPUS" --mem="$FIXTURE_MEM" --time="$FIXTURE_TIME" \
                --output="$LOGDIR/%x_%j.out" slurm/sol/fixture.sbatch)
    echo "Fixture job: $id"
    echo "Log:   $LOGDIR/rdkit-sol-fixture_${id}.out"
    echo "After: sacct -j $id --format=$SACCT_FMT"
    ;;
fetch)
    [[ -x "$ENV_PREFIX/bin/python" ]] || die "environment not found: $ENV_PREFIX (run the fixture step first)"
    id=$(submit --cpus-per-task="$FETCH_CPUS" --mem="$FETCH_MEM" --time="$FETCH_TIME" \
                --output="$LOGDIR/%x_%j.out" slurm/sol/fetch.sbatch)
    echo "Fetch job: $id"
    echo "Log:   $LOGDIR/rdkit-sol-fetch_${id}.out"
    echo "After: sacct -j $id --format=$SACCT_FMT"
    ;;
one-task)
    [[ -f "$SIF" ]]  || die "image not found: $SIF (step 1)"
    [[ -f "$DATA" ]] || die "data not found: $DATA (step 3a)"
    # The last FULL chunk: it skips furthest into the compressed file, so it
    # is the slowest full-size task.
    task=$(( TOTAL_MOLECULES / CHUNK_SIZE - 1 ))
    (( task >= 0 )) || die "CHUNK_SIZE is larger than the dataset"
    id=$(submit --array="${task}%1" \
                --cpus-per-task="$ARRAY_CPUS" --mem="$ARRAY_MEM" --time="$ARRAY_TIME" \
                --output="$LOGDIR/%x_%A_%a.out" \
                slurm/sol/array.sbatch "$RESULTS/one_task/chunks")
    echo "One-task test: array job $id, task $task ($CHUNK_SIZE molecules)"
    echo "Log:   $LOGDIR/rdkit-sol-array_${id}_${task}.out"
    echo "After: sacct -j $id --format=$SACCT_FMT"
    ;;
full)
    [[ -f "$SIF" ]]  || die "image not found: $SIF (step 1)"
    [[ -f "$DATA" ]] || die "data not found: $DATA (step 3a)"
    out="$RESULTS/chembl37_full"
    array_id=$(submit --array="0-$(( N_CHUNKS - 1 ))%${MAX_PARALLEL}" \
                      --cpus-per-task="$ARRAY_CPUS" --mem="$ARRAY_MEM" --time="$ARRAY_TIME" \
                      --output="$LOGDIR/%x_%A_%a.out" \
                      slurm/sol/array.sbatch "$out/chunks")
    # afterok:<array ID> needs EVERY task to exit 0; if one fails the
    # dependency can never be met and --kill-on-invalid-dep cancels the merge.
    merge_id=$(submit --dependency="afterok:${array_id}" --kill-on-invalid-dep=yes \
                      --cpus-per-task="$MERGE_CPUS" --mem="$MERGE_MEM" --time="$MERGE_TIME" \
                      --output="$LOGDIR/%x_%j.out" \
                      slurm/sol/merge.sbatch "$N_CHUNKS" "$out/chunks" "$out/descriptors.tsv")
    echo "Array job: $array_id ($N_CHUNKS tasks x $CHUNK_SIZE molecules, at most $MAX_PARALLEL at once)"
    echo "Merge job: $merge_id (runs only if all $N_CHUNKS tasks succeed)"
    ids="$array_id,$merge_id"
    # The first 200,000 molecules can be compared with the VM result
    # (SHA-256 5c792afc..., docs/RESULTS.md) if they are whole chunks.
    if (( 200000 % CHUNK_SIZE == 0 && 200000 <= TOTAL_MOLECULES )); then
        cmp_id=$(submit --dependency="afterok:${array_id}" --kill-on-invalid-dep=yes \
                        --cpus-per-task=1 --mem=2G --time=00:15:00 \
                        --output="$LOGDIR/%x_%j.out" --job-name=rdkit-sol-merge200k \
                        slurm/sol/merge.sbatch "$(( 200000 / CHUNK_SIZE ))" "$out/chunks" \
                        "$out/subset200k_descriptors.tsv")
        echo "Comparison merge of the first 200,000 molecules: $cmp_id"
        ids="$ids,$cmp_id"
    fi
    echo "Watch: squeue -u \$USER"
    echo "After: sacct -j $ids --format=$SACCT_FMT"
    ;;
*)
    die "unknown step '$step' (fixture|fetch|one-task|full)"
    ;;
esac
