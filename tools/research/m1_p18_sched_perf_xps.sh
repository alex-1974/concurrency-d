#!/usr/bin/env bash
# P18 research-only external Linux perf scheduler trace; NO SPEED qualification.
# perf records OTHER tasks on selected CPUs: raw perf.data is host-sensitive.
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-sched-perf-$(date +%Y%m%d-%H%M%S)}"
CPUSET="${P18_SCHED_CPUSET:-0,1,2,3}"
SESSIONS="${P18_SCHED_SESSIONS:-4}"
ROUNDS="${P18_SCHED_ROUNDS:-24}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
BIN_DIR=""
TEMP=""
cleanup() {
    if [[ -n "$BIN_DIR" ]]; then rm -rf -- "$BIN_DIR"; fi
    if [[ -n "$TEMP" ]]; then rm -rf -- "$TEMP"; fi
}
trap cleanup EXIT

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )) ||
   [[ ! "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || (( ROUNDS > 24 )); then
    echo 'P18 perf: require sessions=1..8 and rounds=1..24' >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 perf refuses overwrite: $DEST" >&2
    exit 2
fi
for executable in perf "$DC" dub taskset timeout python3 tar sha256sum cmp; do
    command -v "$executable" >/dev/null || {
        echo "P18 perf missing $executable" >&2
        exit 2
    }
done
[[ "$(uname -s)" == Linux ]] || { echo 'Linux required' >&2; exit 2; }
taskset -c "$CPUSET" true

TEMP="$(mktemp -d)"
mkdir -p "$DEST"/{raw,csv,diagnostics,perf}
DEST="$(cd "$DEST" && pwd)"
{
    echo "perf_executable=$(command -v perf)"
    perf --version
    echo "uname=$(uname -r)"
    echo "uid=$(id -u)"
    printf 'perf_event_paranoid='
    cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 'unavailable'
    echo 'events=sched_switch,sched_wakeup,sched_migrate_task'
    echo "affinity=$CPUSET"
} >"$DEST/diagnostics/perf-capability.txt"

# Explicit capability probe: fail closed, NO sudo/sysctl/security mutations.
# -a/-C records system-wide scheduler events only on selected CPUs.
# Per-process tracepoint sampling cannot reconstruct all sched-in/wakeup edges.
if ! perf record --no-buildid -o "$TEMP/preflight.data" -a -C "$CPUSET" \
        -e sched:sched_switch -e sched:sched_wakeup \
        -e sched:sched_migrate_task -- taskset -c "$CPUSET" sleep 0.12 \
        >"$DEST/diagnostics/perf-preflight.stdout" \
        2>"$DEST/diagnostics/perf-preflight.stderr"; then
    echo 'P18 perf: tracepoint permission or availability check failed.' >&2
    echo 'Review diagnostics; do not automatically lower perf security.' >&2
    exit 3
fi
if ! perf sched timehist -i "$TEMP/preflight.data" -s \
        >"$DEST/diagnostics/perf-preflight-summary.txt" \
        2>"$DEST/diagnostics/perf-preflight-summary.err"; then
    echo 'P18 perf: cannot decode scheduler trace' >&2
    exit 3
fi
if ! grep -q '[[:digit:]]' "$DEST/diagnostics/perf-preflight-summary.txt"; then
    echo 'P18 perf: no plausible scheduler events in capability probe' >&2
    exit 3
fi

if [[ "${P18_SCHED_PREFLIGHT_ONLY:-0}" == 1 ]]; then
    echo "P18 PERF preflight PASS; no DUB build or TaskRefs started"
    echo "Capability evidence: $DEST/diagnostics/"
    exit 0
fi

python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"
BIN_DIR="$(mktemp -d)"
for mode in control grace; do
    dub build --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode"
    cp "$BASE/m1-p18-idle-grace" "$BIN_DIR/$mode"
    sha256sum "$BIN_DIR/$mode" >>"$DEST/diagnostics/binaries-sha256.txt"
done
if cmp -s "$BIN_DIR/control" "$BIN_DIR/grace"; then
    echo 'P18 perf: M0/P18 binaries unexpectedly identical' >&2
    exit 3
fi

for mode in race-control race-grace; do
    taskset -c "$CPUSET" timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode" -- 12 >"$DEST/diagnostics/$mode.log" 2>&1
done

{
    echo 'study=external-Linux-scheduler-events; P18 bounded yield vs unchanged M0'
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "original_M0_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    echo "affinity=$CPUSET"
    echo "sessions=$SESSIONS"
    echo "rounds=$ROUNDS"
    echo 'profiles=sched8,sched2048'
    echo 'workers=1'
    echo 'iterations=512'
    echo 'count=2048'
    echo 'waves=3'
    echo 'warmups=2'
    echo 'process_order=ABBA/BAAB'
    echo 'perf_scope=all_tasks_on_selected_CPUs'
    echo 'perf_raw_contains_other_processes_and_thread_names=true'
    echo 'main_thread_tid_is_exec_wrapped_pid=true'
    echo 'native_workers_not_individually_affined=true'
    echo 'perf_trace_timing_NOT_uninstrumented_scheduler_speed=true'
    echo 'previous_uninstrumented_SHA256=a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63'
    uname -a
    if command -v lscpu >/dev/null; then lscpu; fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    if (( session % 2 == 1 )); then
        modes=(control grace grace control)
    else
        modes=(grace control control grace)
    fi
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    for profile in sched8 sched2048; do
        seen_control=0; seen_grace=0
        for mode in "${modes[@]}"; do
            if [[ "$mode" == control ]]; then
                seen_control=$((seen_control+1)); ordinal="$seen_control"
            else
                seen_grace=$((seen_grace+1)); ordinal="$seen_grace"
            fi
            label="session${session}-${profile}-${mode}${ordinal}"
            perfdata="$DEST/perf/$label.data"
            pidfile="$DEST/diagnostics/$label.pid"
            echo "P18 sched trace: $label" >&2
            python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" snapshot \
                --cpus "$CPUSET" --mode observe \
                >>"$DEST/diagnostics/thermal-preflight.txt"
            # The shell writes its PID, then execs taskset which execs the
            # benchmark. Main thread TID == PID; worker TIDs are distinct.
            # A timeout or event-loss condition invalidates this process.
            if ! timeout --signal=TERM --kill-after=5s 90s \
                perf record --no-buildid -o "$perfdata" -a -C "$CPUSET" \
                -e sched:sched_switch -e sched:sched_wakeup \
                -e sched:sched_migrate_task -- \
                bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
                _ "$pidfile" taskset -c "$CPUSET" "$BIN_DIR/$mode" \
                --profile "$profile" --count 2048 --waves 3 \
                --warmup 2 --rounds "$ROUNDS" \
                --seed "$((332925000+session*101))" \
                >"$DEST/raw/$label.log" \
                2>"$DEST/diagnostics/$label-perf.stderr"; then
                echo "P18 perf record/benchmark failed: $label" >&2
                exit 4
            fi
            [[ -s "$pidfile" && -s "$perfdata" ]] || {
                echo "P18 perf trace or main-thread PID missing: $label" >&2
                exit 4
            }
            pid="$(cat "$pidfile")"
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
                echo "P18 perf invalid PID: $pid" >&2
                exit 4
            }
            grep -E '^(phase,round,|warmup,|measure,)' "$DEST/raw/$label.log" \
                >"$DEST/csv/$label.csv"
            if [[ "$(wc -l <"$DEST/csv/$label.csv")" -ne $((ROUNDS+3)) ]] ||
               [[ "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -ne 2 ]] ||
               [[ "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -ne "$ROUNDS" ]]; then
                echo "P18 perf incomplete/wrong-case CSV: $label" >&2
                exit 4
            fi
            python3 "$ROOT/tools/research/m1_p18_sched_check.py" \
                "$DEST/csv/$label.csv" --profile "$profile" --rounds "$ROUNDS" \
                >"$DEST/diagnostics/$label-workload-check.txt"
            if ! perf sched timehist -i "$perfdata" -p "$pid" -s -M \
                >"$DEST/diagnostics/$label-target-summary.txt" \
                2>"$DEST/diagnostics/$label-target-summary.err"; then
                echo "P18 perf sched timehist summary failed: $label" >&2
                exit 5
            fi
            if ! grep -q '[[:digit:]]' "$DEST/diagnostics/$label-target-summary.txt"; then
                echo "P18 perf: no target scheduling rows: $label" >&2
                exit 5
            fi
            # Keep thread-level wakeups, context switches and CPU migration
            # text for later source-specific manual/parser audit.
            perf sched timehist -i "$perfdata" -p "$pid" -M -w \
                >"$DEST/diagnostics/$label-target-events.txt" \
                2>"$DEST/diagnostics/$label-target-events.err"
            python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" snapshot \
                --cpus "$CPUSET" --mode observe \
                >>"$DEST/diagnostics/thermal-postflight.txt"
        done
    done
    for profile in sched8 sched2048; do
        for half in 1 2; do
            python3 "$ROOT/tools/research/m1_p18_sched_check.py" \
                "$DEST/csv/session${session}-${profile}-control${half}.csv" \
                "$DEST/csv/session${session}-${profile}-grace${half}.csv" \
                --profile "$profile" --rounds "$ROUNDS" \
                >"$DEST/diagnostics/session${session}-${profile}-half${half}.txt"
        done
    done
done
tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 scheduler diagnostic archive: $DEST.tar.gz"
echo 'WARNING: perf.data includes host system-wide task metadata from CPUs selected.'
echo 'Do NOT treat trace-collected elapsed times as a speed comparison.'
