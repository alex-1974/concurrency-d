#!/usr/bin/env bash
# P14 — exact pinned M0 source, generated event overlay, matched P13 workloads.
# No production code modification and no CI speed thresholds.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p14_scheduler_events"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
dub --version
python3 "$ROOT/tools/research/m1_p14_make_instrumented_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p14_pool.d"
python3 "$ROOT/tools/research/m1_p14_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"
bash -n "$ROOT/tools/research/m1_p14_xps.sh"

run_mode() {
    local config="$1" profile="$2" count="$3" waves="$4" rounds="$5"
    local build="$6" seed="$7" output="$8"
    timeout --signal=TERM --kill-after=5s 160s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
          --config="$config" -- \
          --profile "$profile" --count "$count" --waves "$waves" \
          --warmup 1 --rounds "$rounds" --seed "$seed" >"$TMP/$output.raw"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$output.raw" >"$TMP/$output.csv"
}
run_mode control smoke 128 2 2 debug 332922510 control-debug
run_mode trace smoke 128 2 2 debug 332922510 trace-debug
python3 "$ROOT/tools/research/m1_p14_compare.py" \
    "$TMP/control-debug.csv" "$TMP/trace-debug.csv"

# Full native 45-case matrix preflight with small inputs on both compilers.
run_mode control native 32 2 2 debug 332922511 control-matrix
run_mode trace native 32 2 2 debug 332922511 trace-matrix
python3 "$ROOT/tools/research/m1_p14_compare.py" \
    "$TMP/control-matrix.csv" "$TMP/trace-matrix.csv" --min-rows 90

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    # LDC optimizes the complete worker kernel while debug retains asserts.
    run_mode control-optimized smoke 128 3 3 debug 332922512 control-O3
    run_mode trace-optimized smoke 128 3 3 debug 332922512 trace-O3
    python3 "$ROOT/tools/research/m1_p14_compare.py" \
        "$TMP/control-O3.csv" "$TMP/trace-O3.csv"

    # Release: the P13 oracle uses explicit exceptions, never assert-only.
    run_mode control smoke 128 3 3 release 332922513 control-release
    run_mode trace smoke 128 3 3 release 332922513 trace-release
    python3 "$ROOT/tools/research/m1_p14_compare.py" \
        "$TMP/control-release.csv" "$TMP/trace-release.csv"
fi
echo "P14 exact-source matched control/instrumented M0 correctness: PASS"
