#!/usr/bin/env bash
# M1 P28: fixed-capacity orphan manager over source-pinned REAL M0.
set -euo pipefail
ulimit -c 0
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo "P28 stale generated module" >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a || {
        echo "P28 M0 pool source drift" >&2; exit 1;
    }
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
for mode in debug release; do
    timeout --signal=TERM --kill-after=4s 160s dub run \
        --root="$BASE" --compiler="$DC" --build="$mode" \
        --config=p28-bounded >"$TMP/$mode.log" 2>&1 || {
            cat "$TMP/$mode.log" >&2; exit 1;
        }
    grep -Fx 'P28_BOUNDED_OWNER_PASS orphan_drains=6 unknown_retained=6 root_pairs=30 quota_denials=12' \
        "$TMP/$mode.log" || { cat "$TMP/$mode.log" >&2; exit 1; }
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=4s 160s dub run \
        --root="$BASE" --compiler="$DC" --build=debug \
        --config=p28-bounded-optimized >"$TMP/O3.log" 2>&1 || {
            cat "$TMP/O3.log" >&2; exit 1;
        }
    grep -Fx 'P28_BOUNDED_OWNER_PASS orphan_drains=6 unknown_retained=6 root_pairs=30 quota_denials=12' \
        "$TMP/O3.log" || { cat "$TMP/O3.log" >&2; exit 1; }
fi

# Negative application exit checks must happen BEFORE druntime teardown,
# as documented by P27's module destructor ordering counterexample.
for bad in P28ExitUnknown P28ExitOrphan; do
    dub build --root="$BASE" --compiler="$DC" --build=debug \
        --config=p28-bounded --d-version="$bad" --force \
        >"$TMP/$bad.build" 2>&1 || {
            cat "$TMP/$bad.build" >&2; exit 1;
        }
    set +e
    ( timeout --signal=TERM --kill-after=3s 25s \
        "$BASE/m1-p11-real-pool" >"$TMP/$bad.log" 2>&1 ) 2>/dev/null
    status=$?
    set -e
    if [[ "$status" != 134 ]] || \
        ! grep -Fq 'P28_APP_EXIT_UNFINISHED_FAILSTOP' "$TMP/$bad.log"; then
        cat "$TMP/$bad.log" >&2
        echo "P28 $bad unexpected native exit: $status" >&2
        exit 1
    fi
done
echo 'P28_APPLICATION_EXIT_FAILSTOP_PASS unknown=134 orphan=134'
