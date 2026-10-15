#!/usr/bin/env bash
# P32-B: identical pinned M0 task/producer workload, untouched vs P15-timed.
# Existing P15 overlay is reused, NOT a second scheduler.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p32_admission_contention"
P15="$ROOT/research/m1_task_lifetime/prototypes/p15_mutex_timing"
GENERATED="$P15/generated/concurrency/research/m1_p15_pool.d"
TEMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TEMP"; rm -f -- "$GENERATED"; }
trap cleanup EXIT
[[ ! -e "$GENERATED" ]] || { echo 'P32 stale generated source' >&2; exit 1; }
python3 "$ROOT/tools/research/m1_p32_source_audit.py" --self-test
python3 "$ROOT/tools/research/m1_p32_classify.py" --self-test
python3 "$ROOT/tools/research/m1_p15_make_mutex_probe.py" \
  "$ROOT/source/concurrency/internal/submission_pool.d" "$GENERATED"

for build in debug release; do
  for variant in control timed; do
    timeout --signal=TERM --kill-after=5s 180s \
      dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config="$variant" -- --count 384 --workers 4 \
        --ingress 32 --warmup 1 --rounds 3 \
        >"$TEMP/$build-$variant.raw" 2>&1 || {
          cat "$TEMP/$build-$variant.raw" >&2; exit 1;
        }
    grep -Fx 'P32_M0_CONTROL_TIMED_PASS' \
      "$TEMP/$build-$variant.raw" >/dev/null
    grep -E '^(phase,round,producers|warmup,|measure,)' \
      "$TEMP/$build-$variant.raw" >"$TEMP/$build-$variant.csv"
  done
  python3 "$ROOT/tools/research/m1_p32_compare.py" \
    "$TEMP/$build-control.csv" "$TEMP/$build-timed.csv" --min-rounds 3
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
  for variant in control-optimized timed-optimized; do
    timeout --signal=TERM --kill-after=5s 180s \
      dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config="$variant" -- --count 384 --workers 4 \
        --ingress 32 --warmup 1 --rounds 3 \
        >"$TEMP/$variant.raw" 2>&1 || {
          cat "$TEMP/$variant.raw" >&2; exit 1;
        }
    grep -Fx 'P32_M0_CONTROL_TIMED_PASS' "$TEMP/$variant.raw" >/dev/null
    grep -E '^(phase,round,producers|warmup,|measure,)' \
      "$TEMP/$variant.raw" >"$TEMP/$variant.csv"
  done
  python3 "$ROOT/tools/research/m1_p32_compare.py" \
    "$TEMP/control-optimized.csv" "$TEMP/timed-optimized.csv" --min-rounds 3
fi
echo 'P32_B_COMPILER_CORRECTNESS_PASS (timings diagnostic only)'
