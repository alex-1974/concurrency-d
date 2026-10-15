#!/usr/bin/env bash
# P27: real M0 overlapped lifetime transitions and process exit policy.
set -euo pipefail
ulimit -c 0
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo 'P27 generated source already exists' >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a || {
        echo 'P27 M0 pool changed: re-audit required' >&2; exit 1;
    }
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"

for build in debug release; do
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config=p27-transitions >"$TMP/$build.log" 2>&1 || {
            cat "$TMP/$build.log" >&2; exit 1;
        }
    grep -Fx 'P27_LIFECYCLE_RACES_PASS producer_close=12 start_close=12 never_started=12' \
        "$TMP/$build.log" || { cat "$TMP/$build.log" >&2; exit 1; }
done

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=p27-transitions-optimized >"$TMP/O3.log" 2>&1 || {
            cat "$TMP/O3.log" >&2; exit 1;
        }
    grep -Fx 'P27_LIFECYCLE_RACES_PASS producer_close=12 start_close=12 never_started=12' \
        "$TMP/O3.log" || { cat "$TMP/O3.log" >&2; exit 1; }
fi

# Explicitly test genuine module teardown, not an application-invoked
# stand-in for a destructor. DUB masks SIGABRT; run the built binary.
for variant in P27ExitActive P27ExitUnstarted; do
    dub build --root="$BASE" --compiler="$DC" --build=debug \
        --config=p27-transitions --d-version="$variant" --force \
        >"$TMP/$variant.build" 2>&1 || {
            cat "$TMP/$variant.build" >&2; exit 1;
        }
    set +e
    ( timeout --signal=TERM --kill-after=4s 40s \
        "$BASE/m1-p11-real-pool" >"$TMP/$variant.log" 2>&1 ) 2>/dev/null
    status=$?
    set -e
    if [[ "$status" != 134 ]] || \
        ! grep -Fq 'P27_PROCESS_EXIT_FAILSTOP' "$TMP/$variant.log"; then
        cat "$TMP/$variant.log" >&2
        echo "P27 $variant missing module destructor abort: $status" >&2
        exit 1
    fi
done
echo 'P27_PROCESS_EXIT_FAILSTOP_PASS active=134 unstarted=134'
