#!/usr/bin/env bash
# P04: standalone scalar-only safe-consumer research gate.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p04_value_only"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || { echo "missing compiler: $DC" >&2; exit 2; }

"$DC" --version

# Actual consumer uses imported P04 module, with real M0 task transport.
"$DC" -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
    "-of=$TMP/m1-p04-safe-consumer" \
    "$ROOT/source/concurrency/internal/task_record.d" \
    "$BASE/concurrency/research/m1_value_scope.d" \
    "$BASE/consumer/positive_safe_consumer.d"
"$TMP/m1-p04-safe-consumer"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
        "-of=$TMP/m1-p04-safe-consumer-O3" \
        "$ROOT/source/concurrency/internal/task_record.d" \
        "$BASE/concurrency/research/m1_value_scope.d" \
        "$BASE/consumer/positive_safe_consumer.d"
    "$TMP/m1-p04-safe-consumer-O3"
fi

for name in \
    negative_captured_delegate \
    negative_system_function \
    negative_nonpure_function
do
    if "$DC" -c -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
        "-of=$TMP/$name.o" "$BASE/consumer/$name.d" >"$TMP/$name.log" 2>&1; then
        echo "FAIL: $name unexpectedly compiled" >&2
        exit 1
    fi
    # Compiler diagnostics differ across frontends: review their meaning
    # in GitHub Actions logs; never equate arbitrary failure with proof.
    echo "P04 expected compile rejection: $name"
    cat -- "$TMP/$name.log"
done
echo "P04 scalar-only language gate: PASS (safe consumer + 3 negative sources)"
