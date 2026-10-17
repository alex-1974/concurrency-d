#!/usr/bin/env bash
# P29: generational owner identity, ABA rejection and uncertain quota.
set -euo pipefail
ulimit -c 0
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo "P29 stale generated source" >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a || {
        echo "P29 original native M0 source drift" >&2; exit 1;
    }
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
for build in debug release; do
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config=p29-generational >"$TMP/$build.log" 2>&1 || {
            cat "$TMP/$build.log" >&2; exit 1;
        }
    grep -Fx 'P29_GENERATIONAL_OWNER_PASS aba=8 contention=8 unknown_quota=8' \
        "$TMP/$build.log" || { cat "$TMP/$build.log" >&2; exit 1; }
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=p29-generational-optimized >"$TMP/O3.log" 2>&1 || {
            cat "$TMP/O3.log" >&2; exit 1;
        }
    grep -Fx 'P29_GENERATIONAL_OWNER_PASS aba=8 contention=8 unknown_quota=8' \
        "$TMP/O3.log" || { cat "$TMP/O3.log" >&2; exit 1; }
fi

# Fatal policy is checked in a separate NATIVE subprocess.
dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=p29-generational --d-version=P29ExitUnknown --force \
    >"$TMP/unknown-build.log" 2>&1 || {
        cat "$TMP/unknown-build.log" >&2; exit 1;
    }
set +e
( timeout --signal=TERM --kill-after=4s 25s \
    "$BASE/m1-p11-real-pool" >"$TMP/unknown.log" 2>&1 ) 2>/dev/null
exit_status=$?
set -e
if [[ "$exit_status" != 134 ]] || \
    ! grep -Fq 'P29_UNFINISHED_OWNER_FAILSTOP' "$TMP/unknown.log"; then
    cat "$TMP/unknown.log" >&2
    echo "P29 unknown-exit fail-stop missing: $exit_status" >&2
    exit 1
fi
echo 'P29_UNKNOWN_OWNER_FAILSTOP_PASS exit=134'
