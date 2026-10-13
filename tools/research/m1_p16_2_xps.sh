#!/usr/bin/env bash
# P16.2 FOREGROUND actual Dell-XPS head-to-head: uninstrumented unchanged M0
# versus uninstrumented seq-cst completion variant. Same P13 task workload,
# randomized worker/kernel/ingress sweeps, AB/BA mode order by session.
# Usage: bash tools/research/m1_p16_2_xps.sh ldc2 /tmp/p16-2-xps-2026-10-13
# Optional P162_CPUSET=..., P162_SESSIONS=3. No CI timing decisions.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p16-2-atomic-completion-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P162_SESSIONS:-3}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 9 )); then
    echo "Invalid P162_SESSIONS=$SESSIONS" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "Refusing to overwrite P16.2 evidence: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset python3; do
    command -v "$cmd" >/dev/null 2>&1
done
if [[ -n "${P162_CPUSET:-}" ]]; then
    CPUSET="$P162_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
import os
from pathlib import Path
cores, selected = set(), []
for cpu in sorted(os.sched_getaffinity(0)):
    path = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key = ((path/"physical_package_id").read_text().strip(),
           (path/"core_id").read_text().strip())
    if key not in cores:
        cores.add(key)
        selected.append(cpu)
    if len(selected) == 4:
        break
if len(selected) != 4:
    raise SystemExit("P16.2 requires four permitted distinct physical cores")
print(",".join(map(str, selected)))
PY
)"
fi
taskset -c "$CPUSET" true

python3 "$ROOT/tools/research/m1_p16_2_sc_handshake.py"
python3 "$ROOT/tools/research/m1_p16_2_make_atomic_completion.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p16_2_pool.d"
python3 "$ROOT/tools/research/m1_p16_2_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

# Semantics and no-lost-wake race protocol are checked BEFORE any timing.
for mode in race-control race-atomic; do
    taskset -c "$CPUSET" \
        timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
            --config="$mode" -- 12
done

mkdir -p "$DEST"/{raw,csv,diagnostics}
DEST="$(cd "$DEST" && pwd)"

{
    echo "P16.2 native XPS only: unchanged M0 vs seq-cst completion research copy"
    echo "date=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "source_git_blob=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "cpuset=$CPUSET"
    echo "process_mask_is_not_thread_pinning=true"
    echo "sessions=$SESSIONS"
    echo "workers=1,2,4"
    echo "iterations=0,8,32,128,512"
    echo "ingress=8,64,256"
    echo "count_per_wave=2048"
    echo "waves=3"
    echo "warmup_sweeps=2"
    echo "measured_sweeps=7"
    echo "ABBA=whole_process_mode_order_alternates_by_session"
    echo "no_cpu_frequency_trace=true"
    echo "M0_production_and_APIs_unchanged=true"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if command -v sensors >/dev/null 2>&1; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332923510 + 101 * session))"
    if (( session % 2 == 0 )); then
        modes=(atomic control)
    else
        modes=(control atomic)
    fi
    echo "P16.2 session=$session cpus=$CPUSET mode_order=${modes[*]}" >&2
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

    python3 "$ROOT/tools/research/m1_p16_2_check.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-atomic.csv" \
        --min-rows 400 >"$DEST/diagnostics/session$session-compare.txt"

    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/session$session-end.txt"
done

{
    for session in $(seq 1 "$SESSIONS"); do
        echo "== P16.2 session $session =="
        cat "$DEST/diagnostics/session$session-compare.txt"
    done
} | tee "$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P16.2 native evidence archive: $DEST.tar.gz"
echo "Review raw logs and manifest for local identifiers before publishing."
