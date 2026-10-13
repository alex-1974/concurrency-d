#!/usr/bin/env bash
# M1 P10: real M0 TaskRef dispatch with CT-specialized inline value records.
# This is correctness/source-safety research, NOT a fair speed benchmark.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p10_typed_transport"
P09="$ROOT/research/m1_task_lifetime/prototypes/p09_transfer_contract"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

"$DC" --version
SOURCE=(
    "$ROOT/source/concurrency/internal/task_record.d"
    "$P09/concurrency/research/m1_inline_transfer.d"
    "$BASE/concurrency/research/m1_typed_transport.d"
)
INCLUDE=("-I$ROOT/source" "-I$P09" "-I$BASE")
POSITIVE="$BASE/consumer/positive_typed_consumer.d"

"$DC" -preview=dip1000 "${INCLUDE[@]}" \
    "-of=$TMP/p10-typed" "${SOURCE[@]}" "$POSITIVE"
timeout --signal=TERM --kill-after=2s 20s "$TMP/p10-typed"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "${INCLUDE[@]}" \
        "-of=$TMP/p10-typed-O3" "${SOURCE[@]}" "$POSITIVE"
    timeout --signal=TERM --kill-after=2s 20s "$TMP/p10-typed-O3"
fi

for kind in \
    negative_borrowed_pointer negative_borrowed_field \
    negative_slice_input negative_class_result \
    negative_delegate_operation negative_unsafe_operation \
    negative_nonpure_operation
do
    if "$DC" -c -preview=dip1000 "${INCLUDE[@]}" \
        "-of=$TMP/$kind.o" "$BASE/consumer/$kind.d" \
        >"$TMP/$kind.log" 2>&1; then
        echo "FAIL P10: $kind unexpectedly compiled" >&2
        exit 1
    fi
    if ! grep -Eq 'evaluateInline|isInlineTransfer' "$TMP/$kind.log"; then
        echo "FAIL P10: $kind failed for unrelated diagnostic" >&2
        cat "$TMP/$kind.log" >&2
        exit 1
    fi
    echo "P10 typed API negative: $kind EXPECTED REJECTION"
    cat "$TMP/$kind.log"
done

# Challenge two real @trusted boundaries, one by one, in the real P10
# source. A compile error for safety is *necessity*, not a proof of trust.
for marker in launch cast; do
    python3 - "$BASE/concurrency/research/m1_typed_transport.d" \
        "$TMP/m1_typed_transport_$marker.d" "$marker" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
kind = sys.argv[3]
if kind == "launch":
    old = "size_t count,\n    R function(P) @safe pure nothrow @nogc action) @trusted"
    new = old.replace("@trusted", "@safe")
else:
    old = "private static TypedRecord* fromHeader(shared(TaskHeader)* raw)\n        @trusted"
    new = old.replace("@trusted", "@safe")
if source.count(old) != 1:
    raise SystemExit(f"P10 trust marker {kind} count={source.count(old)}")
Path(sys.argv[2]).write_text(source.replace(old, new, 1))
PY
    if "$DC" -c -preview=dip1000 "${INCLUDE[@]}" \
        "-of=$TMP/challenge-$marker.o" \
        "$TMP/m1_typed_transport_$marker.d" "$POSITIVE" \
        >"$TMP/challenge-$marker.log" 2>&1; then
        echo "FAIL P10: challenged $marker @safe unexpectedly compiled" >&2
        exit 1
    fi
    if ! grep -Eq '@safe|@system|cast from' "$TMP/challenge-$marker.log"; then
        echo "FAIL P10: $marker challenge failed for unrelated reason" >&2
        cat "$TMP/challenge-$marker.log" >&2
        exit 1
    fi
    echo "P10 necessary trusted boundary ($marker): confirmed by @safe challenge"
    cat "$TMP/challenge-$marker.log"
done

echo "P10 typed real M0 TaskRef research gate: PASS"
