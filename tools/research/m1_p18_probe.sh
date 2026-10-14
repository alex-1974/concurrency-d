#!/usr/bin/env bash
# P18: identical-source workload, bounded idle grace, negative source guards.
# No CI speed thresholds. Runs original and candidate close/producer races.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
dub --version
python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" \
    "$P162/race/main.d" "$BASE/generated"

# Explicit fail-closed source-drift negative test.
cp "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/drift.d"
printf '\n// synthetic source drift for P18 negative qualification\n' >>"$TMP/drift.d"
if python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$TMP/drift.d" "$TMP/forbidden.d" >"$TMP/negative.log" 2>&1; then
    echo "P18 FAIL: modified original M0 was not rejected" >&2
    exit 1
fi
test ! -e "$TMP/forbidden.d"
bash -n "$ROOT/tools/research/m1_p18_xps.sh"
python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" self-test
# Exercise both real native worker pools while admitting zero TaskRefs.
# CI wall-clock/process-CPU values are not performance evidence.
for mode in idle-control idle-grace; do
    timeout --signal=TERM --kill-after=5s 80s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$mode" -- --settle-ms 60 --hold-ms 80 --rounds 1 \
        >"$TMP/$mode.log"
    test "$(grep -c '^measure,' "$TMP/$mode.log")" = 3
    grep -q '^P18_IDLE_PASS' "$TMP/$mode.log"
    grep -E '^(phase,workers,|measure,)' "$TMP/$mode.log" \
        >"$TMP/$mode.csv"
done
python3 "$ROOT/tools/research/m1_p18_idle_compare.py" --self-test
python3 "$ROOT/tools/research/m1_p18_idle_compare.py" \
    "$TMP/idle-control.csv" "$TMP/idle-grace.csv" --min-rows 3
bash -n "$ROOT/tools/research/m1_p18_idle_xps.sh"

run_profile() {
    local mode="$1" profile="$2" count="$3" waves="$4" rounds="$5"
    local build="$6" seed="$7" label="$8"
    timeout --signal=TERM --kill-after=5s 175s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config="$mode" -- --profile "$profile" --count "$count" \
        --waves "$waves" --warmup 1 --rounds "$rounds" --seed "$seed" \
        >"$TMP/$label-$mode.log"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$label-$mode.log" >"$TMP/$label-$mode.csv"
}
compare() {
    local prefix="$1" minimum="$2"
    python3 "$ROOT/tools/research/m1_p18_compare.py" \
        "$TMP/$prefix-control.csv" "$TMP/$prefix-grace.csv" \
        --min-rows "$minimum"
}
run_races() {
    local build="$1" rounds="$2"
    for mode in race-control race-grace; do
        timeout --signal=TERM --kill-after=5s 120s \
            dub run --root="$BASE" --compiler="$DC" --build="$build" \
            --config="$mode" -- "$rounds"
    done
}
run_races debug 5
run_profile control smoke 128 3 3 debug 332924510 smoke
run_profile grace smoke 128 3 3 debug 332924510 smoke
compare smoke 18

# All 45 target settings with bounded CI task counts, DMD and LDC.
run_profile control native 64 2 2 debug 332924511 matrix
run_profile grace native 64 2 2 debug 332924511 matrix
compare matrix 90

# Source-pinned P18 driver supports a separate long-task profile:
# 1/2/4 workers x 128/256/512/1024/2048 iterations x 8/64/256 ingress.
run_profile control long 16 2 1 debug 332924515 long
run_profile grace long 16 2 1 debug 332924515 long
compare long 90

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    run_profile control-optimized smoke 128 3 3 debug 332924512 O3
    run_profile grace-optimized smoke 128 3 3 debug 332924512 O3
    # DUB configuration is part of the generated filename; normalize only
    # the CI comparison aliases. The raw optimized logs remain preserved.
    cp "$TMP/O3-control-optimized.csv" "$TMP/O3-control.csv"
    cp "$TMP/O3-grace-optimized.csv" "$TMP/O3-grace.csv"
    compare O3 18
    # Check native release build/exec for the two no-task idle configurations.
    for mode in idle-control idle-grace; do
        timeout --signal=TERM --kill-after=5s 80s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- --settle-ms 60 --hold-ms 80 --rounds 1 \
            >"$TMP/release-$mode.log"
        grep -q '^P18_IDLE_PASS' "$TMP/release-$mode.log"
    done
    run_races release 5
    run_profile control smoke 128 3 3 release 332924513 release
    run_profile grace smoke 128 3 3 release 332924513 release
    compare release 18
fi

echo "P18 PASS source-drift guard, matching M0 results and adversarial close/parking races"
