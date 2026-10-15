#!/usr/bin/env bash
# P19 actual unchanged M0 OwnedTaskExecutor retention and result lifetime.
# Correctness only, NOT a native GC-root soundness proof or speed comparison.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
"$DC" --version
dub --version

for mode in debug release; do
    timeout --signal=TERM --kill-after=5s 160s \
        dub run --root="$BASE" --compiler="$DC" \
        --build="$mode" --config=owned-graph \
        >"$TMP/$mode.log" 2>&1 || {
            cat "$TMP/$mode.log" >&2
            exit 1
        }
    grep -Fx 'P19_REAL_OWNED_GC_PASS queued=8 graphs=3 gc=4 result_after_reap=1' \
        "$TMP/$mode.log" || {
            cat "$TMP/$mode.log" >&2
            echo "FAIL P19: $mode witness missing" >&2
            exit 1
        }
    echo "P19 real M0 owned graph $mode: PASS"
done

# The independently owned class does not currently prove arbitrary F safe.
if timeout --signal=TERM --kill-after=5s 160s \
    dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=owned-negative-safe >"$TMP/negative.log" 2>&1; then
    echo "FAIL P19: @safe consumer unexpectedly compiled" >&2
    exit 1
fi
if ! grep -Eiq 'OwnedTaskExecutor|submit' "$TMP/negative.log" ||
   ! grep -Eiq '@safe|@system' "$TMP/negative.log"; then
    cat "$TMP/negative.log" >&2
    echo "FAIL P19: unrelated compile-negative error" >&2
    exit 1
fi
echo "P19 @safe general owned submit: expected rejection"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=5s 160s \
        dub run --root="$BASE" --compiler="$DC" \
        --build=debug --config=owned-graph-optimized \
        >"$TMP/optimized.log" 2>&1 || {
            cat "$TMP/optimized.log" >&2
            exit 1
        }
    grep -Fx 'P19_REAL_OWNED_GC_PASS queued=8 graphs=3 gc=4 result_after_reap=1' \
        "$TMP/optimized.log" || {
            cat "$TMP/optimized.log" >&2
            exit 1
        }
    echo "P19 real M0 owned graph LDC -O3: PASS"
fi
