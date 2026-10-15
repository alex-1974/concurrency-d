#!/usr/bin/env bash
# P30: paired same-work correctness + diagnostic timing ONLY on CI.
# Actual performance conclusions require the separate native XPS capture.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TEMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TEMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo "P30 stale generated M0 owner" >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a || {
        echo 'P30 native pool source changed; re-audit required' >&2; exit 1;
    }
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
python3 "$ROOT/tools/research/m1_p30_analyze.py" --self-test
bash -n "$ROOT/tools/research/m1_p30_xps.sh"
for build in debug release; do
    # Same per-mode M0 work, admitted count and retention pressure.
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config=p29-generational --d-version=P30Benchmark -- \
        --count 384 --workers 2 --producers 2 --ingress 32 \
        --retained 64 --warmup 1 --rounds 3 \
        > "$TEMP/$build.raw" 2>&1 || {
            cat "$TEMP/$build.raw" >&2; exit 1;
        }
    grep -Fx 'P30_M0_OWNERSHIP_BENCHMARK_PASS' "$TEMP/$build.raw" >/dev/null || {
        cat "$TEMP/$build.raw" >&2; exit 1;
    }
    grep -E '^(phase,round,mode|warmup,|measure,)' \
        "$TEMP/$build.raw" > "$TEMP/$build.csv"
    python3 "$ROOT/tools/research/m1_p30_analyze.py" \
        --input "$TEMP/$build.csv" --min-rounds 3 || {
            cat "$TEMP/$build.csv" >&2; exit 1;
        }
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    # LDC -O3 with assertion oracles still enabled.
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=p29-generational-optimized --d-version=P30Benchmark -- \
        --count 384 --workers 2 --producers 4 --ingress 32 \
        --retained 64 --warmup 1 --rounds 3 \
        > "$TEMP/O3.raw" 2>&1 || {
            cat "$TEMP/O3.raw" >&2; exit 1;
        }
    grep -Fx 'P30_M0_OWNERSHIP_BENCHMARK_PASS' "$TEMP/O3.raw" >/dev/null || {
        cat "$TEMP/O3.raw" >&2; exit 1;
    }
    grep -E '^(phase,round,mode|warmup,|measure,)' \
        "$TEMP/O3.raw" > "$TEMP/O3.csv"
    python3 "$ROOT/tools/research/m1_p30_analyze.py" \
        --input "$TEMP/O3.csv" --min-rounds 3 || {
            cat "$TEMP/O3.csv" >&2; exit 1;
        }
fi
echo "P30_COMPILER_CORRECTNESS_PASS (CI timings DIAGNOSTIC ONLY)"
