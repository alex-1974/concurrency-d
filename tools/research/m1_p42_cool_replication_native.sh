#!/usr/bin/env bash
# P42.19: independent cooled replication of unchanged P42.18 workloads.
# Target: 4 producers / 4 workers; drift-sensitive control: 1 producer / 1 worker.
# This is NOT a proof of task-lifetime safety or an isolated wakeup benchmark.
set -euo pipefail
export LC_ALL=C
if (( $# != 1 )); then
    echo "usage: $0 NEW-OUTPUT-DIRECTORY" >&2
    exit 2
fi
ROOT="$(git rev-parse --show-toplevel)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
SOURCE="$ROOT/source/concurrency/internal/submission_pool.d"
GEN="$ROOT/tools/research/m1_p42_make_conditional_pool.py"
GUARD="$ROOT/tools/research/m1_p42_thermal_guard.py"
CONDITIONAL="$BASE/concurrency/research/m1_p42_pool.d"
OUT="$1"
for path in "$OUT" "$CONDITIONAL"; do
    [[ ! -e "$path" ]] || {
        echo "refusing to overwrite result or overlay: $path" >&2
        exit 2
    }
done
# A dirty tracked tree is not an identifiable source-pinned experiment.
if [[ -n "$(git -C "$ROOT" status --porcelain=v1 -uno)" ]]; then
    echo "refusing a native benchmark with tracked worktree changes" >&2
    exit 2
fi
mkdir -p "$OUT/bin" "$OUT/raw" "$OUT/telemetry"
OUT="$(cd "$OUT" && pwd)"
printf 'INCOMPLETE: raw evidence retained; do not qualify\n' > "$OUT/run_state.txt"
cleanup() { rm -f -- "$CONDITIONAL"; }
trap cleanup EXIT
python3 -m py_compile "$GEN" "$ROOT/tools/research/m1_p42_e2e_analyze.py"
python3 "$ROOT/tools/research/m1_p42_e2e_analyze.py" --self-test
python3 "$GUARD" --self-test
SENSOR="$(python3 "$GUARD" discover)"
printf '%s\n' "$SENSOR" > "$OUT/package_sensor.txt"
printf 'event,run_id,utc,temp_mc\n' > "$OUT/thermal.csv"
# Historical two-argument generator has no P42.16/P42.17 flow or worker
# diagnostics. Only its waiter count is needed by the conditional policy.
python3 "$GEN" "$SOURCE" "$CONDITIONAL"
[[ -f "$CONDITIONAL" ]] || exit 3

git -C "$ROOT" rev-parse HEAD > "$OUT/commit.txt"
git -C "$ROOT" status --porcelain=v1 -uno > "$OUT/worktree_status.txt"
ldc2 --version > "$OUT/compiler.txt"
dub --version > "$OUT/dub.txt"
uname -a > "$OUT/platform.txt"
lscpu > "$OUT/cpu.txt"
date -u --iso-8601=seconds > "$OUT/start_utc.txt"
printf '%s\n' "P42.19 cooled replication; original P42 consumer, LDC --build=release" \
    "Target=4P/4W, drift control=1P/1W, light/medium cost" \
    "6 sessions x 6 pairs x 2 costs x 2 workloads x 2 policies" \
    "Tasks/run=131072; 2 warmups per binary/workload" \
    "Order alternates by session/pair/cost/scenario" \
    "Temperature coretemp Package id 0, two pre-arm readings <= 70000 mC separated by 3 seconds" \
    "Abort with preserved INCOMPLETE evidence after 600 s cooldown failure or >=95000 mC post-arm" \
    "Minimum 30 s between sessions; no governor or affinity changes" \
    "Temperature checks are pre/post snapshots, not continuous throttling exclusion" \
    > "$OUT/protocol.txt"
sha256sum "$SOURCE" "$GEN" "$CONDITIONAL" \
    "$BASE/consumer/p42_benchmark.d" "$BASE/dub.sdl" \
    "$ROOT/tools/research/m1_p42_e2e_native.sh" \
    "$ROOT/tools/research/m1_p42_e2e_analyze.py" \
    "$GUARD" "$ROOT/tools/research/m1_p42_cool_replication_native.sh" \
    > "$OUT/sources.sha256"

telemetry() {
    local destination="$1"
    {
        date -u --iso-8601=seconds
        taskset -pc "$$" || true
        [[ ! -f /proc/pressure/cpu ]] || cat /proc/pressure/cpu
        [[ ! -f /proc/loadavg ]] || cat /proc/loadavg
        for governor in /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
            if [[ -f "$governor" ]]; then
                printf '%s=' "$governor"
                cat "$governor" || true
            fi
        done
        for freq in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
            [[ -f "$freq" ]] || continue
            printf '%s=' "$freq"
            cat "$freq" || true
        done
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            [[ -f "$zone" ]] || continue
            printf '%s=' "$zone"
            cat "$zone" || true
        done
        if command -v sensors >/dev/null 2>&1; then sensors || true; fi
    } > "$destination" 2>&1
}
telemetry "$OUT/telemetry/start.txt"

# Both costs/arms use exactly the same DUB release mode and D compiler.
# No worker-level instrumentation, tracing, or separate arm-specific -O flags.
for cost in light medium; do
    for arm in baseline conditional; do
        echo "P42_E2E_BUILD cost=$cost arm=$arm"
        dub build --root="$BASE" --compiler=ldc2 --build=release \
            --config="p42-e2e-$arm-$cost" --force \
            > "$OUT/build-$cost-$arm.log" 2>&1
        [[ -x "$BASE/m1-p11-real-pool" ]] || exit 3
        cp "$BASE/m1-p11-real-pool" "$OUT/bin/$cost-$arm"
    done
done
sha256sum "$OUT/bin/"* > "$OUT/binaries.sha256"
readonly TASKS=131072
for cost in light medium; do
    for arm in baseline conditional; do
        for config in "1 1" "4 4"; do
            read -r producers workers <<< "$config"
            for warmup in 1 2; do
                echo "P42_E2E_WARMUP cost=$cost arm=$arm P=$producers W=$workers run=$warmup"
                timeout --signal=TERM --kill-after=5s 180s \
                    "$OUT/bin/$cost-$arm" "$producers" "$workers" "$TASKS" >/dev/null
            done
        done
    done
done

printf 'session,pair,cost,scenario,arm,producers,workers,tasks,elapsed_us\n' \
    > "$OUT/results.csv"
for session in 1 2 3 4 5 6; do
    # A separated thermal block; every arm also requires its own cool gate.
    if (( session > 1 )); then sleep 30; fi
    telemetry "$OUT/telemetry/session-$session-before.txt"
    for pair in 1 2 3 4 5 6; do
        if (( (session + pair) % 2 == 0 )); then
            costs=(light medium)
        else
            costs=(medium light)
        fi
        for cost in "${costs[@]}"; do
            if [[ "$cost" == light ]]; then cost_index=0; else cost_index=1; fi
            if (( (session + pair + cost_index) % 2 == 0 )); then
                scenarios=(target control)
            else
                scenarios=(control target)
            fi
            for scenario in "${scenarios[@]}"; do
                if [[ "$scenario" == target ]]; then
                    producers=4 workers=4
                else
                    producers=1 workers=1
                fi
                # Use complementary AB/BA order in different pairs. The
                # 1P1W control is still policy-exposed, not a pure CPU oracle.
                if [[ "$scenario" == target ]]; then scenario_index=0; else scenario_index=1; fi
                if (( (session + pair + cost_index + scenario_index) % 2 == 0 )); then
                    arms=(baseline conditional)
                else
                    arms=(conditional baseline)
                fi
                for arm in "${arms[@]}"; do
                    run_id="s$session-p$pair-$cost-$scenario-$arm"
                    raw="$OUT/raw/$run_id.txt"
                    echo "P42_E2E_COOL_CHECK $run_id"
                    python3 "$GUARD" cool "$SENSOR" "$OUT/thermal.csv" "$run_id"
                    echo "P42_E2E_RUN $run_id"
                    timeout --signal=TERM --kill-after=5s 180s \
                        "$OUT/bin/$cost-$arm" "$producers" "$workers" "$TASKS" > "$raw"
                    # Every captured arm must have a post-run reading; abort
                    # rather than selectively exclude a thermally hot result.
                    python3 "$GUARD" post "$SENSOR" "$OUT/thermal.csv" "$run_id"
                    [[ "$(wc -l < "$raw")" == 1 ]] || {
                        echo "unexpected multiline benchmark result $raw" >&2
                        exit 4
                    }
                    line="$(< "$raw")"
                    prefix="P42_BENCH arm=$arm producers=$producers workers=$workers tasks=$TASKS elapsed_us="
                    [[ "$line" == "$prefix"* ]] || {
                        echo "unexpected benchmark result: $line" >&2
                        exit 4
                    }
                    elapsed="${line#"$prefix"}"
                    [[ "$elapsed" =~ ^[0-9]+$ ]] && (( 10#$elapsed > 0 )) || {
                        echo "invalid elapsed_us: $elapsed" >&2
                        exit 4
                    }
                    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                        "$session" "$pair" "$cost" "$scenario" "$arm" \
                        "$producers" "$workers" "$TASKS" "$elapsed" >> "$OUT/results.csv"
                done
            done
        done
        telemetry "$OUT/telemetry/session-$session-pair-$pair.txt"
    done
done
python3 "$ROOT/tools/research/m1_p42_e2e_analyze.py" "$OUT" \
    > "$OUT/analysis.log"
python3 "$GUARD" audit "$OUT/thermal.csv" > "$OUT/thermal-audit.log"
sha256sum "$OUT/raw/"* "$OUT/results.csv" "$OUT/paired.csv" \
    "$OUT/sessions.csv" "$OUT/thermal.csv" > "$OUT/results.sha256"
date -u --iso-8601=seconds > "$OUT/end_utc.txt"
telemetry "$OUT/telemetry/end.txt"
printf 'COMPLETE: parser and thermal gates PASS; research only\n' > "$OUT/run_state.txt"
echo "P42_COOLED_REPLICATION_COMPLETE $OUT"
