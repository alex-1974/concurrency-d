#!/usr/bin/env bash
# P18 bounded research: event-only diagnostics on pinned original M0 vs grace.
# TRACE TIMINGS CANNOT QUALIFY PERFORMANCE; use existing uninstrumented ABBA.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-focus512-trace-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P18_TRACE_SESSIONS:-4}"
CPUSET="${P18_TRACE_CPUSET:-0,1,2,3}"
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

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )); then
    echo "P18 trace invalid session count" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 trace refuses overwrite: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset timeout python3 sha256sum tar; do
    command -v "$cmd" >/dev/null
done
taskset -c "$CPUSET" true

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
    python3 "$ROOT/tools/research/m1_p18_512_make_event_pair.py" "$mode" \
        "$source" "$BASE/generated/concurrency/research/m1_p18_trace_${mode}_pool.d"
done
python3 "$ROOT/tools/research/m1_p18_512_make_trace_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,diagnostics,telemetry}
DEST="$(cd "$DEST" && pwd)"
BIN_DIR="$(mktemp -d)"

# Traced process binaries are compiled outside the measured event processes.
for mode in trace-control trace-grace; do
    dub build --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode"
    cp "$BASE/m1-p18-idle-grace" "$BIN_DIR/$mode"
    sha256sum "$BIN_DIR/$mode" >>"$DEST/diagnostics/binary-sha256.txt"
done

# Prove both uninstrumented lifetime/close/producer paths still function.
for mode in race-control race-grace; do
    taskset -c "$CPUSET" timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode" -- 12
done

{
    echo "study=P18 focus512 EVENT-ONLY; no speed comparison permitted"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "started_utc=$(date -u -Iseconds)"
    echo "original_source_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_affinity=$CPUSET"
    echo "worker_pinning=false"
    echo "profile=focus512"
    echo "iterations=128,512,1024"
    echo "workers=1,2,4"
    echo "ingress=8,64,256"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "warmups=2"
    echo "measured_rounds=5"
    echo "sessions=$SESSIONS"
    echo "event_only_instrumentation=true"
    echo "use_event_counts_not_trace_timings=true"
    echo "P18_uninstrumented_ABBA_archive_sha256=df4b1e1f60a0f95d4e7a6523f8af3e390e1138402fa1ab3e0718a77f84a61da6"
    if command -v lscpu >/dev/null; then lscpu; fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332925000 + session * 101))"
    if (( session % 2 == 1 )); then
        modes=(trace-control trace-grace)
    else
        modes=(trace-grace trace-control)
    fi
    echo "P18 TRACE session=$session mode-order=${modes[*]}" >&2
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    for mode in "${modes[@]}"; do
        label="session$session-$mode"
        python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" snapshot \
            --cpus "$CPUSET" --mode observe \
            >>"$DEST/diagnostics/thermal-preflight.txt"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --interval 0.5 \
            --output "$DEST/telemetry/$label.csv" &
        MONITOR=$!
        if taskset -c "$CPUSET" \
            timeout --signal=TERM --kill-after=5s 300s \
            "$BIN_DIR/$mode" --profile focus512 --count 2048 \
            --waves 3 --warmup 2 --rounds 5 --seed "$seed" \
            >"$DEST/raw/$label.log" 2>&1; then
            kill "$MONITOR" 2>/dev/null || true
            wait "$MONITOR" 2>/dev/null || true
            MONITOR=""
        else
            rc=$?
            echo "P18 TRACE run failed: $label, exit=$rc" >&2
            exit "$rc"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"
        if [[ "$(wc -l <"$DEST/csv/$label.csv")" -ne 190 ]] ||
           [[ "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -ne 54 ]] ||
           [[ "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -ne 135 ]]; then
            echo "P18 TRACE incomplete 27-case CSV: $label" >&2
            exit 4
        fi
    done
    python3 "$ROOT/tools/research/m1_p18_512_trace_compare.py" \
        "$DEST/csv/session$session-trace-control.csv" \
        "$DEST/csv/session$session-trace-grace.csv" \
        --min-rows 189 \
        >"$DEST/diagnostics/session$session-event-compare.txt"
done

python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" review \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"
{
    for session in $(seq 1 "$SESSIONS"); do
        echo "== session $session event-only =="
        cat "$DEST/diagnostics/session$session-event-compare.txt"
    done
} >"$DEST/summary.txt"
tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 event-only native evidence: $DEST.tar.gz"
echo "Trace wave times are instrumentation-confounded and NOT speed evidence."
