#!/usr/bin/env bash
# P18 source-locked native XPS: single-worker CPU-affinity intervention.
# Exact same M0/P18 release binaries on 1, 2, and 4 PHYSICAL-core CPU masks.
# No production scheduler, producer, task or timing instrumentation changes.
# Exact M0/P18 TaskRefs; 2048-slot ingress cannot reject a 2048-task wave.
# Uninstrumented whole-release control / grace / grace / control processes.
# Reversed BAAB in alternating sessions. No production source changes.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-affinity-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P18_AFFINITY_SESSIONS:-6}"
CPUSET="0,1,2,3"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
BIN_DIR=""
MONITOR=""
cleanup() {
    if [[ -n "$MONITOR" ]]; then
        kill "$MONITOR" 2>/dev/null || true
        wait "$MONITOR" 2>/dev/null || true
        MONITOR=""
    fi
    if [[ -n "$BIN_DIR" ]]; then rm -rf -- "$BIN_DIR"; fi
}
trap cleanup EXIT

if [[ "$SESSIONS" != "6" ]]; then
    echo "P18 affinity qualification requires exactly 6 balanced sessions" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 AFFINITY refuses to overwrite: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset timeout python3 sha256sum tar cmp; do
    command -v "$cmd" >/dev/null
done
# The user XPS topology must prove the requested CPUs are distinct physical
# cores; SMT siblings would invalidate the predeclared affinity intervention.
# No affinity settings are modified globally; taskset wraps only test processes.
declare -A physical=()
for cpu in 0 1 2 3; do
    taskset -c "$cpu" true
    core_path="/sys/devices/system/cpu/cpu$cpu/topology/core_id"
    package_path="/sys/devices/system/cpu/cpu$cpu/topology/physical_package_id"
    if [[ ! -r "$core_path" || ! -r "$package_path" ]]; then
        echo "P18 affinity cannot qualify CPU $cpu physical topology" >&2
        exit 3
    fi
    physical_key="$(cat "$package_path"):$(cat "$core_path")"
    if [[ -v "physical[$physical_key]" ]]; then
        echo "P18 affinity CPU 0..3 contain SMT sibling cores ($physical_key)" >&2
        exit 3
    fi
    physical["$physical_key"]=1
done
# Linux cpuset/cgroup policy may silently narrow a requested mask.
# Verify the EFFECTIVE mask of a child process equals every proposed mask.
for cpumask in 0 0,1 0,1,2,3; do
    taskset -c "$cpumask" python3 - "$cpumask" <<'PY'
import os
import sys
expected = {int(x) for x in sys.argv[1].split(",")}
observed = os.sched_getaffinity(0)
if observed != expected:
    raise SystemExit(
        f"P18 CPU-affinity intervention unavailable: "
        f"requested={sorted(expected)} effective={sorted(observed)}")
PY
done

python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,diagnostics,telemetry}
DEST="$(cd "$DEST" && pwd)"
BIN_DIR="$(mktemp -d)"

# The two measured binaries are prebuilt and immutable throughout A/B/B/A.
for mode in control grace; do
    dub build --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode"
    cp "$BASE/m1-p18-idle-grace" "$BIN_DIR/$mode"
    sha256sum "$BIN_DIR/$mode" >>"$DEST/diagnostics/binary-sha256.txt"
done
if cmp -s "$BIN_DIR/control" "$BIN_DIR/grace"; then
    echo "P18 AFFINITY fail closed: identical compiled variants" >&2
    exit 3
fi

# Qualify close/producer races at both concurrency-affinity extremes.
for race_cpu in 0 0,1,2,3; do
    for mode in race-control race-grace; do
        taskset -c "$race_cpu" timeout --signal=TERM --kill-after=5s 150s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- 12
    done
done

{
    echo "study=P18 one-worker CPU-mask intervention; uninstrumented A/B/B/A"
    echo "started_utc=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "M0_source_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_affinity_cases=cpu1:0;cpu2:0,1;cpu4:0,1,2,3"
    echo "physical_distinct_cores_0_1_2_3=true"
    echo "balanced_affinity_case_order=six_session_latin_and_reverse"
    echo "same_immutable_binary_per_arm_across_all_affinities=true"
    echo "individual_worker_pinning=false"
    echo "sessions=$SESSIONS"
    echo "process_order=ABBA_alternating_with_BAAB"
    echo "profile=singleingress"
    echo "iterations=128,512,1024"
    echo "workers=1"
    echo "ingress=8,64,256,2048"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "warmups=2"
    echo "measured_rounds=5"
    echo "target_iteration=512"
    echo "diagnostic_control_iterations=128,1024"
    echo "ingress_2048_equals_tasks_per_wave_no_full_retries_expected=true"
    echo "ingress_capacity_changes_worker_producer_interaction=true"
    echo "no_speed_thresholds=true"
    echo "thermals=observe_not_admission"
    echo "no_qualified_energy_measurement=true"
    echo "cpu_mask_changes_turbo_scheduler_and_concurrent_core_capacity=true"
    echo "not_a_direct_producer_yield_cost_measurement=true"
    if command -v lscpu >/dev/null; then lscpu; fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332925000 + session * 101))"
    if (( session % 2 == 1 )); then
        modes=(control grace grace control)
    else
        modes=(grace control control grace)
    fi
    # Six-session balanced design: each affinity mask appears twice in
    # each chronological block position (and both ABBA/BAAB directions).
    case "$session" in
        1) mask_order=(1 2 4) ;;
        2) mask_order=(4 2 1) ;;
        3) mask_order=(2 4 1) ;;
        4) mask_order=(1 4 2) ;;
        5) mask_order=(4 1 2) ;;
        6) mask_order=(2 1 4) ;;
    esac
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    echo "${mask_order[*]}" >"$DEST/diagnostics/session$session-mask-order.txt"
    for cpu_count in "${mask_order[@]}"; do
        case "$cpu_count" in
            1) CPUSET="0" ;;
            2) CPUSET="0,1" ;;
            4) CPUSET="0,1,2,3" ;;
            *) echo "P18 invalid mask" >&2; exit 2 ;;
        esac
        affinity="cpu$cpu_count"
        echo "P18 affinity session=$session $affinity order=${modes[*]}" >&2
        seen_control=0
        seen_grace=0
        for mode in "${modes[@]}"; do
        if [[ "$mode" == control ]]; then
            seen_control=$((seen_control + 1))
            rep=$seen_control
        else
            seen_grace=$((seen_grace + 1))
            rep=$seen_grace
        fi
        label="session${session}-${affinity}-${mode}${rep}"
        python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" snapshot \
            --cpus "$CPUSET" --mode observe \
            >>"$DEST/diagnostics/thermal-preflight.txt"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --interval 0.5 \
            --output "$DEST/telemetry/$label.csv" &
        MONITOR=$!
        if taskset -c "$CPUSET" \
            timeout --signal=TERM --kill-after=5s 300s \
            "$BIN_DIR/$mode" --profile singleingress --count 2048 \
            --waves 3 --warmup 2 --rounds 5 --seed "$seed" \
            >"$DEST/raw/$label.log" 2>&1; then
            kill "$MONITOR" 2>/dev/null || true
            wait "$MONITOR" 2>/dev/null || true
            MONITOR=""
        else
            rc=$?
            echo "P18 AFFINITY failed: $label rc=$rc" >&2
            exit "$rc"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"
        # Exactly 12 configurations x (2 warm-up + 5 measured) rounds,
        # plus one header. A truncated or changed fixture must fail closed.
        if [[ "$(wc -l <"$DEST/csv/$label.csv")" -ne 85 ]] ||
           [[ "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -ne 24 ]] ||
           [[ "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -ne 60 ]]; then
            echo "P18 AFFINITY incomplete/modified CSV: $label" >&2
            exit 4
        fi
        python3 "$ROOT/tools/research/m1_p18_single_ingress_check.py" \
            "$DEST/csv/$label.csv" --count 2048 --waves 3 --warmup 2 \
            --rounds 5 >"$DEST/diagnostics/$label-ingress-audit.txt"
        done
        for rep in 1 2; do
            python3 "$ROOT/tools/research/m1_p18_compare.py" \
                "$DEST/csv/session${session}-${affinity}-control${rep}.csv" \
                "$DEST/csv/session${session}-${affinity}-grace${rep}.csv" \
                --min-rows 84 \
                >"$DEST/diagnostics/session${session}-${affinity}-pair${rep}.txt"
        done
    done
done
python3 "$ROOT/tools/research/m1_p18_affinity_compare.py" "$DEST/csv" \
    --sessions "$SESSIONS" >"$DEST/diagnostics/affinity-paired-review.txt"

python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" review \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"

{
    for session in $(seq 1 "$SESSIONS"); do
        for cpu_count in 1 2 4; do
            for rep in 1 2; do
                echo "== session $session cpu$cpu_count adjacent-pair $rep =="
                cat "$DEST/diagnostics/session${session}-cpu${cpu_count}-pair${rep}.txt"
            done
        done
    done
    cat "$DEST/diagnostics/affinity-paired-review.txt"
} >"$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 AFFINITY source-pinned ABBA archive: $DEST.tar.gz"
echo "Privacy: inspect manifest/raw local host paths before publication."
