#!/usr/bin/env bash
# P24: process-reachable explicit GC roots around actual M0 owned records.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
[[ ! -e "$GEN" ]] || { echo "P24 stale generated source" >&2; exit 1; }
trap 'rm -f -- "$GEN"' EXIT
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = b7d8fafcb3179f00cba7e89e28c6d6b9b676353a
python3 "$ROOT/tools/research/m1_p23_make_owned.py" "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
for build in debug release; do
    result="$(timeout 160s dub run --root="$BASE" --compiler="$DC" --build="$build" --config=p24-root-registry)"
    printf '%s\n' "$result"
    grep -Fq 'P24_DURABLE_ROOT_PASS normal=6 uncertain=6 independent=4 roots=20 removed=20' <<< "$result"
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    result="$(timeout 160s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p24-root-registry-optimized)"
    printf '%s\n' "$result"
    grep -Fq 'P24_DURABLE_ROOT_PASS normal=6 uncertain=6 independent=4 roots=20 removed=20' <<< "$result"
fi
