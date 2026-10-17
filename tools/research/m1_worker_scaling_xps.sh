#!/usr/bin/env bash
# P13 native XPS evidence collection. Runs FOREGROUND in a worktree.
# Usage:
#   bash tools/research/m1_worker_scaling_xps.sh ldc2 /tmp/p13-xps-2026-10-13
# Optional P13_CPUSET="0,1,2,3" overrides topology-derived distinct cores.
# Optional P13_SESSIONS=3 sets number of independent randomized sessions.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p13-worker-scaling-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P13_SESSIONS:-3}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"

command -v "$DC" >/dev/null 2>&1
command -v dub >/dev/null 2>&1
command -v taskset >/dev/null 2>&1
if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )); then
    echo "P13 invalid P13_SESSIONS: $SESSIONS" >&2
    exit 2
fi
if [[ -e "$DEST" ]] || [[ -e "$DEST.tar.gz" ]]; then
    echo "P13 refuses to overwrite evidence: $DEST" >&2
    exit 2
fi

# Choose four available logical CPUs mapping to DIFFERENT (socket, core)
# according to Linux sysfs. Do not assume CPU 0-3 are physical cores.
if [[ -n "${P13_CPUSET:-}" ]]; then
    CPUSET="$P13_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
import os
from pathlib import Path

seen = set()
chosen = []
for cpu in sorted(os.sched_getaffinity(0)):
    topo = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key = (
        (topo / "physical_package_id").read_text().strip(),
        (topo / "core_id").read_text().strip(),
    )
    if key in seen:
        continue
    seen.add(key)
    chosen.append(cpu)
    if len(chosen) == 4:
        break
if len(chosen) < 4:
    raise SystemExit("P13: fewer than four distinct allowed physical cores")
print(",".join(map(str, chosen)))
PY
)"
fi
taskset -c "$CPUSET" true

mkdir -p "$DEST/raw" "$DEST/csv" "$DEST/diagnostics"
DEST="$(cd "$DEST" && pwd)"

{
    echo "P13 independent native scaling experiment — research only"
    echo "utc=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "cpuset=$CPUSET"
    echo "sessions=$SESSIONS"
    echo "profile=native"
    echo "count_per_wave=2048"
    echo "waves=3"
    echo "warmup_sweeps=2"
    echo "measured_sweeps=7"
    echo "kernels=0,8,32,128,512 unsigned iterations"
    echo "ingress=8,64,256"
    echo "workers=1,2,4"
    echo "order=seeded independent whole-matrix shuffle every sweep"
    echo "M0_pool=unchanged SubmissionWorkerPool / containers-d 0.2.0"
    echo "NO-GO: CI speed gate, @safe task API, production optimization"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if [[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        echo "governor_cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332922414 + session * 101))"
    label="session${session}"
    echo "P13: $label, cores=$CPUSET, seed=$seed" >&2
    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/$label-start.txt"

    taskset -c "$CPUSET" \
        dub run --root="$BASE" --compiler="$DC" --build=release \
            --config=release-mode -- --profile native --count 2048 \
            --waves 3 --warmup 2 --rounds 7 --seed "$seed" \
            >"$DEST/raw/$label.log" 2>&1

    grep -E '^(phase,round,|warmup,|measure,)' \
        "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"

    {
        date -u -Iseconds
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } >"$DEST/diagnostics/$label-end.txt"
done

args=()
for session in $(seq 1 "$SESSIONS"); do
    args+=("$DEST/csv/session$session.csv")
done
python3 "$ROOT/tools/research/m1_worker_scaling_analyze.py" \
    --minimum-rounds 7 --require-profile native \
    --output "$DEST/summary.csv" "${args[@]}" \
    | tee "$DEST/analysis.log"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P13 evidence archive: $DEST.tar.gz"
echo "Note: manifest/raw logs may include local host/path information; review before public upload."
