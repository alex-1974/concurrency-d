#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
P23="$BASE/concurrency/research/m1_p23_owned.d"
P35="$BASE/concurrency/research/m1_p35_owned.d"
CONSUMER="$BASE/consumer/p35_generational_owner.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$P23" "$P35" "$CONSUMER"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$P23" && ! -e "$P35" && ! -e "$CONSUMER" ]] || exit 2
python3 "$ROOT/tools/research/m1_p35_source_audit.py"
python3 "$ROOT/tools/research/m1_p35_make_owner.py" "$ROOT" "$P23" "$P35"
python3 "$ROOT/tools/research/m1_p35_make_consumer.py" "$BASE/consumer/p29_generational_owner.d" "$CONSUMER"
for arm in null timed; do
  timeout --signal=TERM --kill-after=5s 180s dub run --root="$BASE" --compiler="$DC" --build=debug --config="p35-$arm" --d-version=P31Benchmark -- --count 384 --workers 4 --ingress 32 --retained 128 --warmup 1 --rounds 3 >"$TMP/$arm.raw" 2>&1 || {
    cat "$TMP/$arm.raw" >&2; exit 1;
  }
  grep -Fx P35_OWNER_MUTEX_BENCHMARK_PASS "$TMP/$arm.raw" >/dev/null
  grep -E '^(phase,round,work|warmup,|measure,)' "$TMP/$arm.raw" >"$TMP/$arm.csv"
done
python3 "$ROOT/tools/research/m1_p35_compare.py" "$TMP/null.csv" "$TMP/timed.csv" --min-rounds 3
echo P35_OWNER_COMPILER_CORRECTNESS_PASS
