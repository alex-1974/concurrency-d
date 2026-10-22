#!/usr/bin/env bash
# P33 source-pinned P31 owner-path phases; correctness only in CI.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
OWNER="$BASE/concurrency/research/m1_p23_owned.d"
P33="$BASE/consumer/p33_generational_owner.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$OWNER" "$P33"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$OWNER" && ! -e "$P33" ]] || { echo 'P33 stale research-generated source' >&2; exit 1; }
python3 "$ROOT/tools/research/m1_p33_source_audit.py"
python3 "$ROOT/tools/research/m1_p33_make_phase.py" \
 "$BASE/consumer/p29_generational_owner.d" "$P33"
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
 "$ROOT/source/concurrency/internal/owned_task.d" "$OWNER"
for mode in debug release; do
  timeout --signal=TERM --kill-after=5s 180s \
    dub run --root="$BASE" --compiler="$DC" --build="$mode" \
      --config=p33-phases --d-version=P31Benchmark -- \
      --count 384 --workers 4 --ingress 32 --retained 128 \
      --warmup 1 --rounds 3 >"$TMP/$mode.raw" 2>&1 || {
      cat "$TMP/$mode.raw" >&2; exit 1;
    }
  grep -Fx P33_PHASE_BENCHMARK_PASS "$TMP/$mode.raw" >/dev/null
  grep -E '^(phase,round,work|warmup,|measure,)' "$TMP/$mode.raw" >"$TMP/$mode.csv"
  python3 "$ROOT/tools/research/m1_p33_analyze.py" \
      "$TMP/$mode.csv" --min-rounds 3
done
echo 'P33_PHASE_COMPILER_CORRECTNESS_PASS (timings diagnostic only)'
