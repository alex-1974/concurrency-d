#!/usr/bin/env bash
# P18 XPS foreground matched ORIGINAL M0 vs one-retry grace: no-task idle.
# Process CPU time indicates scheduler activity, NOT energy use or watts.
# Observational sysfs temperature/frequency/throttle sampling; no hot gate.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-idle-xps-$(date +%Y%m%d-%H%M%S)}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
SESSIONS="${P18_SESSIONS:-4}"
CPUSET="${P18_CPUSET:-0,1,2,3}"
ROUNDS="${P18_IDLE_ROUNDS:-3}"
HOLD_MS="${P18_IDLE_HOLD_MS:-1000}"
SETTLE_MS="${P18_IDLE_SETTLE_MS:-250}"
MONITOR=""
TEMP_BIN=""

stop_monitor() {
    if [[ -n "$MONITOR" ]]; then
        kill "$MONITOR" 2>/dev/null || true
        wait "$MONITOR" 2>/dev/null || true
        MONITOR=""
    fi
}
cleanup() {
    stop_monitor
    if [[ -n "$TEMP_BIN" ]]; then rm -rf -- "$TEMP_BIN"; fi
}
trap cleanup EXIT
for cmd in "$DC" dub taskset python3 timeout sha256sum tar; do
    command -v "$cmd" >/dev/null
done
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 idle refuses overwrite: $DEST" >&2
    exit 2
fi
if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )) ||
   [[ ! "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || (( ROUNDS > 40 )) ||
   [[ ! "$HOLD_MS" =~ ^[1-9][0-9]*$ ]] || (( HOLD_MS < 20 || HOLD_MS > 30000 )) ||
   [[ ! "$SETTLE_MS" =~ ^[1-9][0-9]*$ ]] || (( SETTLE_MS < 20 || SETTLE_MS > 10000 )); then
    echo "P18 idle invalid sessions/rounds/hold/settle" >&2
    exit 2
fi
taskset -c "$CPUSET" true

# Check the real M0 source, never patch production code.
python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,telemetry,diagnostics}
DEST="$(cd "$DEST" && pwd)"
TEMP_BIN="$(mktemp -d)"
{
    echo "experiment=P18 real native zero-TaskRef idle CPU observation"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "original_source_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "source_variant=unchanged-M0-vs-P18-one-bounded-idle-retry"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "affinity=$CPUSET"
    echo "worker_thread_pinning=false"
    echo "sessions=$SESSIONS"
    echo "rounds=$ROUNDS"
    echo "hold_ms=$HOLD_MS"
    echo "settle_ms=$SETTLE_MS"
    echo "workload=zero admitted TaskRefs"
    echo "measure=process CPU time during stabilized idle windows"
    echo "not_power_or_energy=true"
    echo "thermal_observation=500ms-sysfs-no-automatic-abort"
    if command -v lscpu >/dev/null; then lscpu; fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

# Build both binaries BEFORE sampling; no DUB build/compilation inside
# the temperature-monitored, short/quiet idle measurement processes.
for mode in control grace; do
    dub build --root="$BASE" --compiler="$DC" --build=release \
        --config="idle-$mode"
    cp "$BASE/m1-p18-idle-grace" "$TEMP_BIN/idle-$mode"
    sha256sum "$TEMP_BIN/idle-$mode" \
        >>"$DEST/diagnostics/binary-sha256.txt"
done

# Source-identical close/producer native adversarial tests remain required.
for mode in race-control race-grace; do
    taskset -c "$CPUSET" timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode" -- 12
done

for session in $(seq 1 "$SESSIONS"); do
    if (( session % 2 == 1 )); then
        modes=(control grace)
    else
        modes=(grace control)
    fi
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    echo "P18 idle session=$session order=${modes[*]} CPU=$CPUSET" >&2
    for mode in "${modes[@]}"; do
        python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" snapshot \
            --cpus "$CPUSET" --mode observe \
            >>"$DEST/diagnostics/thermal-preflight.txt"
        raw="$DEST/raw/session$session-$mode.log"
        telemetry="$DEST/telemetry/session$session-$mode.csv"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --interval 0.5 --output "$telemetry" &
        MONITOR=$!
        if taskset -c "$CPUSET" "$TEMP_BIN/idle-$mode" \
            --settle-ms "$SETTLE_MS" --hold-ms "$HOLD_MS" \
            --rounds "$ROUNDS" >"$raw" 2>&1; then
            stop_monitor
        else
            rc=$?
            stop_monitor
            echo "P18 idle $mode failed: $rc" >&2
            exit "$rc"
        fi
        grep -E '^(phase,workers,|measure,)' "$raw" \
            >"$DEST/csv/session$session-$mode.csv"
        grep -q '^P18_IDLE_PASS' "$raw"
    done
    python3 "$ROOT/tools/research/m1_p18_idle_compare.py" \
        "$DEST/csv/session$session-control.csv" \
        "$DEST/csv/session$session-grace.csv" \
        --min-rows "$((3 * ROUNDS))" \
        >"$DEST/diagnostics/session$session-compare.txt"
done

python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" review \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"
for session in $(seq 1 "$SESSIONS"); do
    echo "== session $session =="
    cat "$DEST/diagnostics/session$session-compare.txt"
done >"$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 idle research archive: $DEST.tar.gz"
echo "Privacy: review manifest/paths before publishing."
echo "Interpret process CPU time as an idle activity proxy, NOT measured watts."
