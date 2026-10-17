#!/usr/bin/env bash
# P42.16 only: matched observed-arm XPS diagnostic capture.
# Does not benchmark the original uninstrumented M0 versus P42.6 throughput.
set -euo pipefail
export LC_ALL=C
if (( $# != 1 )); then
    echo "usage: $0 NEW-OUTPUT-DIRECTORY" >&2
    exit 2
fi
ROOT="$(git rev-parse --show-toplevel)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$ROOT/tools/research/m1_p42_make_conditional_pool.py"
SOURCE="$ROOT/source/concurrency/internal/submission_pool.d"
CONDITIONAL="$BASE/concurrency/research/m1_p42_pool.d"
BASELINE="$BASE/concurrency/research/m1_p42_baseline_pool.d"
OUT="$1"
for path in "$OUT" "$CONDITIONAL" "$BASELINE"; do
    if [[ -e "$path" ]]; then
        echo "refusing to overwrite existing result or overlay: $path" >&2
        exit 2
    fi
done
mkdir -p "$OUT/bin" "$OUT/raw" "$OUT/telemetry"
OUT="$(cd "$OUT" && pwd)"
cleanup() { rm -f -- "$CONDITIONAL" "$BASELINE"; }
trap cleanup EXIT

python3 -m py_compile "$GEN" "$ROOT/tools/research/m1_p42_multi_idle_extract.py"
python3 "$GEN" "$SOURCE" "$CONDITIONAL" conditional
python3 "$GEN" "$SOURCE" "$BASELINE" baseline

# Exactly the same wait instrumentation; only the publish policy differs.
python3 - "$CONDITIONAL" "$BASELINE" <<'PY'
from pathlib import Path
import sys
cond, base = (Path(x).read_text() for x in sys.argv[1:])
cond = cond.replace("module concurrency.research.m1_p42_pool;",
                    "module concurrency.research.p42_matched;")
base = base.replace("module concurrency.research.m1_p42_baseline_pool;",
                    "module concurrency.research.p42_matched;")
cnotify = """// P42 conditional hypothesis; guarded by the inbox mutex.
            if (_waiters != 0)
                _changed.notify();"""
bnotify = """// P42 baseline: retain unconditional publication notification.
            _changed.notify();"""
assert cond.count(cnotify) == 1 and base.count(bnotify) == 1
assert cond.replace(cnotify, "P42_POLICY") == base.replace(bnotify, "P42_POLICY")
print("P42_MATCHED_OBSERVATION_PREFLIGHT_PASS")
PY

git -C "$ROOT" rev-parse HEAD > "$OUT/commit.txt"
git -C "$ROOT" status --porcelain=v1 -uno > "$OUT/worktree_status.txt"
ldc2 --version > "$OUT/compiler.txt"
dub --version > "$OUT/dub.txt"
uname -a > "$OUT/platform.txt"
lscpu > "$OUT/cpu.txt"
date -u --iso-8601=seconds > "$OUT/start_utc.txt"
sha256sum "$SOURCE" "$GEN" "$CONDITIONAL" "$BASELINE" \
    "$BASE/consumer/p42_multi_idle.d" "$BASE/dub.sdl" > "$OUT/sources.sha256"

telemetry() {
    local file="$1"
    {
        date -u --iso-8601=seconds
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            [[ -f "$zone" ]] || continue
            printf '%s=' "$zone"
            cat "$zone" || true
        done
        for frequency in /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq; do
            [[ -f "$frequency" ]] || continue
            printf '%s=' "$frequency"
            cat "$frequency" || true
        done
        if command -v sensors >/dev/null 2>&1; then
            sensors || true
        fi
    } > "$file" 2>&1
}
telemetry "$OUT/telemetry/start.txt"

for arm in baseline conditional; do
    echo "P42_NATIVE_BUILD arm=$arm"
    dub build --root="$BASE" --compiler=ldc2 --build=release \
        --config="p42-multi-idle-$arm" --force > "$OUT/build-$arm.log" 2>&1
    cp "$BASE/m1-p11-real-pool" "$OUT/bin/$arm"
done
sha256sum "$OUT/bin/baseline" "$OUT/bin/conditional" > "$OUT/binaries.sha256"

for arm in baseline conditional; do
    for warmup in 1 2; do
        echo "P42_NATIVE_WARMUP arm=$arm run=$warmup"
        timeout --signal=TERM --kill-after=5s 180s "$OUT/bin/$arm" > /dev/null
    done
done
for session in 1 2 3; do
    telemetry "$OUT/telemetry/session-$session-before.txt"
    for pair in 1 2 3 4 5 6; do
        if (( (session + pair) % 2 )); then
            order="conditional baseline"
        else
            order="baseline conditional"
        fi
        for arm in $order; do
            echo "P42_NATIVE_MEASURE session=$session pair=$pair arm=$arm"
            raw="$OUT/raw/s$session-p$pair-$arm.txt"
            timeout --signal=TERM --kill-after=5s 180s "$OUT/bin/$arm" > "$raw"
            grep -q "^P42_MULTI_IDLE_PASS workers=4 rounds=12 cases=3 " "$raw"
            [[ "$(grep -c "^P42_MULTI_IDLE_WAIT arm=$arm " "$raw")" == 36 ]]
            [[ "$(grep -c "^P42_MULTI_IDLE_TASK arm=$arm " "$raw")" == 444 ]]
            [[ "$(grep -c "^P42_MULTI_IDLE arm=$arm " "$raw")" == 36 ]]
        done
        telemetry "$OUT/telemetry/s$session-p$pair.txt"
    done
done
python3 "$ROOT/tools/research/m1_p42_multi_idle_extract.py" "$OUT" \
    > "$OUT/extraction.log"
sha256sum "$OUT/raw/"* "$OUT/tasks.csv" "$OUT/rounds.csv" \
    > "$OUT/results.sha256"
date -u --iso-8601=seconds > "$OUT/end_utc.txt"
telemetry "$OUT/telemetry/end.txt"
echo "P42_MULTI_IDLE_NATIVE_COMPLETE $OUT"
