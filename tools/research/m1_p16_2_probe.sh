#!/usr/bin/env bash
# P16.2 exact-source candidate vs unchanged M0; NO CI speed gate.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
dub --version
python3 "$ROOT/tools/research/m1_p16_2_sc_handshake.py"
python3 "$ROOT/tools/research/m1_p16_2_make_atomic_completion.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p16_2_pool.d"
python3 "$ROOT/tools/research/m1_p16_2_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"
bash -n "$ROOT/tools/research/m1_p16_2_xps.sh"

run_profile() {
    local mode="$1" profile="$2" count="$3" waves="$4" rounds="$5"
    local build="$6" seed="$7" label="$8"
    timeout --signal=TERM --kill-after=5s 170s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
            --config="$mode" -- --profile "$profile" --count "$count" \
            --waves "$waves" --warmup 1 --rounds "$rounds" --seed "$seed" \
            >"$TMP/$label.log"
    grep -E '^(phase,round,|warmup,|measure,)' "$TMP/$label.log" \
        >"$TMP/$label.csv"
}

# Closing after completion and closing with last task still running,
# plus multiple producers racing with close, are run in both modes.
for mode in race-control race-atomic; do
    timeout --signal=TERM --kill-after=5s 120s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config="$mode" -- 5
done

run_profile control smoke 128 3 3 debug 332923210 debug-control
run_profile atomic smoke 128 3 3 debug 332923210 debug-atomic
python3 "$ROOT/tools/research/m1_p16_2_check.py" \
    "$TMP/debug-control.csv" "$TMP/debug-atomic.csv"

# Full target matrix with small correctness workloads on both compilers.
run_profile control native 64 2 2 debug 332923211 native-control
run_profile atomic native 64 2 2 debug 332923211 native-atomic
python3 "$ROOT/tools/research/m1_p16_2_check.py" \
    "$TMP/native-control.csv" "$TMP/native-atomic.csv" --min-rows 90

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    run_profile control-optimized smoke 128 3 3 debug 332923212 O3-control
    run_profile atomic-optimized smoke 128 3 3 debug 332923212 O3-atomic
    python3 "$ROOT/tools/research/m1_p16_2_check.py" \
        "$TMP/O3-control.csv" "$TMP/O3-atomic.csv"

    for mode in race-control race-atomic; do
        timeout --signal=TERM --kill-after=5s 120s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
                --config="$mode" -- 5
    done
    run_profile control smoke 128 3 3 release 332923213 release-control
    run_profile atomic smoke 128 3 3 release 332923213 release-atomic
    python3 "$ROOT/tools/research/m1_p16_2_check.py" \
        "$TMP/release-control.csv" "$TMP/release-atomic.csv"
fi
echo "P16.2 candidate and unchanged M0 semantic qualification PASS (no performance gate)"
