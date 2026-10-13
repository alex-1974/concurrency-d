#!/usr/bin/env bash
# P14 native XPS foreground capture: identical production M0 control vs
# generated exact-source per-worker counter overlay, whole-matrix repetitions.
# Usage: bash tools/research/m1_p14_xps.sh ldc2 /tmp/p14-xps-2026-10-13
# Optional P14_CPUSET=..., P14_SESSIONS=3. NEVER upload raw host data blindly.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p14-m0-events-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P14_SESSIONS:-3}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p14_scheduler_events"

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )); then
    echo "Invalid P14_SESSIONS=$SESSIONS" >&2
    exit 2
fi
if [[ -e "$DEST" ]] || [[ -e "$DEST.tar.gz" ]]; then
    echo "P14 refuses to overwrite prior evidence: $DEST" >&2
    exit 2
fi
for command in "$DC" dub taskset python3; do
    command -v "$command" >/dev/null 2>&1
done

if [[ -n "${P14_CPUSET:-}" ]]; then
    CPUSET="$P14_CPUSET"
else
    CPUSET="$(python3 - <<'PY'
from pathlib import Path
import os
selected = []
seen = set()
for cpu in sorted(os.sched_getaffinity(0)):
    parent = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key = ((parent / "physical_package_id").read_text().strip(),
           (parent / "core_id").read_text().strip())
    if key not in seen:
        seen.add(key)
        selected.append(cpu)
    if len(selected) == 4:
        break
if len(selected) != 4:
    raise SystemExit("P14 requires four distinct allowed physical cores")
print(",".join(map(str, selected)))
PY
)"
fi
taskset -c "$CPUSET" true

# Before directory creation: fail fast if source probes changed.
python3 "$ROOT/tools/research/m1_p14_make_instrumented_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p14_pool.d"
python3 "$ROOT/tools/research/m1_p14_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

mkdir -p "$DEST/raw" "$DEST/csv" "$DEST/diagnostics"
DEST="$(cd "$DEST" && pwd)"

{
    echo "P14: real-M0 exact source, control vs event-overlay, no optimization conclusion"
    echo "date_utc=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_cpu_affinity=$CPUSET"
    echo "affinity_is_not_per_worker_pinning=true"
    echo "sessions=$SESSIONS"
    echo "count_per_wave=2048"
    echo "waves=3"
    echo "warmup_sweeps=2"
    echo "measured_sweeps=7"
    echo "profile=native; 1/2/4 workers; 0/8/32/128/512 iterations; 8/64/256 ingress"
    echo "same_wave_computation=true"
    echo "order=alternating control/trace process order; same scenario-seed per pair"
    echo "P14_trace_source_git_blob=b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
    echo "no continuous frequency, thermal or PMU trace; results are diagnostic"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    fi
    if command -v sensors >/dev/null 2>&1; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332922610 + 101 * session))"
    echo "P14 native session $session, cpus=$CPUSET, seed=$seed" >&2
    if (( session % 2 == 0 )); then
        modes=(trace control)
    else
        modes=(control trace)
    fi
    date -u -Iseconds >"$DEST/diagnostics/session$session-start.txt"
    if command -v sensors >/dev/null 2>&1; then
        sensors >>"$DEST/diagnostics/session$session-start.txt" || true
    fi
    for mode in "${modes[@]}"; do
        file="$DEST/raw/session$session-$mode.log"
        taskset -c "$CPUSET" \
            dub run --root="$BASE" --compiler="$DC" --build=release \
                --config="$mode" -- --profile native --count 2048 \
                --waves 3 --warmup 2 --rounds 7 --seed "$seed" \
                >"$file" 2>&1
        grep -E '^(phase,round,|warmup,|measure,)' "$file" \
            >"$DEST/csv/session$session-$mode.csv"
    done
    python3 "$ROOT/tools/research/m1_p14_compare.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-trace.csv" \
        --min-rows 400 >"$DEST/diagnostics/session$session-compare.txt"
    date -u -Iseconds >"$DEST/diagnostics/session$session-end.txt"
    if command -v sensors >/dev/null 2>&1; then
        sensors >>"$DEST/diagnostics/session$session-end.txt" || true
    fi
done

{
    for session in $(seq 1 "$SESSIONS"); do
        echo "== Session $session =="
        cat "$DEST/diagnostics/session$session-compare.txt"
    done
} | tee "$DEST/event-summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P14 evidence: $DEST.tar.gz"
echo "Review manifest/raw files for host/user paths before publishing."
