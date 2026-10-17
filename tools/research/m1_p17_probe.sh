#!/usr/bin/env bash
# P17 event accounting for unchanged M0 and P16.2 completion variant.
# All four arms have identical P13 TaskRefs; speed diagnostics are NOT gates.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p17_scheduler_interactions"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
dub --version
python3 "$ROOT/tools/research/m1_p16_2_make_atomic_completion.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p16_2_pool.d"
python3 "$ROOT/tools/research/m1_p17_make_event_pair.py" control \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p17_control_pool.d"
python3 "$ROOT/tools/research/m1_p17_make_event_pair.py" atomic \
    "$BASE/generated/concurrency/research/m1_p16_2_pool.d" \
    "$BASE/generated/concurrency/research/m1_p17_atomic_pool.d"
python3 "$ROOT/tools/research/m1_p17_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

bash -n "$ROOT/tools/research/m1_p17_xps.sh"
python3 "$ROOT/tools/research/m1_p17_telemetry.py" --self-test

run_profile() {
    local mode="$1" profile="$2" count="$3" waves="$4"
    local rounds="$5" build="$6" seed="$7" label="$8"
    timeout --signal=TERM --kill-after=5s 170s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
            --config="$mode" -- --profile "$profile" --count "$count" \
            --waves "$waves" --warmup 1 --rounds "$rounds" \
            --seed "$seed" >"$TMP/$label-$mode.log"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$label-$mode.log" >"$TMP/$label-$mode.csv"
}
check() {
    local label="$1" minimum="$2"
    python3 "$ROOT/tools/research/m1_p17_compare.py" \
        "$TMP/$label-control.csv" "$TMP/$label-atomic.csv" \
        "$TMP/$label-trace-control.csv" "$TMP/$label-trace-atomic.csv" \
        --min-rows "$minimum"
}

for mode in control atomic trace-control trace-atomic; do
    run_profile "$mode" smoke 128 3 2 debug 332923710 smoke
done
check smoke 18

for mode in control atomic trace-control trace-atomic; do
    run_profile "$mode" native 64 2 2 debug 332923711 matrix
done
check matrix 90

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    for mode in control atomic trace-control trace-atomic; do
        run_profile "$mode" smoke 128 3 3 release 332923712 release
    done
    check release 24
fi
echo "P17 matching four-arm scheduler-event preflight: PASS"
