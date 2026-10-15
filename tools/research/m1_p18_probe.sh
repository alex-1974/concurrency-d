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
# Exhaustively enumerate bounded worker/external-event interleavings with
# the original generation+Condition predicate text pinned to M0. The
# deliberately broken no-generation mutant MUST have counterexamples.
python3 "$ROOT/tools/research/m1_p18_park_boundary_model.py" \
    --source "$ROOT/source/concurrency/internal/submission_pool.d" \
    --self-test
# Deterministic native publication/search/park/notify correctness
# boundaries for both unchanged original M0 and bounded P18 research clone.
# These are not benchmarks and must not change source scheduler semantics.
python3 "$ROOT/tools/research/m1_p18_park_boundary_make_fixture.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" "$BASE/generated"
for boundary in park-boundary-control park-boundary-grace; do
    timeout --signal=TERM --kill-after=5s 80s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$boundary" >"$TMP/$boundary.log"
    grep -q '^P18_PARK_BOUNDARY_PASS scenarios=96' "$TMP/$boundary.log"
done

# Source change must invalidate both copied variants before output.
cp "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/modified-M0.d"
printf '\n// source pin negative\n' >>"$TMP/modified-M0.d"
if python3 "$ROOT/tools/research/m1_p18_park_boundary_make_fixture.py" \
    "$TMP/modified-M0.d" "$TMP/forbidden-park-fixture" \
    >"$TMP/park-pin-negative.log" 2>&1; then
    echo "ERROR: P18 park boundary generator accepted drifted M0" >&2
    exit 1
fi
test ! -e "$TMP/forbidden-park-fixture"

# One semaphore blocker and 16 independently submitted siblings; source-pinned
# real pool M0/P18; exactly-once and bounded progress, NOT benchmark timing.
for fairness in fairness-control fairness-grace; do
    timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$fairness" >"$TMP/$fairness.log"
    grep -q '^P18_FAIRNESS_PASS scenarios=16$' "$TMP/$fairness.log"
done
# Separately timestamped research-only P13 driver: NOT the historical
# uninstrumented timing baseline. Both arms get identical phase instrumentation.
python3 "$ROOT/tools/research/m1_p18_phase_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"

# Source-locked producer cadence is a deliberately changed producer workload,
# never a rewritten scheduler. Verify all three compiler specializations.
python3 "$ROOT/tools/research/m1_p18_cadence_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"
python3 "$ROOT/tools/research/m1_p18_cadence_compare.py" --self-test
bash -n "$ROOT/tools/research/m1_p18_cadence_xps.sh"
for cadence in cadence0 cadence8 cadence64; do
    for arm in control grace; do
        timeout --signal=TERM --kill-after=5s 175s \
            dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config="$cadence-$arm" -- --profile cadencefocus \
            --count 128 --waves 2 --warmup 1 --rounds 1 \
            --seed 332925050 >"$TMP/$cadence-$arm.log"
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$TMP/$cadence-$arm.log" >"$TMP/$cadence-$arm.csv"
        test "$(grep -c '^warmup,' "$TMP/$cadence-$arm.csv")" = 6
        test "$(grep -c '^measure,' "$TMP/$cadence-$arm.csv")" = 6
    done
done
python3 "$ROOT/tools/research/m1_p18_cadence_smoke.py" "$TMP" --count 128 --waves 2

# Require the cadence generator to fail before writing output if the original
# P13 driver changes in any byte (even a comment).
cp "$P13/consumer/main.d" "$TMP/cadence-drifted-driver.d"
printf '\n// deliberately drifted driver for a fail-closed test\n' >>"$TMP/cadence-drifted-driver.d"
if python3 "$ROOT/tools/research/m1_p18_cadence_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$TMP/cadence-drifted-driver.d" "$P162/race/main.d" \
    "$TMP/forbidden-cadence" >"$TMP/cadence-source-negative.log" 2>&1; then
    echo "P18 ERROR: cadence generator accepted modified P13 driver" >&2
    exit 1
fi
test ! -e "$TMP/forbidden-cadence"

# Separately generated, source-locked event-only copies. They are never
# compared for runtime speed with the existing uninstrumented M0/P18 pair.
for mode in control grace; do
    if [[ "$mode" == control ]]; then
        input="$ROOT/source/concurrency/internal/submission_pool.d"
    else
        input="$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
    fi
    python3 "$ROOT/tools/research/m1_p18_512_make_event_pair.py" "$mode" \
        "$input" "$BASE/generated/concurrency/research/m1_p18_trace_${mode}_pool.d"
done
python3 "$ROOT/tools/research/m1_p18_512_make_trace_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

# PI counters are a NEW event-only overlay of source-pinned trace copies.
# Preserve both old trace and uninstrumented M0/P18 exactly as recorded.
for mode in control grace; do
    if [[ "$mode" == control ]]; then
        input="$ROOT/source/concurrency/internal/submission_pool.d"
    else
        input="$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
    fi
    python3 "$ROOT/tools/research/m1_p18_pi_make_pair.py" "$mode" \
        "$input" "$BASE/generated/concurrency/research/m1_p18_pi_${mode}_pool.d"
done
python3 "$ROOT/tools/research/m1_p18_pi_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

# Phase-boundary copies must reject any modified P13 driver, not just
# preserve the TaskRef checksum under a mismatched generated experiment.
cp "$P13/consumer/main.d" "$TMP/phase-driver-drift.d"
printf '\n// injected phase-driver source drift\n' >>"$TMP/phase-driver-drift.d"
if python3 "$ROOT/tools/research/m1_p18_phase_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$TMP/phase-driver-drift.d" "$P162/race/main.d" \
    "$TMP/forbidden-phase" >"$TMP/phase-negative.log" 2>&1; then
    echo "P18 FAIL: phase generator accepted modified P13 driver" >&2
    exit 1
fi
test ! -e "$TMP/forbidden-phase"

# Explicit fail-closed source-drift negative test.
cp "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/drift.d"
printf '\n// synthetic source drift for P18 negative qualification\n' >>"$TMP/drift.d"
if python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$TMP/drift.d" "$TMP/forbidden.d" >"$TMP/negative.log" 2>&1; then
    echo "P18 FAIL: modified original M0 was not rejected" >&2
    exit 1
fi
test ! -e "$TMP/forbidden.d"

cp "$BASE/generated/concurrency/research/m1_p18_grace_pool.d" "$TMP/grace-drift.d"
printf '\n// synthetic P18 trace provenance drift\n' >>"$TMP/grace-drift.d"
if python3 "$ROOT/tools/research/m1_p18_512_make_event_pair.py" grace \
    "$TMP/grace-drift.d" "$TMP/forbidden-trace.d" >"$TMP/trace-negative.log" 2>&1; then
    echo "P18 FAIL: modified grace input was not rejected" >&2
    exit 1
fi
test ! -e "$TMP/forbidden-trace.d"
if python3 "$ROOT/tools/research/m1_p18_pi_make_pair.py" grace \
    "$TMP/grace-drift.d" "$TMP/forbidden-pi.d" >"$TMP/pi-negative.log" 2>&1; then
    echo "P18 FAIL: PI overlay accepted altered P18 source" >&2
    exit 1
fi
test ! -e "$TMP/forbidden-pi.d"

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
bash -n "$ROOT/tools/research/m1_p18_512_abba_xps.sh"
bash -n "$ROOT/tools/research/m1_p18_512_trace_xps.sh"
bash -n "$ROOT/tools/research/m1_p18_512_single_ingress_xps.sh"
# Balanced one/two/four-core affinity study is source/TaskRef identical,
# needs no privileged kernel tracepoints and never changes producer policy.
bash -n "$ROOT/tools/research/m1_p18_affinity_xps.sh"
python3 "$ROOT/tools/research/m1_p18_affinity_compare.py" --self-test
bash -n "$ROOT/tools/research/m1_p18_pi_xps.sh"
# Event-only single-core versus four-core parking/batching follow-up.
# Synthetic corrupted Condition.wait counter must fail closed.
bash -n "$ROOT/tools/research/m1_p18_pi_affinity_xps.sh"
python3 "$ROOT/tools/research/m1_p18_pi_affinity_compare.py" --self-test
bash -n "$ROOT/tools/research/m1_p18_phase_xps.sh"
bash -n "$ROOT/tools/research/m1_p18_sched_perf_xps.sh"
python3 "$ROOT/tools/research/m1_p18_sched_check.py" --self-test
python3 "$ROOT/tools/research/m1_p18_sched_proc_sampler.py" self-test
python3 "$ROOT/tools/research/m1_p18_sched_proc_sampler.py" probe >"$TMP/proc-capability.json"
bash -n "$ROOT/tools/research/m1_p18_sched_proc_xps.sh"
python3 "$ROOT/tools/research/m1_p18_phase_compare.py" --self-test
python3 "$ROOT/tools/research/m1_p18_single_ingress_check.py" --self-test
python3 "$ROOT/tools/research/m1_p18_512_trace_compare.py" --self-test

# Trace arms execute EXACT TaskRef work, but their wall-clock time is
# instrumentation-confounded and MUST NEVER qualify scheduler speed.
for mode in trace-control trace-grace; do
    timeout --signal=TERM --kill-after=5s 175s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$mode" -- --profile focus512 --count 64 \
        --waves 2 --warmup 1 --rounds 1 --seed 332924518 \
        >"$TMP/$mode.log"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$mode.log" >"$TMP/$mode.csv"
done
python3 "$ROOT/tools/research/m1_p18_512_trace_compare.py" \
    "$TMP/trace-control.csv" "$TMP/trace-grace.csv" --min-rows 54

# Exactly one-worker producer/ingress event snapshot, no wall-clock claim.
for mode in pi-control pi-grace; do
    timeout --signal=TERM --kill-after=5s 175s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$mode" -- --profile singleingress --count 16 \
        --waves 2 --warmup 1 --rounds 1 --seed 332924522 \
        >"$TMP/$mode.log"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$mode.log" >"$TMP/$mode.csv"
done
python3 "$ROOT/tools/research/m1_p18_pi_compare.py" \
    "$TMP/pi-control.csv" "$TMP/pi-grace.csv" \
    --min-rows 24 --count 16 --waves 2


# Exact TaskRef and phase conservation on both instrumented arms.
for mode in phase-control phase-grace; do
    timeout --signal=TERM --kill-after=5s 175s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$mode" -- --profile singleingress --count 16 \
        --waves 2 --warmup 1 --rounds 1 --seed 332924524 \
        >"$TMP/$mode.log"
    grep -E '^(phase,round,|warmup,|measure,)' \
        "$TMP/$mode.log" >"$TMP/$mode.csv"
done
python3 "$ROOT/tools/research/m1_p18_phase_compare.py" \
    "$TMP/phase-control.csv" "$TMP/phase-grace.csv" \
    --min-rows 24 --count 16 --waves 2

# One-worker external Linux perf scheduler trace uses TWO generated-only
# one-case profiles. CI verifies TaskRef equality and source generation;
# perf tracepoints require native host privileges and are NOT run in CI.
for profile in sched8 sched2048; do
    for mode in control grace; do
        timeout --signal=TERM --kill-after=5s 175s \
            dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config="$mode" -- --profile "$profile" --count 16 \
            --waves 2 --warmup 2 --rounds 1 --seed 332924526 \
            >"$TMP/$profile-$mode.log"
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$TMP/$profile-$mode.log" >"$TMP/$profile-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p18_sched_check.py" \
        "$TMP/$profile-control.csv" "$TMP/$profile-grace.csv" \
        --profile "$profile" --count 16 --waves 2 --rounds 1
done

# Negative oracle: a fabricated full-inbox event must fail against both the
# producer's unchanged retry count and submit outcome conservation.
python3 - "$TMP/pi-grace.csv" "$TMP/pi-mutated.csv" <<'PY'
import csv
import sys
with open(sys.argv[1], newline="") as source:
    rd = csv.DictReader(source)
    fields = rd.fieldnames
    rows = list(rd)
rows[0]["submitFull"] = str(int(rows[0]["submitFull"]) + 1)
with open(sys.argv[2], "w", newline="") as target:
    wr = csv.DictWriter(target, fieldnames=fields)
    wr.writeheader()
    wr.writerows(rows)
PY
if python3 "$ROOT/tools/research/m1_p18_pi_compare.py" \
    "$TMP/pi-control.csv" "$TMP/pi-mutated.csv" \
    --min-rows 24 --count 16 --waves 2 >"$TMP/pi-invalid.log" 2>&1; then
    echo "P18 FAIL: corrupted producer/ingress event trace was accepted" >&2
    exit 1
fi

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

# Unmodified P13 kernel; generated-only focus512 (128/512/1024) regression
# study with 1/2/4 workers and ingress 8/64/256, 27 cases.
run_profile control focus512 16 2 1 debug 332924516 focus512
run_profile grace focus512 16 2 1 debug 332924516 focus512
compare focus512 54

# One-worker exact P13 TaskRef producer/ingress study, 12 cells:
# 128/512/1024 iterations x 8/64/256/2048 ingress capacities.
# The 2048-slot case cannot reject the 16-task CI wave as full.
for mode in control grace; do
    run_profile "$mode" singleingress 16 2 1 debug 332924520 singleingress
    python3 "$ROOT/tools/research/m1_p18_single_ingress_check.py" \
        "$TMP/singleingress-$mode.csv" --count 16 --waves 2 \
        --warmup 1 --rounds 1
done
compare singleingress 24

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
    # Compile and execute the same real progress fixture with -release.
    # No required state transition may be hidden inside assert().
    for fairness in fairness-control fairness-grace; do
        dub build --root="$BASE" --compiler="$DC" --build=release \
            --config="$fairness" >"$TMP/release-$fairness-build.log" 2>&1 || {
            cat "$TMP/release-$fairness-build.log" >&2
            exit 1
        }
        timeout --signal=TERM --kill-after=5s 90s \
            "$BASE/m1-p18-idle-grace" \
            >"$TMP/release-$fairness.log" 2>&1 || {
            cat "$TMP/release-$fairness.log" >&2
            exit 1
        }
        grep -q '^P18_FAIRNESS_PASS scenarios=16$' "$TMP/release-$fairness.log"
    done
    # Same fixed work and checksum in whole LDC release.
    run_profile control focus512 16 2 1 release 332924517 release-focus512
    run_profile grace focus512 16 2 1 release 332924517 release-focus512
    compare release-focus512 54
    # Event-only trace module and exact-work oracle in whole LDC release.
    # Its measured wall times are NOT speed evidence.
    for mode in trace-control trace-grace; do
        timeout --signal=TERM --kill-after=5s 175s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- --profile focus512 --count 64 \
            --waves 2 --warmup 1 --rounds 1 --seed 332924519 \
            >"$TMP/release-$mode.log"
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$TMP/release-$mode.log" >"$TMP/release-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p18_512_trace_compare.py" \
        "$TMP/release-trace-control.csv" \
        "$TMP/release-trace-grace.csv" --min-rows 54
    # Independent LDC whole-release single-ingress semantic smoke.
    for mode in control grace; do
        run_profile "$mode" singleingress 32 2 1 release 332924521 release-singleingress
        python3 "$ROOT/tools/research/m1_p18_single_ingress_check.py" \
            "$TMP/release-singleingress-$mode.csv" --count 32 --waves 2 \
            --warmup 1 --rounds 1
    done
    compare release-singleingress 24
    # LDC release: separately instrumented, no throughput qualification.
    for mode in pi-control pi-grace; do
        timeout --signal=TERM --kill-after=5s 175s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- --profile singleingress --count 32 \
            --waves 2 --warmup 1 --rounds 1 --seed 332924523 \
            >"$TMP/release-$mode.log"
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$TMP/release-$mode.log" >"$TMP/release-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p18_pi_compare.py" \
        "$TMP/release-pi-control.csv" "$TMP/release-pi-grace.csv" \
        --min-rows 24 --count 32 --waves 2
    # Release-mode scheduler-trace case generator smoke. The kernel-event
    # profiler is host-specific and MUST NOT run inside shared CI.
    for profile in sched8 sched2048; do
        for mode in control grace; do
            timeout --signal=TERM --kill-after=5s 175s \
                dub run --root="$BASE" --compiler="$DC" --build=release \
                --config="$mode" -- --profile "$profile" --count 32 \
                --waves 2 --warmup 2 --rounds 1 --seed 332924527 \
                >"$TMP/release-$profile-$mode.log"
            grep -E '^(phase,round,|warmup,|measure,)' \
                "$TMP/release-$profile-$mode.log" \
                >"$TMP/release-$profile-$mode.csv"
        done
        python3 "$ROOT/tools/research/m1_p18_sched_check.py" \
            "$TMP/release-$profile-control.csv" \
            "$TMP/release-$profile-grace.csv" \
            --profile "$profile" --count 32 --waves 2 --rounds 1
    done
    # Three deliberately different producer admission workloads must all
    # compile under LDC whole-release with identical M0/P18 TaskRef results.
    for cadence in cadence0 cadence8 cadence64; do
        for arm in control grace; do
            timeout --signal=TERM --kill-after=5s 175s \
                dub run --root="$BASE" --compiler="$DC" --build=release \
                --config="$cadence-$arm" -- --profile cadencefocus \
                --count 128 --waves 2 --warmup 1 --rounds 1 \
                --seed 332925051 >"$TMP/release-$cadence-$arm.log"
            grep -E '^(phase,round,|warmup,|measure,)' \
                "$TMP/release-$cadence-$arm.log" \
                >"$TMP/release-$cadence-$arm.csv"
        done
    done
    python3 "$ROOT/tools/research/m1_p18_cadence_smoke.py" "$TMP" \
        --prefix release- --count 128 --waves 2
    # Separate LDC release COMPILE from native EXECUTION. A slow LDC
    # optimization is not evidence of a lost Condition wakeup. Only the
    # prebuilt executable gets a strictly bounded native test timeout.
    for boundary in park-boundary-control park-boundary-grace; do
        echo "P18 release park-boundary compile: $boundary"
        dub build --root="$BASE" --compiler="$DC" --build=release \
            --config="$boundary" \
            >"$TMP/release-$boundary-build.log" 2>&1 || {
            cat "$TMP/release-$boundary-build.log" >&2
            exit 1
        }
        echo "P18 release park-boundary execute: $boundary"
        timeout --signal=TERM --kill-after=5s 45s \
            "$BASE/m1-p18-idle-grace" \
            >"$TMP/release-$boundary-execute.log" 2>&1 || {
            cat "$TMP/release-$boundary-execute.log" >&2
            echo "P18 native boundary execution failed $boundary" >&2
            exit 1
        }
        grep -q '^P18_PARK_BOUNDARY_PASS scenarios=96' \
            "$TMP/release-$boundary-execute.log"
    done
    # Phase-boundary snapshots also compile and conserve work in LDC release.
    # Phase-timed binaries are NOT direct historical throughput baselines.
    for mode in phase-control phase-grace; do
        timeout --signal=TERM --kill-after=5s 175s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- --profile singleingress --count 32 \
            --waves 2 --warmup 1 --rounds 1 --seed 332924525 \
            >"$TMP/release-$mode.log"
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$TMP/release-$mode.log" >"$TMP/release-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p18_phase_compare.py" \
        "$TMP/release-phase-control.csv" "$TMP/release-phase-grace.csv" \
        --min-rows 24 --count 32 --waves 2
    run_races release 5
    run_profile control smoke 128 3 3 release 332924513 release
    run_profile grace smoke 128 3 3 release 332924513 release
    compare release 18
fi

echo "P18 PASS source-drift guard, matching M0 results and adversarial close/parking races"
