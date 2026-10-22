#!/usr/bin/env bash
# P22 research: real druntime Threads, separate strong owner, 3-way close.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/research/m1_task_lifetime/prototypes/p22_native_supervisor/concurrency/research/m1_p22_native_supervisor.d"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a || {
        echo "P22 M0 pool drift: re-audit required" >&2
        exit 1
    }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/owned_task.d)" = \
    e74d6a73f956c562eab176e27687a47249f5815d || {
        echo "P22 M0 owned-task drift: re-audit required" >&2
        exit 1
    }
"$DC" --version
for mode in debug release; do
    flags=()
    if [[ "$mode" == release ]]; then flags=(-release); fi
    "$DC" -preview=dip1000 "${flags[@]}" \
        "-of=$TMP/p22-$mode" "$SOURCE"
    timeout --signal=TERM --kill-after=3s 35s "$TMP/p22-$mode" \
        >"$TMP/$mode.log"
    grep -Fx 'P22_NATIVE_SUPERVISOR_PASS normal=12 prejoin=12 postlaunch=8' \
        "$TMP/$mode.log"
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "-of=$TMP/p22-O3" "$SOURCE"
    timeout --signal=TERM --kill-after=3s 35s "$TMP/p22-O3" \
        >"$TMP/O3.log"
    grep -Fx 'P22_NATIVE_SUPERVISOR_PASS normal=12 prejoin=12 postlaunch=8' \
        "$TMP/O3.log"
fi
