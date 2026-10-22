#!/usr/bin/env bash
# M1 P21: source-pinned, standalone D model for native shutdown obligations.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/research/m1_task_lifetime/prototypes/p21_shutdown_contract/concurrency/research/m1_p21_shutdown_contract.d"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a || {
        echo "P21 M0 pool source changed: re-audit required" >&2
        exit 1
    }
test "$(git -C "$ROOT" hash-object source/concurrency/internal/owned_task.d)" = \
    e74d6a73f956c562eab176e27687a47249f5815d || {
        echo "P21 M0 owned source changed: re-audit required" >&2
        exit 1
    }
"$DC" --version
for config in debug release; do
    extra=()
    if [[ "$config" == release ]]; then extra=(-release); fi
    "$DC" -preview=dip1000 "${extra[@]}" \
        "-of=$TMP/model-$config" "$SOURCE"
    timeout --signal=TERM --kill-after=3s 30s "$TMP/model-$config" \
        >"$TMP/$config.out"
    grep -Eq '^P21_SHUTDOWN_CONTRACT_PASS states=[0-9]+ edges=[0-9]+ rejects=[0-9]+$' \
        "$TMP/$config.out"
    cat "$TMP/$config.out"
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "-of=$TMP/model-O3" "$SOURCE"
    timeout --signal=TERM --kill-after=3s 30s "$TMP/model-O3" \
        >"$TMP/O3.out"
    grep -Eq '^P21_SHUTDOWN_CONTRACT_PASS states=[0-9]+ edges=[0-9]+ rejects=[0-9]+$' \
        "$TMP/O3.out"
    cat "$TMP/O3.out"
fi
