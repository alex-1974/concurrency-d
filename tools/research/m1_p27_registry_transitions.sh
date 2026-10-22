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

# Negative A: explicit application boundary, while a real worker exists.
# D runtime may wait BEFORE the shared module destructor: a module-only
# destructor cannot reliably establish this fail-stop policy.
dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=p27-transitions --d-version=P27ExitActive --force \
    >"$TMP/P27ExitActive.build" 2>&1 || {
        cat "$TMP/P27ExitActive.build" >&2; exit 1;
    }
set +e
( timeout --signal=TERM --kill-after=3s 15s \
    "$BASE/m1-p11-real-pool" >"$TMP/P27ExitActive.log" 2>&1 ) 2>/dev/null
active_status=$?
set -e
if [[ "$active_status" != 134 ]] || \
    ! grep -Fq 'P27_APPLICATION_EXIT_FAILSTOP' "$TMP/P27ExitActive.log"; then
    cat "$TMP/P27ExitActive.log" >&2
    echo "P27 missing explicit application-exit fail-stop: $active_status" >&2
    exit 1
fi

# Negative B: no native worker has started, so the native D module
# destructor CAN inspect and reject an uncleared explicit GC root.
dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=p27-transitions --d-version=P27ExitUnstarted --force \
    >"$TMP/P27ExitUnstarted.build" 2>&1 || {
        cat "$TMP/P27ExitUnstarted.build" >&2; exit 1;
    }
set +e
( timeout --signal=TERM --kill-after=3s 15s \
    "$BASE/m1-p11-real-pool" >"$TMP/P27ExitUnstarted.log" 2>&1 ) 2>/dev/null
unstarted_status=$?
set -e
if [[ "$unstarted_status" != 134 ]] || \
    ! grep -Fq 'P27_PROCESS_EXIT_FAILSTOP' "$TMP/P27ExitUnstarted.log"; then
    cat "$TMP/P27ExitUnstarted.log" >&2
    echo "P27 missing never-started module fail-stop: $unstarted_status" >&2
    exit 1
fi

# Controlled DIAGNOSTIC reproducing the native druntime startup/shutdown
# limitation discovered on both pinned compilers. It must not silently
# count as a successful process shutdown.
dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=p27-transitions --d-version=P27RuntimeOnly --force \
    >"$TMP/P27RuntimeOnly.build" 2>&1 || {
        cat "$TMP/P27RuntimeOnly.build" >&2; exit 1;
    }
set +e
( timeout --signal=TERM --kill-after=3s 5s \
    "$BASE/m1-p11-real-pool" >"$TMP/P27RuntimeOnly.log" 2>&1 ) 2>/dev/null
runtime_status=$?
set -e
if [[ "$runtime_status" == 124 ]] && \
    ! grep -Fq 'P27_PROCESS_EXIT_FAILSTOP' "$TMP/P27RuntimeOnly.log"; then
    echo "P27_RUNTIME_ONLY_BLOCKED_DIAGNOSTIC_PASS timed_out=124"
elif [[ "$runtime_status" == 134 ]] && \
    grep -Fq 'P27_PROCESS_EXIT_FAILSTOP' "$TMP/P27RuntimeOnly.log"; then
    echo "P27_RUNTIME_ONLY_DESTRUCTOR_REACHED_PASS exit=134"
else
    cat "$TMP/P27RuntimeOnly.log" >&2
    echo "P27 runtime-only unexpected outcome: $runtime_status" >&2
    exit 1
fi
echo 'P27_EXPLICIT_EXIT_FAILSTOP_PASS active=134 unstarted=134'
