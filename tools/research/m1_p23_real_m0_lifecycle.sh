#!/usr/bin/env bash
# P23: compiler and runtime contract gate; research only.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
[[ ! -e "$GEN" ]] || { echo "P23 generated file already exists" >&2; exit 1; }
trap 'rm -f -- "$GEN"' EXIT
python3 "$ROOT/tools/research/m1_p23_make_owned.py" "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
for build in debug release; do
    output="$(timeout 160s dub run --root="$BASE" --compiler="$DC" --build="$build" --config=p23-lifecycle)"
    printf '%s\n' "$output"
    grep -Fq 'P23_REAL_M0_LIFECYCLE_PASS normal=6 prejoin=6 poststart=6 producer=6' <<< "$output"
done
if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    output="$(timeout 160s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p23-lifecycle-optimized)"
    printf '%s\n' "$output"
    grep -Fq 'P23_REAL_M0_LIFECYCLE_PASS normal=6 prejoin=6 poststart=6 producer=6' <<< "$output"
fi
