#!/usr/bin/env bash
# P07 research: qualified tags/native source audit + simulated exceptional
# start/join returns. Never induce undefined pthread_join on a live worker.
set -euo pipefail
ulimit -c 0 || true

DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p04_value_only"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

V="-version="
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    V="-d-version="
fi

"$DC" --version
SRC=(
    "$ROOT/source/concurrency/internal/task_record.d"
    "$BASE/concurrency/research/m1_value_scope.d"
)

# Nonfaulted binary with the alternate fail-stop policy enabled must still
# be callable by the real @safe consumer, with normal observable results.
"$DC" "${V}M1P07FailStop" -preview=dip1000 \
    "-I$ROOT/source" "-I$BASE" "-of=$TMP/p07-normal" \
    "${SRC[@]}" "$BASE/consumer/positive_safe_consumer.d"
"$TMP/p07-normal"
echo "P07 fail-stop variant normal external consumer: PASS"

for variant in M1P07StartFault M1P07JoinFault; do
    name="P07_FAILSTOP_START"
    if [[ "$variant" == M1P07JoinFault ]]; then
        name="P07_FAILSTOP_JOIN"
    fi

    "$DC" -unittest -main "${V}M1P07FailStop" "${V}$variant" \
        -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
        "-of=$TMP/$variant" "${SRC[@]}"

    set +e
    ( timeout --signal=TERM --kill-after=2s 15s "$TMP/$variant" ) \
        >"$TMP/$variant.log" 2>&1
    status=$?
    set -e
    if [[ "$status" -ne 134 ]] || ! grep -Fq "$name" "$TMP/$variant.log"; then
        echo "FAIL: $variant expected SIGABRT(134) and marker $name; got $status" >&2
        cat "$TMP/$variant.log" >&2
        exit 1
    fi
    echo "P07 $variant: PASS (simulated uncertain native return -> fail-stop SIGABRT)"
done

# The optimized LDC path keeps assertions enabled and repeats both
# fail-stop signals, rather than merely compiling an optimized binary.
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    for variant in M1P07StartFault M1P07JoinFault; do
        name="P07_FAILSTOP_START"
        if [[ "$variant" == M1P07JoinFault ]]; then
            name="P07_FAILSTOP_JOIN"
        fi

        "$DC" -O3 -unittest -main "${V}M1P07FailStop" "${V}$variant" \
            -preview=dip1000 "-I$ROOT/source" "-I$BASE" \
            "-of=$TMP/$variant-O3" "${SRC[@]}"
        set +e
        ( timeout --signal=TERM --kill-after=2s 15s "$TMP/$variant-O3" ) \
            >"$TMP/$variant-O3.log" 2>&1
        status=$?
        set -e
        if [[ "$status" -ne 134 ]] || ! grep -Fq "$name" "$TMP/$variant-O3.log"; then
            echo "FAIL: LDC -O3 $variant expected SIGABRT(134) and marker $name; got $status" >&2
            cat "$TMP/$variant-O3.log" >&2
            exit 1
        fi
        echo "P07 $variant LDC -O3 assertions-on: PASS (fail-stop SIGABRT)"
    done
fi

echo "P07 fail-stop research gate PASS (no native join corruption invoked)"
