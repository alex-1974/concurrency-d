#!/usr/bin/env bash
# P18 research-only XPS: one-worker ingress/producer backpressure contrast.
# Exact M0/P18 TaskRefs; 2048-slot ingress cannot reject a 2048-task wave.
# Uninstrumented whole-release control / grace / grace / control processes.
# Reversed BAAB in alternating sessions. No production source changes.
set -euo pipefail

DC="${1:-ldc2}"
DEST="${2:-/tmp/p18-single-ingress-$(date +%Y%m%d-%H%M%S)}"
SESSIONS="${P18_SINGLE_SESSIONS:-4}"
CPUSET="${P18_SINGLE_CPUSET:-0,1,2,3}"
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
    echo "P18 single-ingress invalid session count" >&2
    exit 2
fi
if [[ -e "$DEST" || -e "$DEST.tar.gz" ]]; then
    echo "P18 single-ingress refuses to overwrite: $DEST" >&2
    exit 2
fi
for cmd in "$DC" dub taskset timeout python3 sha256sum tar cmp; do
    command -v "$cmd" >/dev/null
done
taskset -c "$CPUSET" true

python3 "$ROOT/tools/research/m1_p18_make_grace_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" \
    "$BASE/generated/concurrency/research/m1_p18_grace_pool.d"
python3 "$ROOT/tools/research/m1_p18_make_fixture.py" \
    "$P13/concurrency/research/m1_scaling_kernel.d" \
    "$P13/consumer/main.d" "$P162/race/main.d" "$BASE/generated"

mkdir -p "$DEST"/{raw,csv,diagnostics,telemetry}
DEST="$(cd "$DEST" && pwd)"
BIN_DIR="$(mktemp -d)"

# The two measured binaries are prebuilt and immutable throughout A/B/B/A.
for mode in control grace; do
    dub build --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode"
    cp "$BASE/m1-p18-idle-grace" "$BIN_DIR/$mode"
    sha256sum "$BIN_DIR/$mode" >>"$DEST/diagnostics/binary-sha256.txt"
done
if cmp -s "$BIN_DIR/control" "$BIN_DIR/grace"; then
    echo "P18 single-ingress fail closed: identical compiled variants" >&2
    exit 3
fi

# Actual native close/producer races, both arms, outside timed processes.
for mode in race-control race-grace; do
    taskset -c "$CPUSET" timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config="$mode" -- 12
done

{
    echo "study=P18 one-worker ingress-backpressure uninstrumented A/B/B/A comparison"
    echo "started_utc=$(date -u -Iseconds)"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "M0_source_blob=$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version
    dub --version
    uname -a
    echo "process_affinity=$CPUSET"
    echo "individual_worker_pinning=false"
    echo "sessions=$SESSIONS"
    echo "process_order=ABBA_alternating_with_BAAB"
    echo "profile=singleingress"
    echo "iterations=128,512,1024"
    echo "workers=1"
    echo "ingress=8,64,256,2048"
    echo "tasks_per_wave=2048"
    echo "waves=3"
    echo "warmups=2"
    echo "measured_rounds=5"
    echo "target_iteration=512"
    echo "diagnostic_control_iterations=128,1024"
    echo "ingress_2048_equals_tasks_per_wave_no_full_retries_expected=true"
    echo "ingress_capacity_changes_worker_producer_interaction=true"
    echo "no_speed_thresholds=true"
    echo "thermals=observe_not_admission"
    echo "no_qualified_energy_measurement=true"
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
    echo "P18 single-ingress session=$session order=${modes[*]}" >&2
    echo "${modes[*]}" >"$DEST/diagnostics/session$session-order.txt"
    seen_control=0
    seen_grace=0
    for mode in "${modes[@]}"; do
        if [[ "$mode" == control ]]; then
            seen_control=$((seen_control + 1))
            rep=$seen_control
        else
            seen_grace=$((seen_grace + 1))
            rep=$seen_grace
        fi
        label="session${session}-${mode}${rep}"
        python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" snapshot \
            --cpus "$CPUSET" --mode observe \
            >>"$DEST/diagnostics/thermal-preflight.txt"
        python3 "$ROOT/tools/research/m1_p17_telemetry.py" \
            --cpus "$CPUSET" --interval 0.5 \
            --output "$DEST/telemetry/$label.csv" &
        MONITOR=$!
        if taskset -c "$CPUSET" \
            timeout --signal=TERM --kill-after=5s 300s \
            "$BIN_DIR/$mode" --profile singleingress --count 2048 \
            --waves 3 --warmup 2 --rounds 5 --seed "$seed" \
            >"$DEST/raw/$label.log" 2>&1; then
            kill "$MONITOR" 2>/dev/null || true
            wait "$MONITOR" 2>/dev/null || true
            MONITOR=""
        else
            rc=$?
            echo "P18 single-ingress failed: $label rc=$rc" >&2
            exit "$rc"
        fi
        grep -E '^(phase,round,|warmup,|measure,)' \
            "$DEST/raw/$label.log" >"$DEST/csv/$label.csv"
        # Exactly 12 configurations x (2 warm-up + 5 measured) rounds,
        # plus one header. A truncated or changed fixture must fail closed.
        if [[ "$(wc -l <"$DEST/csv/$label.csv")" -ne 85 ]] ||
           [[ "$(grep -c '^warmup,' "$DEST/csv/$label.csv")" -ne 24 ]] ||
           [[ "$(grep -c '^measure,' "$DEST/csv/$label.csv")" -ne 60 ]]; then
            echo "P18 single-ingress incomplete/modified CSV: $label" >&2
            exit 4
        fi
        python3 "$ROOT/tools/research/m1_p18_single_ingress_check.py" \
            "$DEST/csv/$label.csv" --count 2048 --waves 3 --warmup 2 \
            --rounds 5 >"$DEST/diagnostics/$label-ingress-audit.txt"
    done
    for rep in 1 2; do
        python3 "$ROOT/tools/research/m1_p18_compare.py" \
            "$DEST/csv/session${session}-control${rep}.csv" \
            "$DEST/csv/session${session}-grace${rep}.csv" \
            --min-rows 84 >"$DEST/diagnostics/session${session}-pair${rep}.txt"
    done
done

python3 "$ROOT/tools/research/m1_p18_thermal_audit.py" review \
    "$DEST/telemetry" "$DEST/thermal-summary.csv" \
    >"$DEST/thermal-review.txt"

{
    for session in $(seq 1 "$SESSIONS"); do
        for rep in 1 2; do
            echo "== session $session adjacent-pair $rep =="
            cat "$DEST/diagnostics/session${session}-pair${rep}.txt"
        done
    done
} >"$DEST/summary.txt"

tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
sha256sum "$DEST.tar.gz"
echo "P18 single-ingress source-pinned ABBA archive: $DEST.tar.gz"
echo "Privacy: inspect manifest/raw local host paths before publication."
