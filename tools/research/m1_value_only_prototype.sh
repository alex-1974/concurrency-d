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

# P05 same-module defensive precondition regression (no worker starts).
"$DC" -unittest -main -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
    "-of=$TMP/m1-p05-defensive-unittests" \
    "$ROOT/source/concurrency/internal/task_record.d" \
    "$BASE/concurrency/research/m1_value_scope.d"
"$TMP/m1-p05-defensive-unittests"
echo "P05 trusted-entry invalid count/null guards: PASS"

# Test-only injected failure after 0, 1 and 3 accepted TaskRefs.
# closeAndJoin must drain/return before executeCopied rethrows.
# DMD uses -version; LDC uses -d-version (where -version is --version).
VERSION_FLAG="-version=M1P05Fault"
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    VERSION_FLAG="-d-version=M1P05Fault"
fi
"$DC" -unittest -main "$VERSION_FLAG" -preview=dip1000 \
    "-I$ROOT/source" "-I$BASE" \
    "-of=$TMP/m1-p05-partial-enqueue-unittests" \
    "$ROOT/source/concurrency/internal/task_record.d" \
    "$BASE/concurrency/research/m1_value_scope.d"
"$TMP/m1-p05-partial-enqueue-unittests"
echo "P05 partial enqueue failure and join: PASS"

# QUALITY_GATES.md requires a compilation challenge for each @trusted
# marker. Change each marker individually to @safe, leaving the rest of
# the actual module identical. The expected result is a frontend rejection
# of a genuinely system-level operation, not a link failure.
for marker in launch cast; do
    python3 - "$BASE/concurrency/research/m1_value_scope.d" \
        "$TMP/m1_value_scope_p05_$marker.d" "$marker" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
destination = Path(sys.argv[2])
marker = sys.argv[3]
if marker == "launch":
    needle = "ScalarOperation operation) @trusted"
    replacement = "ScalarOperation operation) @safe"
elif marker == "cast":
    needle = "    @trusted nothrow @nogc"
    replacement = "    @safe nothrow @nogc"
else:
    raise SystemExit("invalid challenge")
if source.count(needle) != 1:
    raise SystemExit(f"expected one {marker} trust marker; found {source.count(needle)}")
destination.write_text(source.replace(needle, replacement, 1))
PY
    if "$DC" -c -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
         "-of=$TMP/p05_$marker.o" "$TMP/m1_value_scope_p05_$marker.d" \
         >"$TMP/p05_$marker.log" 2>&1; then
        echo "FAIL: $marker trusted function unexpectedly compiles @safe" >&2
        exit 1
    fi
    # At a minimum the failure must involve D's safety verification.
    if ! grep -Eq "@safe|@system|cast from" "$TMP/p05_$marker.log"; then
        echo "FAIL: $marker challenge did not fail for a safety reason" >&2
        cat -- "$TMP/p05_$marker.log" >&2
        exit 1
    fi
    echo "P05 required @trusted marker ($marker) verified: rejected as @safe"
    cat -- "$TMP/p05_$marker.log"
done

