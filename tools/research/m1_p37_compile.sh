#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
DIR="$BASE/concurrency/research"
POOL="$DIR/m1_p37_pool.d"
P23="$DIR/m1_p23_owned.d"
OWNER="$DIR/m1_p37_owned.d"
CONSUMER="$BASE/consumer/p37_generational_owner.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$POOL" "$P23" "$OWNER" "$CONSUMER"; rm -rf -- "$TMP"; }
trap cleanup EXIT
for path in "$POOL" "$P23" "$OWNER" "$CONSUMER"; do
  [[ ! -e "$path" ]] || { echo "P37 refuses existing: $path" >&2; exit 2; }
done
python3 "$ROOT/tools/research/m1_p37_source_audit.py"
python3 "$ROOT/tools/research/m1_p37_make_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
python3 "$ROOT/tools/research/m1_p37_make_owner.py" "$ROOT" "$P23" "$OWNER"
python3 "$ROOT/tools/research/m1_p37_make_consumer.py" "$ROOT" "$BASE/consumer/p29_generational_owner.d" "$CONSUMER"
for arm in null timed; do
  timeout --signal=TERM --kill-after=5s 180s dub run --root="$BASE" --compiler="$DC" --build=debug --config="p37-$arm" --d-version=P31Benchmark -- --count 384 --workers 4 --ingress 32 --retained 128 --warmup 1 --rounds 3 >"$TMP/$arm.raw" 2>&1 || { cat "$TMP/$arm.raw" >&2; exit 1; }
  grep -Fx P37_INBOX_BENCHMARK_PASS "$TMP/$arm.raw" >/dev/null
  grep -E '^(phase,round,work|warmup,|measure,)' "$TMP/$arm.raw" >"$TMP/$arm.csv"
done
python3 "$ROOT/tools/research/m1_p37_compare.py" "$TMP/null.csv" "$TMP/timed.csv" --min-rounds 3
echo P37_COMPILER_CORRECTNESS_PASS
