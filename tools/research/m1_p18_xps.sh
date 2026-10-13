#!/usr/bin/env bash
# P18 Dell-XPS foreground matched native M0 vs one-retry idle grace.
# Requires CPU package <95 C before sessions unless P18_ALLOW_HOT=1.
# Both variants uninstrumented. Read-only thermal sampling is symmetric.
# Usage: bash tools/research/m1_p18_xps.sh ldc2 /tmp/p18-xps-2026-10-13
# P18_CPUSET=... P18_SESSIONS=4 optional.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-idle-grace-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P18_SESSIONS:-4}"
ALLOW_HOT="${P18_ALLOW_HOT:-0}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
MONITOR=""
stop_monitor() {
    if [[ -n "$MONITOR" ]]; then
        kill "$MONITOR" 2>/dev/null || true
        wait "$MONITOR" 2>/dev/null || true
        MONITOR=""
    fi
}
trap stop_monitor EXIT

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )); then
    echo "P18 invalid P18_SESSIONS=$SESSIONS" >&2
    exit 2
fi
if [[ "$ALLOW_HOT" != "0" && "$ALLOW_HOT" != "1" ]]; then
    echo "P18_ALLOW_HOT must be 0 or 1" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 refuses overwrite: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset python3; do
    command -v "$cmd" >/dev/null
done

if [[ -n "${P18_CPUSET:-}" ]]; then
    CPUSET="$P18_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
from pathlib import Path
import os
seen=set()
cpus=[]
for cpu in sorted(os.sched_getaffinity(0)):
    root=Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key=((root/"physical_package_id").read_text().strip(),
         (root/"core_id").read_text().strip())
    if key not in seen:
        seen.add(key)
        cpus.append(cpu)
    if len(cpus)==4:
        break
if len(cpus)!=4:
    raise SystemExit("P18 needs four allowed distinct physical cores")
print(",".join(map(str,cpus)))
PY
)"
fi
taskset -c "$CPUSET" true

thermal_preflight() {
    if [[ "$ALLOW_HOT" == "0" ]]; then
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --max-package-c 95 --check
    else
        echo "P18_ALLOW_HOT=1: DIAGNOSTIC ONLY; NOT THERMALLY QUALIFIED" >&2
    fi
}
thermal_preflight

python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" \
    "$P162/race/main.d" "$BASE/generated"

# Qualify the close/completion/producer paths on the real target machine
# before timing either scheduler. Any native join failure remains fail-stop.
for mode in race-control race-grace; do
    taskset -c "$CPUSET" timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode" -- 12
done

mkdir -p "$DEST"/{raw,csv,telemetry,diagnostics}
DEST="$(cd "$DEST" && pwd)"
{
    echo "P18 one bounded extra idle search after yield, research-only"
    echo "started_utc=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "original_source_git_blob=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_cpu_affinity=$CPUSET"
    echo "worker_thread_pinning=false"
    echo "sessions=$SESSIONS"
    echo "warmup=2"
    echo "measured_sweeps=5"
    echo "workers=1,2,4"
    echo "ingress=8,64,256"
    echo "iterations=0,8,32,128,512"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "P18_ALLOW_HOT=$ALLOW_HOT"
    echo "reported_cpu_frequency_sampling_interval=500ms"
    echo "read_only_telemetry_overhead_applies_both_arms=true"
    echo "only_uninstrumented_arm_timings_are_compared=true"
    echo "whole_process_order_rotates_by_session=true"
    if command -v lscpu >/dev/null; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    thermal_preflight
    seed="$((332924710 + session * 101))"
    if ((session % 2 == 1)); then
        modes=(control grace)
    else
        modes=(grace control)
    fi
    echo "P18 session=$session cpu=$CPUSET mode-order=${modes[*]}" >&2
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    for mode in "${modes[@]}"; do
        thermal_preflight
        raw="$DEST/raw/session$session-$mode.log"
        telemetry="$DEST/telemetry/session$session-$mode.csv"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --interval 0.5 --output "$telemetry" &
        MONITOR=$!
        if taskset -c "$CPUSET" \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- --profile native --count 2048 \
            --waves 3 --warmup 2 --rounds 5 --seed "$seed" \
            >"$raw" 2>&1; then
            stop_monitor
        else
            rc=$?
            stop_monitor
            echo "P18 $mode failed: $rc" >&2
            exit "$rc"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' "$raw" \
            >"$DEST/csv/session$session-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p18_compare.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-grace.csv" --min-rows 315 \
        >"$DEST/diagnostics/session$session-compare.txt"
done

python3 "$ROOT/tools/research/m1_p17_thermal_review.py" \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"
{
    for session in $(seq 1 "$SESSIONS"); do
        echo "== session $session =="
        cat "$DEST/diagnostics/session$session-compare.txt"
    done
} >"$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P18 research evidence archive: $DEST.tar.gz"
echo "Privacy: review manifest/raw logs before external publication."
echo "Read thermal-review.txt; any hot/limited screening remains a NO-GO for performance promotion."
