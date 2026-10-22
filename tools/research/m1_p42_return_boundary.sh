#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
[[ ! -e "$POOL" ]] || { echo "P42.20 refuses existing overlay: $POOL" >&2; exit 2; }
trap 'rm -f -- "$POOL"' EXIT
python3 "$ROOT/tools/research/m1_p42_make_conditional_pool.py" \
    "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
# Debug retains assertions. Optimized correctness additionally uses LDC -O3.
for arm in baseline conditional; do
    timeout --signal=TERM --kill-after=5s 90s dub run --root="$BASE" \
        --compiler="$DC" --build=debug --config="p42-return-$arm"
done
if [[ "$(basename "$DC")" == ldc* ]]; then
    for arm in baseline conditional; do
        timeout --signal=TERM --kill-after=5s 90s dub run --root="$BASE" \
            --compiler="$DC" --build=debug --config="p42-return-$arm-optimized" --force
    done
fi
