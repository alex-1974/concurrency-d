#!/usr/bin/env bash
# P26: source-pinned P25 ownership boundaries and real native M0 lifecycle.
set -euo pipefail
ulimit -c 0
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$GEN"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$GEN" ]] || { echo "P26 generated source already exists" >&2; exit 1; }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"

for build in debug release; do
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build="$build" \
        --config=p25-owner-modes --d-version=P26Positive \
        >"$TMP/$build.log" 2>&1 || {
            cat "$TMP/$build.log" >&2; exit 1;
        }
    grep -Fx 'P26_OWNERSHIP_SAFETY_PASS moved=12 unwind=12 races=12' \
        "$TMP/$build.log" || { cat "$TMP/$build.log" >&2; exit 1; }
    grep -Fx 'P25_OWNER_MODES_PASS token=12 registry=12 normal=12 uncertain=12' \
        "$TMP/$build.log" >/dev/null || { cat "$TMP/$build.log" >&2; exit 1; }
done

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=4s 160s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=p25-owner-modes-optimized --d-version=P26Positive \
        >"$TMP/optimized.log" 2>&1 || {
            cat "$TMP/optimized.log" >&2; exit 1;
        }
    grep -Fx 'P26_OWNERSHIP_SAFETY_PASS moved=12 unwind=12 races=12' \
        "$TMP/optimized.log" || { cat "$TMP/optimized.log" >&2; exit 1; }
fi

# Prohibited ref-param lvalue return: not a legal move from a local.
if timeout 60s dub build --root="$BASE" --compiler="$DC" \
    --build=debug --config=p25-owner-modes --d-version=P26ReturnCopy \
    --force >"$TMP/return-copy.log" 2>&1; then
    echo "P26: unexpected token copy across ref-return" >&2; exit 1
fi
grep -Eiq 'copy|postblit|disabled|this\(this\)' "$TMP/return-copy.log" || {
    cat "$TMP/return-copy.log" >&2
    echo "P26 wrong compile-negative cause" >&2; exit 1
}

# A thrown exception that causes the lexical token to unwind while
# workers may still run MUST fail-stop. Execute native binary, not DUB
# (DUB replaces SIGABRT with a wrapped exit status).
dub build --root="$BASE" --compiler="$DC" --build=debug \
    --config=p25-owner-modes --d-version=P26UnwindFault --force \
    >"$TMP/unwind-build.log" 2>&1 || {
        cat "$TMP/unwind-build.log" >&2; exit 1
    }
set +e
( timeout --signal=TERM --kill-after=4s 60s \
    "$BASE/m1-p11-real-pool" >"$TMP/unwind.log" 2>&1 ) 2>/dev/null
status=$?
set -e
if [[ "$status" != 134 ]] || \
    ! grep -Fq 'P26_INJECTED_UNWIND' "$TMP/unwind.log" || \
    ! grep -Fq 'P25_TOKEN_DROP_FAILSTOP' "$TMP/unwind.log"; then
    cat "$TMP/unwind.log" >&2
    echo "P26 improper exceptional-unwind fail-stop: $status" >&2
    exit 1
fi
echo 'P26_EXCEPTION_UNWIND_FAILSTOP_PASS copy_rejected=1 exit=134'
