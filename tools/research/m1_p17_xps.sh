#!/usr/bin/env bash
# P17 foreground native XPS: 4-arm original/atomic and event-only overlays.
# Requires cool CPU to qualify throughput. Telemetry is read-only and may
# itself influence scheduling; it is run for ALL arms symmetrically.
# Usage: bash tools/research/m1_p17_xps.sh ldc2 /tmp/p17-xps-2026-10-13
# P17_ALLOW_HOT=1 permits exploratory hot runs; these are NOT qualified.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p17-scheduler-interactions-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P17_SESSIONS:-4}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p17_scheduler_interactions"
ALLOW_HOT="${P17_ALLOW_HOT:-0}"
SAMPLE_PID=""

stop_sampler() {
    if [[ -n "$SAMPLE_PID" ]]; then
        kill "$SAMPLE_PID" 2>/dev/null || true
        wait "$SAMPLE_PID" 2>/dev/null || true
        SAMPLE_PID=""
    fi
}
trap stop_sampler EXIT

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )); then
    echo "P17 invalid P17_SESSIONS=$SESSIONS" >&2
    exit 2
fi
if [[ "$ALLOW_HOT" != 0 && "$ALLOW_HOT" != 1 ]]; then
    echo "P17_ALLOW_HOT must be 0 or 1" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P17 refuses to overwrite previous evidence: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset python3; do
    command -v "$cmd" >/dev/null 2>&1
done

if [[ -n "${P17_CPUSET:-}" ]]; then
    CPUSET="$P17_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
import os
from pathlib import Path
keys,cpus=set(),[]
for cpu in sorted(os.sched_getaffinity(0)):
    root=Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    k=((root/"physical_package_id").read_text().strip(),
       (root/"core_id").read_text().strip())
    if k not in keys:
        keys.add(k)
        cpus.append(cpu)
    if len(cpus)==4:
        break
if len(cpus)!=4:
    raise SystemExit("P17 needs four distinct available physical cores")
print(",".join(map(str,cpus)))
PY
)"
fi
taskset -c "$CPUSET" true

if [[ "$ALLOW_HOT" == 0 ]]; then
    # This fail-closed temperature screening is deliberate after the
    # P16.2 XPS run recorded 100 C before and after every session.
    python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
        --cpus "$CPUSET" --max-package-c 95 --check
else
    echo "P17 thermal screening OVERRIDDEN: DIAGNOSTIC ONLY, NOT SPEED QUALIFIED" >&2
fi

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

mkdir -p "$DEST"/{raw,csv,diagnostics,telemetry}
DEST="$(cd "$DEST" && pwd)"
{
    echo "P17 research: unchanged M0 / seq-cst variant, original vs event-copy"
    echo "date=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "source_blob=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_cpuset=$CPUSET"
    echo "per_worker_pinning=false"
    echo "P17_ALLOW_HOT=$ALLOW_HOT"
    echo "qualification_limit_package_c=95"
    echo "sessions=$SESSIONS"
    echo "warmup=2"
    echo "measured_rounds=5"
    echo "profile=native"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "four_arms=control,atomic,trace-control,trace-atomic"
    echo "power_and_frequency=read_only_sysfs_500ms_samples"
    echo "telemetry_cannot_prove_absence_of_throttling=true"
    echo "trace_arm_speed_cannot_qualify_performance=true"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if command -v sensors >/dev/null 2>&1; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332924110 + session*101))"
    case $(( (session - 1) % 4 )) in
        0) modes=(control atomic trace-control trace-atomic) ;;
        1) modes=(atomic trace-atomic control trace-control) ;;
        2) modes=(trace-control control trace-atomic atomic) ;;
        3) modes=(trace-atomic trace-control atomic control) ;;
    esac
    echo "P17 session=$session cpus=$CPUSET modes=${modes[*]}" >&2
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    for mode in "${modes[@]}"; do
        raw="$DEST/raw/session$session-$mode.log"
        telemetry="$DEST/telemetry/session$session-$mode.csv"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --interval 0.5 \
            --output "$telemetry" &
        SAMPLE_PID=$!
        if taskset -c "$CPUSET" \
            dub run --root="$BASE" --compiler="$DC" --build=release \
                --config="$mode" -- --profile native --count 2048 \
                --waves 3 --warmup 2 --rounds 5 --seed "$seed" \
                >"$raw" 2>&1; then
            stop_sampler
        else
            status=$?
            stop_sampler
            echo "P17 native $session/$mode failed: $status" >&2
            exit "$status"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' "$raw" \
            >"$DEST/csv/session$session-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p17_compare.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-atomic.csv" \
        "$DEST/csv/session$session-trace-control.csv" \
        "$DEST/csv/session$session-trace-atomic.csv" \
        --min-rows 315 >"$DEST/diagnostics/session$session-compare.txt"
done

{
    for s in $(seq 1 "$SESSIONS"); do
        echo "== P17 session $s =="
        cat "$DEST/diagnostics/session$s-compare.txt"
    done
} >"$DEST/event-summary.txt"

python3 "$ROOT/tools/research/m1_p17_thermal_review.py" \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P17 native evidence: $DEST.tar.gz"
echo "Review raw logs and manifest before publishing machine/user/path details."
echo "If thermal review says NOT QUALIFIED, do NOT use run for a speed verdict."
