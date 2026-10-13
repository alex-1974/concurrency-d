#!/usr/bin/env bash
# P16.1 foreground native Dell XPS completion probe calibration.
# Three separately built identical-work arms: unchanged M0 control;
# one-in-64 null double-clock (before completion); one-in-64 sampled
# whole completion call (clocks straddle completeOne). No perf verdict.
# Usage:
#   bash tools/research/m1_p16_xps.sh ldc2 /tmp/p16-xps-2026-10-13
# Optional P16_CPUSET=... P16_SESSIONS=3. Inspect raw host data before publishing.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p16-completion-sampling-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P16_SESSIONS:-3}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p16_completion_sampling"

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 9 )); then
    echo "P16 invalid session count: $SESSIONS" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P16 refuses to overwrite existing evidence: $DEST" >&2
    exit 2
fi
for tool in "$DC" dub taskset python3; do
    command -v "$tool" >/dev/null 2>&1
done

if [[ -n "${P16_CPUSET:-}" ]]; then
    CPUSET="$P16_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
from pathlib import Path
import os
seen = set()
chosen = []
for cpu in sorted(os.sched_getaffinity(0)):
    root = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key = ((root / "physical_package_id").read_text().strip(),
           (root / "core_id").read_text().strip())
    if key in seen:
        continue
    seen.add(key)
    chosen.append(cpu)
    if len(chosen) == 4:
        break
if len(chosen) != 4:
    raise SystemExit("P16 needs four permitted distinct physical cores")
print(",".join(map(str, chosen)))
PY
)"
fi
taskset -c "$CPUSET" true

python3 "$ROOT/tools/research/m1_p16_make_sampled_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p16_pool.d"
python3 "$ROOT/tools/research/m1_p16_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,diagnostics}
DEST="$(cd "$DEST" && pwd)"

{
    echo "P16.1 fixed-source M0 completion sampling calibration"
    echo "utc_start=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "m0_source_git_blob=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_affinity=$CPUSET"
    echo "per_worker_thread_pinning=false"
    echo "sessions=$SESSIONS"
    echo "profile=native"
    echo "workers=1,2,4"
    echo "iterations=0,8,32,128,512"
    echo "ingress=8,64,256"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "warmup_sweeps=2"
    echo "measured_sweeps=7"
    echo "sampling=every_64th_completeOne_per_worker"
    echo "control=unchanged_M0"
    echo "null-clock=two_adjacent_timestamps_before_completion"
    echo "sample=two_timestamps_bracketing_completeOne"
    echo "process_order=Latin_square_rotate_each_session"
    echo "CAUTION: sampled observations include scheduling, clock overhead and the whole call, not separated Mutex hold/wait"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if command -v sensors >/dev/null 2>&1; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332923010 + session * 101))"
    echo "P16 native session $session cpus=$CPUSET seed=$seed" >&2
    case $(( (session - 1) % 3 )) in
        0) modes=(control null-clock sampled) ;;
        1) modes=(sampled control null-clock) ;;
        2) modes=(null-clock sampled control) ;;
    esac
    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/session$session-start.txt"
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"

    for mode in "${modes[@]}"; do
        raw="$DEST/raw/session$session-$mode.log"
        taskset -c "$CPUSET" \
            dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- --profile native --count 2048 \
            --waves 3 --warmup 2 --rounds 7 --seed "$seed" \
            >"$raw" 2>&1
        grep -E '^(phase,round,|warmup,|measure,)' "$raw" \
            >"$DEST/csv/session$session-$mode.csv"
    done

    python3 "$ROOT/tools/research/m1_p16_compare.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-null-clock.csv" \
        "$DEST/csv/session$session-sampled.csv" \
        --min-rows 400 >"$DEST/diagnostics/session$session-compare.txt"
    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/session$session-end.txt"
done

{
    for session in $(seq 1 "$SESSIONS"); do
        echo "== P16 session $session =="
        cat "$DEST/diagnostics/session$session-compare.txt"
    done
} | tee "$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P16 foreground native evidence archive: $DEST.tar.gz"
echo "Review manifest and raw log paths/host before publication."
