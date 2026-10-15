#!/usr/bin/env bash
# P25: matched real M0 owned-task correctness: lexical token vs registry.
set -euo pipefail
ulimit -c 0
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo "P25 generated copy already exists" >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = b7d8fafcb3179f00cba7e89e28c6d6b9b676353a
python3 "$ROOT/tools/research/m1_p23_make_owned.py" "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"

for build in debug release; do
    timeout --signal=TERM --kill-after=4s 160s dub run --root="$BASE" --compiler="$DC" --build="$build" --config=p25-owner-modes > "$TMP/$build.log" 2>&1 || {
        cat "$TMP/$build.log" >&2; exit 1;
    }
    grep -Fx 'P25_OWNER_MODES_PASS token=12 registry=12 normal=12 uncertain=12' "$TMP/$build.log" || {
        cat "$TMP/$build.log" >&2; exit 1;
    }
done

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=4s 160s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p25-owner-modes-optimized > "$TMP/O3.log" 2>&1 || {
        cat "$TMP/O3.log" >&2; exit 1;
    }
    grep -Fx 'P25_OWNER_MODES_PASS token=12 registry=12 normal=12 uncertain=12' "$TMP/O3.log" || {
        cat "$TMP/O3.log" >&2; exit 1;
    }
fi

# DUB's documented --d-version sets the research negative branch.
# It translates the correct compiler option for each pinned compiler.
if timeout 60s dub build --root="$BASE" --compiler="$DC" --build=debug --config=p25-owner-modes --d-version=P25NegativeCopy >"$TMP/negative.log" 2>&1; then
    echo "P25 ERROR token unexpectedly copyable" >&2; exit 1
fi
grep -Eq 'copy|postblit|this\(this\)|disabled' "$TMP/negative.log" || {
    cat "$TMP/negative.log" >&2; echo "P25 wrong negative failure" >&2; exit 1;
}

# Build via DUB but execute the resulting binary DIRECTLY.
# DUB wraps a child SIGABRT as its own exit code 2, masking exit 134.
dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=p25-owner-modes --d-version=P25DropFault --force \
    >"$TMP/drop-build.log" 2>&1 || {
        cat "$TMP/drop-build.log" >&2; exit 1;
    }
set +e
( timeout --signal=TERM --kill-after=4s 60s \
    "$BASE/m1-p11-real-pool" >"$TMP/drop.log" 2>&1 ) 2>/dev/null
drop_status=$?
set -e
if [[ "$drop_status" != 134 ]] || ! grep -Fq 'P25_TOKEN_DROP_FAILSTOP' "$TMP/drop.log"; then
    cat "$TMP/drop.log" >&2
    echo "P25 incorrect drop-fault result: $drop_status" >&2
    exit 1
fi
echo "P25_SCOPE_FAILSTOP_PASS disabled_copy=1 exit=134"
