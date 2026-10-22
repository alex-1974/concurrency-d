#!/usr/bin/env bash
# P31 fixed-dimension native M0 producer scaling and task-side atomic oracle.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TEMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TEMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo 'P31 stale source-pinned clone' >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/owned_task.d)" = \
    e74d6a73f956c562eab176e27687a47249f5815d
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
python3 "$ROOT/tools/research/m1_p31_analyze.py" --self-test
bash -n "$ROOT/tools/research/m1_p31_xps.sh"

for mode in debug release; do
    timeout --signal=TERM --kill-after=5s 180s \
        dub run --root="$BASE" --compiler="$DC" --build="$mode" \
        --config=p29-generational --d-version=P31Benchmark -- \
        --count 384 --workers 4 --ingress 32 --retained 128 \
        --warmup 1 --rounds 3 >"$TEMP/$mode.log" 2>&1 || {
            cat "$TEMP/$mode.log" >&2; exit 1;
        }
    grep -Fx 'P31_FIXED_DIMENSIONS_BENCHMARK_PASS' "$TEMP/$mode.log" \
        >/dev/null || { cat "$TEMP/$mode.log" >&2; exit 1; }
    grep -E '^(phase,round,work|warmup,|measure,)' "$TEMP/$mode.log" \
        >"$TEMP/$mode.csv"
    python3 "$ROOT/tools/research/m1_p31_analyze.py" \
        --input "$TEMP/$mode.csv" --min-rounds 3 || {
            cat "$TEMP/$mode.csv" >&2; exit 1;
        }
done

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=5s 180s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=p29-generational-optimized --d-version=P31Benchmark -- \
        --count 384 --workers 4 --ingress 32 --retained 128 \
        --warmup 1 --rounds 3 >"$TEMP/optimized.log" 2>&1 || {
            cat "$TEMP/optimized.log" >&2; exit 1;
        }
    grep -Fx 'P31_FIXED_DIMENSIONS_BENCHMARK_PASS' "$TEMP/optimized.log" \
        >/dev/null || { cat "$TEMP/optimized.log" >&2; exit 1; }
    grep -E '^(phase,round,work|warmup,|measure,)' \
        "$TEMP/optimized.log" >"$TEMP/optimized.csv"
    python3 "$ROOT/tools/research/m1_p31_analyze.py" \
        --input "$TEMP/optimized.csv" --min-rounds 3 || {
            cat "$TEMP/optimized.csv" >&2; exit 1;
        }
fi
echo 'P31_COMPILER_CORRECTNESS_PASS (timings diagnostic only)'
