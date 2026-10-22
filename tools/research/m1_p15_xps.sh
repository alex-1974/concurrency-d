#!/usr/bin/env bash
# P15 native Dell XPS M0 lock wait/hold timing evidence — foreground only.
# Usage:
#   bash tools/research/m1_p15_xps.sh ldc2 /tmp/p15-xps-2026-10-13
# Optional P15_CPUSET=... and P15_SESSIONS=3. Review raw logs before sharing.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p15-m0-mutex-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P15_SESSIONS:-3}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p15_mutex_timing"

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )); then
    echo "P15 invalid session count: $SESSIONS" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P15 refuses to overwrite existing evidence: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset python3; do
    command -v "$cmd" >/dev/null 2>&1
done

# A process affinity mask is NOT individual worker-to-CPU pinning.
if [[ -n "${P15_CPUSET:-}" ]]; then
    CPUSET="$P15_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
from pathlib import Path
import os

cores = set()
cpus = []
for cpu in sorted(os.sched_getaffinity(0)):
    topology = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key = (topology.joinpath("physical_package_id").read_text().strip(),
           topology.joinpath("core_id").read_text().strip())
    if key not in cores:
        cores.add(key)
        cpus.append(cpu)
        if len(cpus) == 4:
            break
if len(cpus) != 4:
    raise SystemExit("P15 needs 4 allowed distinct physical cores")
print(",".join(map(str, cpus)))
PY
)"
fi
taskset -c "$CPUSET" true

python3 "$ROOT/tools/research/m1_p15_make_mutex_probe.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p15_pool.d"
python3 "$ROOT/tools/research/m1_p15_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,diagnostics}
DEST="$(cd "$DEST" && pwd)"

{
    echo "P15 source=exact M0 with 5 timestamp-sampled TaskInbox mutex paths"
    echo "date_utc=$(date -u -Iseconds)"
    echo "git_commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "source_git_blob=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_affinity=$CPUSET"
    echo "worker_core_pinning=false"
    echo "sessions=$SESSIONS"
    echo "profile=native"
    echo "workers=1,2,4"
    echo "iterations=0,8,32,128,512"
    echo "ingress=8,64,256"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "warmup_sweeps=2"
    echo "measured_sweeps=7"
    echo "probe_sites=submit,batch,complete,generation,local_signal"
    echo "scope_warning=timestamp and statistic updates under lock perturb target"
    echo "order=alternated whole-process control/timed, same seed per session"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if command -v sensors >/dev/null 2>&1; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332922810 + session * 101))"
    echo "P15 session $session, cpus=$CPUSET, seed=$seed" >&2
    if (( session % 2 == 0 )); then
        modes=(timed control)
    else
        modes=(control timed)
    fi
    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/session$session-start.txt"

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

    python3 "$ROOT/tools/research/m1_p15_compare.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-timed.csv" --min-rows 400 \
        >"$DEST/diagnostics/session$session-compare.txt"

    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/session$session-end.txt"
done

{
    for session in $(seq 1 "$SESSIONS"); do
        echo "== P15 session $session =="
        cat "$DEST/diagnostics/session$session-compare.txt"
    done
} | tee "$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P15 native diagnostic evidence: $DEST.tar.gz"
echo "Raw logs contain local environment identifiers. Review before publishing."
