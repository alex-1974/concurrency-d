#!/usr/bin/env bash
# P16.1 three-arm sampled completion probe, exact source, checked semantics.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p16_completion_sampling"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
"$DC" --version
dub --version

python3 "$ROOT/tools/research/m1_p16_make_sampled_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p16_pool.d"
python3 "$ROOT/tools/research/m1_p16_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"
bash -n "$ROOT/tools/research/m1_p16_xps.sh"

run_case() {
    local config="$1" profile="$2" count="$3" waves="$4"
    local rounds="$5" build="$6" seed="$7" label="$8"
    timeout --signal=TERM --kill-after=5s 175s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config="$config" -- --profile "$profile" \
        --count "$count" --waves "$waves" \
        --warmup 1 --rounds "$rounds" --seed "$seed" >"$TMP/$label.raw"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$label.raw" >"$TMP/$label.csv"
}

check_case() {
    local label="$1"
    python3 "$ROOT/tools/research/m1_p16_compare.py" \
        "$TMP/$label-control.csv" "$TMP/$label-null.csv" \
        "$TMP/$label-sample.csv"
}

run_case control smoke 128 3 2 debug 332922910 debug-control
run_case null-clock smoke 128 3 2 debug 332922910 debug-null
run_case sampled smoke 128 3 2 debug 332922910 debug-sample
check_case debug

# All 45 native scenario combinations are qualified under BOTH pinned
# compilers. Small count may produce zero samples: source conservation
# verifies exact per-worker sampling periods and complete task results.
run_case control native 32 2 2 debug 332922911 full-control
run_case null-clock native 32 2 2 debug 332922911 full-null
run_case sampled native 32 2 2 debug 332922911 full-sample
python3 "$ROOT/tools/research/m1_p16_compare.py" \
    "$TMP/full-control.csv" "$TMP/full-null.csv" \
    "$TMP/full-sample.csv" --min-rows 90

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    run_case control-optimized smoke 128 3 3 debug 332922912 O3-control
    run_case null-clock-optimized smoke 128 3 3 debug 332922912 O3-null
    run_case sampled-optimized smoke 128 3 3 debug 332922912 O3-sample
    check_case O3

    run_case control smoke 128 3 3 release 332922913 release-control
    run_case null-clock smoke 128 3 3 release 332922913 release-null
    run_case sampled smoke 128 3 3 release 332922913 release-sample
    check_case release
fi
echo "P16.1 sampled completion and null-clock matched semantics PASS"
