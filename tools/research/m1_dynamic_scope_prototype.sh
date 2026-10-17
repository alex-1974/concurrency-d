#!/usr/bin/env bash
# Standalone M1 P03 research; not a production package/public contract.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || { echo "missing compiler: $DC" >&2; exit 2; }
"$DC" --version

"$DC" -preview=dip1000 "-I$ROOT/source" \
  "-of=$TMP/m1-p03-dynamic-scope" \
  "$ROOT/source/concurrency/internal/task_record.d" \
  "$ROOT/research/m1_task_lifetime/prototypes/p03_dynamic_lexical_scope/concurrency/research/m1_dynamic_scope.d"
timeout --signal=TERM --kill-after=5s 45s "$TMP/m1-p03-dynamic-scope" >"$TMP/p03-normal.log"
grep -qx 'P03_NESTED_SCOPE_ORDER_PASS' "$TMP/p03-normal.log"
cat "$TMP/p03-normal.log"

# P03 release-mode correctness must remain live: all admissions and oracle
# checks used to be assert() statements, which D -release elides.
"$DC" -release -preview=dip1000 "-I$ROOT/source" \
  "-of=$TMP/m1-p03-dynamic-scope-release" \
  "$ROOT/source/concurrency/internal/task_record.d" \
  "$ROOT/research/m1_task_lifetime/prototypes/p03_dynamic_lexical_scope/concurrency/research/m1_dynamic_scope.d"
timeout --signal=TERM --kill-after=5s 45s "$TMP/m1-p03-dynamic-scope-release" >"$TMP/p03-release.log"
grep -qx 'P03_NESTED_SCOPE_ORDER_PASS' "$TMP/p03-release.log"
cat "$TMP/p03-release.log"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    # Keep assert checks enabled: this is optimized correctness, not a benchmark.
    "$DC" -O3 -preview=dip1000 "-I$ROOT/source" \
      "-of=$TMP/m1-p03-dynamic-scope-O3" \
      "$ROOT/source/concurrency/internal/task_record.d" \
      "$ROOT/research/m1_task_lifetime/prototypes/p03_dynamic_lexical_scope/concurrency/research/m1_dynamic_scope.d"
    timeout --signal=TERM --kill-after=5s 45s "$TMP/m1-p03-dynamic-scope-O3" >"$TMP/p03-optimized.log"
grep -qx 'P03_NESTED_SCOPE_ORDER_PASS' "$TMP/p03-optimized.log"
cat "$TMP/p03-optimized.log"
fi
