#!/usr/bin/env bash
# P09 research-only checked inline payload and supervisor state.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p09_transfer_contract"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || exit 2
"$DC" --version

"$DC" -preview=dip1000 "-I$BASE" \
  "-of=$TMP/positive-inline" \
  "$BASE/concurrency/research/m1_inline_transfer.d" \
  "$BASE/consumer/positive_inline_consumer.d"
"$TMP/positive-inline"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "-I$BASE" \
      "-of=$TMP/positive-inline-O3" \
      "$BASE/concurrency/research/m1_inline_transfer.d" \
      "$BASE/consumer/positive_inline_consumer.d"
    "$TMP/positive-inline-O3"
fi

# Compile-only NEGATIVE fixtures against the actual research API module.
# Guard against failures unrelated to the intended constrained overload.
for file in \
    negative_raw_pointer negative_slice negative_borrowed_member \
    negative_delegate_member negative_class_ref negative_function_ptr
do
    if "$DC" -c -preview=dip1000 "-I$BASE" \
        "-of=$TMP/$file.o" "$BASE/consumer/$file.d" \
        >"$TMP/$file.log" 2>&1; then
        echo "FAIL: P09 $file unexpectedly compiled" >&2
        exit 1
    fi
    if ! grep -Eq 'snapshotInline|isInlineTransfer' "$TMP/$file.log"; then
        echo "FAIL: P09 $file rejected for an unrelated reason" >&2
        cat "$TMP/$file.log" >&2
        exit 1
    fi
    echo "P09 expected typed rejection: $file"
    cat "$TMP/$file.log"
done

"$DC" -preview=dip1000 \
  "-of=$TMP/uncertain-supervisor" \
  "$BASE/concurrency/research/m1_uncertain_supervisor.d"
timeout --signal=TERM --kill-after=2s 20s "$TMP/uncertain-supervisor"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 \
      "-of=$TMP/uncertain-supervisor-O3" \
      "$BASE/concurrency/research/m1_uncertain_supervisor.d"
    timeout --signal=TERM --kill-after=2s 20s "$TMP/uncertain-supervisor-O3"
fi
echo "P09 typed inline snapshot + supervised uncertainty: PASS"
