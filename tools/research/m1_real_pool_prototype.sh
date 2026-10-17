#!/usr/bin/env bash
# M1 P11: real M0 SubmissionWorkerPool + containers-d work stealing.
# Standalone DUB research consumer — no production source mutation.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
command -v "$DC" >/dev/null 2>&1
command -v dub >/dev/null 2>&1

"$DC" --version
dub --version

# Uses the real root concurrency-d package and its pinned containers-d 0.2.0
# dependency, not a local replacement deque or changed M0 source.
timeout --signal=TERM --kill-after=5s 160s \
    dub run --root="$BASE" --compiler="$DC" --build=debug --config=positive

# Each consumer is compiled through the SAME native DUB dependency graph
# (real concurrency-d + containers-d), without linker-failure-based negatives.
for scenario in negative-safe negative-borrow negative-delegate; do
    LOG="$(mktemp)"
    if timeout --signal=TERM --kill-after=5s 160s \
        dub build --root="$BASE" --compiler="$DC" --build=debug \
            --config="$scenario" >"$LOG" 2>&1; then
        cat "$LOG" >&2
        rm -f -- "$LOG"
        echo "FAIL: P11 $scenario unexpectedly compiled" >&2
        exit 1
    fi

    if ! grep -Eq 'evaluateWithRealPool|isInlineTransfer' "$LOG"; then
        cat "$LOG" >&2
        rm -f -- "$LOG"
        echo "FAIL: P11 $scenario failed for an unrelated reason" >&2
        exit 1
    fi
    if [[ "$scenario" == negative-safe ]] && \
        ! grep -Eq '@safe|@system' "$LOG"; then
        cat "$LOG" >&2
        rm -f -- "$LOG"
        echo "FAIL: P11 negative-safe lacks a safety diagnostic" >&2
        exit 1
    fi

    echo "P11 expected P11 API rejection: $scenario"
    grep -E 'Error:|error:' "$LOG" | head -8
    rm -f -- "$LOG"
done

# Exercise actual copy-vs-owned-result parity in WHOLE release mode.
# The original consumer hid TaskHandle.get() inside assert(), which would
# silently remove the observation. Keep all admission and join checks live.
LOG="$(mktemp)"
if ! timeout --signal=TERM --kill-after=5s 160s \
    dub run --root="$BASE" --compiler="$DC" --build=release \
        --config=positive >"$LOG" 2>&1; then
    cat "$LOG" >&2
    rm -f -- "$LOG"
    exit 1
fi
if ! grep -q '^P11 real M0 work stealing: PASS' "$LOG"; then
    cat "$LOG" >&2
    rm -f -- "$LOG"
    echo "FAIL: P11 release output marker missing" >&2
    exit 1
fi
cat "$LOG"
rm -f -- "$LOG"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    # The opt-in research configuration injects -O3 into a debug build:
    # compiler assertions remain enabled, unlike ordinary release mode.
    timeout --signal=TERM --kill-after=5s 160s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config=optimized
    echo "P11 LDC -O3 research configuration (assertions-on): PASS"
fi

echo "P11 unchanged M0 submission pool DUB integration: PASS"
