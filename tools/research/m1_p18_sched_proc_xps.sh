#!/usr/bin/env bash
# P18 EXPLICITLY SELECTED unprivileged /proc observer, NOT a perf substitute.
# No kernel settings/permissions modified; runqueue wait may be unavailable.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-sched-proc-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P18_PROC_SESSIONS:-4}"
ROUNDS="${P18_PROC_ROUNDS:-24}"
CPUSET="${P18_PROC_CPUSET:-0,1,2,3}"
INTERVAL="${P18_PROC_INTERVAL_MS:-1}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p18_idle_grace"
P13="$ROOT/research/m1_task_lifetime/prototypes/p13_worker_scaling"
P162="$ROOT/research/m1_task_lifetime/prototypes/p16_2_atomic_completion"
BIN_DIR=""
cleanup() {
    if [[ -n "$BIN_DIR" ]]; then rm -rf -- "$BIN_DIR"; fi
}
trap cleanup EXIT

if [[ ! "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || (( SESSIONS > 8 )) ||
   [[ ! "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || (( ROUNDS > 24 )); then
    echo 'P18 /proc session/round parameter out of range' >&2
    exit 2
fi
for cmd in "$DC" dub taskset timeout python3 sha256sum tar cmp; do
    command -v "$cmd" >/dev/null || {
        echo "P18 /proc missing $cmd" >&2
        exit 2
    }
done
[[ "$(uname -s)" == Linux ]] || {
    echo 'P18 /proc requires Linux' >&2
    exit 2
}
taskset -c "$CPUSET" true

if [[ "${P18_PROC_PREFLIGHT_ONLY:-0}" == 1 ]]; then
    python3 "$ROOT/tools/research/m1_p18_sched_proc_sampler.py" probe
    exit
fi

if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 /proc refuses to overwrite $DEST" >&2
    exit 2
fi
mkdir -p "$DEST"/{raw,csv,proc,diagnostics}
DEST="$(cd "$DEST" && pwd)"
python3 "$ROOT/tools/research/m1_p18_sched_proc_sampler.py" probe \
    >"$DEST/diagnostics/proc-capabilities.json"
if [[ "${P18_PROC_REQUIRE_WAIT:-0}" == 1 ]]; then
    WAITFLAG=(--require-runqueue-wait)
else
    WAITFLAG=()
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
    echo 'P18 /proc original and candidate compiled identically' >&2
    exit 3
fi

# The real M0/P18 close-producer races must still pass without instrumentation.
for mode in race-control race-grace; do
    taskset -c "$CPUSET" timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode" -- 12 >"$DEST/diagnostics/$mode.log" 2>&1
done

{
    echo 'study=read-only-own-process-procfs-thread-polling'
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "M0_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "affinity=$CPUSET"
    echo "sessions=$SESSIONS"
    echo "rounds=$ROUNDS"
    echo "requested_interval_ms=$INTERVAL"
    echo 'profiles=sched8,sched2048; workers=1; iterations=512'
    echo 'count=2048; waves=3; warmups=2'
    echo 'process_order=ABBA/BAAB'
    echo 'perf_scope=none; source=/proc/launched_PID/task/TID'
    echo 'observed_thread_deltas_are_sample_window_lower_bounds=true'
    echo 'per_thread_lifetimes_NOT_observed_completely=true'
    echo 'missing_sched_schedstats_means_no_runqueue_wait_measurement=true'
    echo 'worker_TIDs_unverified_by_just_nonmain_thread=true'
    echo 'CPU_migrations_between_samples_may_be_missed=true'
    echo 'no_production_speed_verdict=true'
    echo 'previous_uninstrumented_SHA256=a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63'
    if command -v lscpu >/dev/null; then lscpu; fi
    if command -v sensors >/dev/null; then sensors || true; fi
} >"$DEST/manifest.txt"

for session in $(seq 1 "$SESSIONS"); do
    seed="$((332925000 + session * 101))"
    if (( session % 2 == 1 )); then
        modes=(control grace grace control)
    else
        modes=(grace control control grace)
    fi
    printf '%s\n' "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    for profile in sched8 sched2048; do
        seen_control=0
        seen_grace=0
        for mode in "${modes[@]}"; do
            if [[ "$mode" == control ]]; then
                seen_control=$((seen_control + 1))
                ordinal="$seen_control"
            else
                seen_grace=$((seen_grace + 1))
                ordinal="$seen_grace"
            fi
            label="session${session}-${profile}-${mode}${ordinal}"
            echo "P18 /proc collecting $label" >&2
            python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" \
                snapshot --cpus "$CPUSET" --mode observe \
                >>"$DEST/diagnostics/thermal-preflight.txt"
            python3 "$ROOT/tools/research/m1_p18_sched_proc_sampler.py" record \
                --binary "$BIN_DIR/$mode" --profile "$profile" \
                --cpus "$CPUSET" --count 2048 --waves 3 \
                --rounds "$ROUNDS" --seed "$seed" \
                --interval-ms "$INTERVAL" --timeout-s 90 \
                --stdout "$DEST/raw/$label.log" \
                --samples "$DEST/proc/$label-samples.csv" \
                --summary "$DEST/proc/$label-summary.json" \
                "${WAITFLAG[@]}" \
                >"$DEST/diagnostics/$label-collector.log" \
                2>"$DEST/diagnostics/$label-collector.err"
            grep -E '^(phase,round,|warmup,|measure,)' \
                "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"
            if [[ "$(wc -l <"$DEST/csv/$label.csv")" -ne $((ROUNDS+3)) ]] ||
               [[ "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -ne 2 ]] ||
               [[ "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -ne "$ROUNDS" ]]; then
                echo "P18 /proc incomplete scenario rows $label" >&2
                exit 4
            fi
            python3 "$ROOT/tools/research/m1_p18_sched_check.py" \
                "$DEST/csv/$label.csv" --profile "$profile" --rounds "$ROUNDS" \
                >"$DEST/diagnostics/$label-taskref-check.txt"
            python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" \
                snapshot --cpus "$CPUSET" --mode observe \
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
echo "P18 optional /proc observational archive: $DEST.tar.gz"
echo "WARNING: never use these polling-perturbed timings for speed qualification."
