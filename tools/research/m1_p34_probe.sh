#!/usr/bin/env bash
# P34 bounded correctness gate; CI durations are not performance evidence.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
OWNER="$BASE/concurrency/research/m1_p23_owned.d"
GEN="$BASE/consumer/p34_generational_owner.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$OWNER" "$GEN"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$OWNER" && ! -e "$GEN" ]] || { echo 'P34 stale generated source' >&2; exit 1; }
python3 "$ROOT/tools/research/m1_p34_compare.py" --self-test
python3 "$ROOT/tools/research/m1_p34_source_audit.py"
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
 "$ROOT/source/concurrency/internal/owned_task.d" "$OWNER"
python3 "$ROOT/tools/research/m1_p34_make_wrapper.py" \
 "$BASE/consumer/p29_generational_owner.d" "$GEN"
for arm in null timed; do
  timeout --signal=TERM --kill-after=5s 180s \
    dub run --root="$BASE" --compiler="$DC" --build=debug \
      --config="p34-$arm" --d-version=P31Benchmark -- \
      --count 384 --workers 4 --ingress 32 --retained 128 \
      --warmup 1 --rounds 3 >"$TMP/$arm.raw" 2>&1 || {
       cat "$TMP/$arm.raw" >&2; exit 1;
      }
  grep -Fx P34_WRAPPER_BENCHMARK_PASS "$TMP/$arm.raw" >/dev/null
  grep -E '^(phase,round,work|warmup,|measure,)' "$TMP/$arm.raw" >"$TMP/$arm.csv"
done
python3 "$ROOT/tools/research/m1_p34_compare.py" "$TMP/null.csv" "$TMP/timed.csv" --min-rounds 3
echo "P34_WRAPPER_COMPILER_CORRECTNESS_PASS diagnostic_only=true"
