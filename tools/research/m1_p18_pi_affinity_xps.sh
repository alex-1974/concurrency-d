#!/usr/bin/env bash
# P18: instrumented native event-only contrast at 1 vs 4 physical CPU cores.
# NEVER use this trace for timing comparisons; see uninstrumented affinity XPS.
# INSTRUMENTED TIMINGS CANNOT QUALIFY PERFORMANCE; use existing uninstrumented ABBA.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-onecore-parking-events-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P18_PARK_SESSIONS:-4}"
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

if [[ "$SESSIONS" != 4 ]]; then
    echo "P18 PI invalid session count" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 PI refuses overwrite: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset timeout python3 sha256sum tar; do
    command -v "$cmd" >/dev/null
done
# This experiment is ONLY about one core vs four distinct physical cores;
# do not silently compare cpuset siblings or a narrowed effective affinity.
declare -A phys=()
for cpu in 0 1 2 3; do
    taskset -c "$cpu" true
    k="/sys/devices/system/cpu/cpu$cpu/topology/core_id"
    p="/sys/devices/system/cpu/cpu$cpu/topology/physical_package_id"
    [[ -r "$k" && -r "$p" ]] || { echo "missing CPU topology $cpu" >&2; exit 3; }
    key="$(cat "$p"):$(cat "$k")"
    if [[ -v "phys[$key]" ]]; then
        echo "SMT sibling CPUs; event comparison invalid: $key" >&2
        exit 3
    fi
    phys["$key"]=1
done
for requested in 0 0,1,2,3; do
    taskset -c "$requested" python3 - "$requested" <<'PY'
import os, sys
expected={int(c) for c in sys.argv[1].split(",")}
actual=os.sched_getaffinity(0)
if actual!=expected:
    raise SystemExit(f"effective CPU mask {sorted(actual)} != requested {sorted(expected)}")
PY
done

# All sources fail closed against exact M0 and pinned P13 kernel/driver.
python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"

for mode in control grace; do
    if [[ "$mode" == control ]]; then
        source="$ROOT/source/concurrency/internal/submission_pool.d"
    else
        source="$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
    fi
    python3 "$ROOT/tools/research/m1_p18_pi_make_pair.py" "$mode" \
        "$source" "$BASE/generated/concurrency/research/m1_p18_pi_${mode}_pool.d"
done
python3 "$ROOT/tools/research/m1_p18_pi_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,diagnostics,telemetry}
DEST="$(cd "$DEST" && pwd)"
BIN_DIR="$(mktemp -d)"

# Traced process binaries are compiled outside the measured event processes.
for mode in pi-control pi-grace; do
    dub build --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode"
    cp "$BASE/m1-p18-idle-grace" "$BIN_DIR/$mode"
    sha256sum "$BIN_DIR/$mode" >>"$DEST/diagnostics/binary-sha256.txt"
done

# Save both original native close/producer race preflights so the run can
# be independently audited, at each process-affinity extreme.
for race_mask in 0 0,1,2,3; do
    case "$race_mask" in 0) prefix=cpu1 ;; *) prefix=cpu4 ;; esac
    for mode in race-control race-grace; do
        taskset -c "$race_mask" timeout --signal=TERM --kill-after=5s 150s \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- 12 \
            >"$DEST/diagnostics/race-$prefix-$mode.log" 2>&1
    done
done

{
    echo "study=P18 one-vs-four physical CPU event-only Condition.wait and ingress path comparison"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "started_utc=$(date -u -Iseconds)"
    echo "original_source_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_affinity_masks=cpu1:0;cpu4:0,1,2,3"
    echo "physical_cores_distinct=true"
    echo "effective_cpu_masks_verified=true"
    echo "affinity_order=ABBA reversed per session"
    echo "worker_pinning=false"
    echo "profile=singleingress"
    echo "iterations=128,512,1024"
    echo "workers=1"
    echo "ingress=8,64,256,2048"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "warmups=2"
    echo "measured_rounds=5"
    echo "sessions=$SESSIONS"
    echo "event_only_instrumentation=true"
    echo "use_event_counts_not_trace_timings=true"
    echo "P18_uninstrumented_affinity_archive_sha256=5aed3e015e6a82d2c6a93f276ddc1192492dd5ac72fc3f4916723212c1a2bcb1"
    echo "original_uninstrumented_single_ingress_sha256=a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63"
    echo "condition_wait_counter_counts_entries_NOT_wait_duration=true"
    echo "worker_batch_tasks_same_total_not_same_batch_count=true"
    echo "instrumentation_mutex_counters_perturb_thread_scheduling=true"
    echo "ingress_2048_means_zero_producer_full_expected=true"
    if command -v lscpu >/dev/null; then lscpu; fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332925000 + session * 101))"
    if (( session % 2 == 1 )); then
        modes=(pi-control pi-grace)
    else
        modes=(pi-grace pi-control)
    fi
    if (( session % 2 == 1 )); then
        mask_order=(1 4)
    else
        mask_order=(4 1)
    fi
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    echo "${mask_order[*]}" >"$DEST/diagnostics/session$session-cpu-mask-order.txt"
    for cpu_count in "${mask_order[@]}"; do
        if [[ "$cpu_count" == 1 ]]; then CPUSET="0"; else CPUSET="0,1,2,3"; fi
        for mode in "${modes[@]}"; do
            echo "P18 PI event-only session=$session cpu=$cpu_count arm=$mode" >&2
            label="session$session-cpu$cpu_count-$mode"
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
            echo "P18 PI run failed: $label, exit=$rc" >&2
            exit "$rc"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"
        if [[ "$(wc -l <"$DEST/csv/$label.csv")" -ne 85 ]] ||
           [[ "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -ne 24 ]] ||
           [[ "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -ne 60 ]]; then
            echo "P18 PI incomplete 12-case CSV: $label" >&2
            exit 4
        fi
        python3 "$ROOT/tools/research/m1_p18_single_ingress_check.py" \
            "$DEST/csv/$label.csv" --count 2048 --waves 3 \
            --warmup 2 --rounds 5 \
            >"$DEST/diagnostics/$label-scenario-check.txt"
        done
        python3 "$ROOT/tools/research/m1_p18_pi_compare.py" \
            "$DEST/csv/session$session-cpu$cpu_count-pi-control.csv" \
            "$DEST/csv/session$session-cpu$cpu_count-pi-grace.csv" \
            --min-rows 84 --count 2048 --waves 3 \
            >"$DEST/diagnostics/session$session-cpu$cpu_count-event-compare.txt"
    done
done
python3 "$ROOT/tools/research/m1_p18_pi_affinity_compare.py" "$DEST/csv" \
    >"$DEST/diagnostics/onecore-affinity-paired-event-audit.txt"

python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" review \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"
{
    for session in $(seq 1 "$SESSIONS"); do
        for cpu_count in 1 4; do
            echo "== session $session cpu$cpu_count event-only =="
            cat "$DEST/diagnostics/session$session-cpu$cpu_count-event-compare.txt"
        done
    done
    cat "$DEST/diagnostics/onecore-affinity-paired-event-audit.txt"
} >"$DEST/summary.txt"
tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 one/four-core event-only native evidence: $DEST.tar.gz"
echo "Trace wave times are instrumentation-confounded and NOT speed evidence."
