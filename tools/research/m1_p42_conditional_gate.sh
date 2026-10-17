#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
[[ ! -e "$POOL" ]] || { echo "P42 refuses overwrite: $POOL" >&2; exit 2; }
cleanup() { rm -f -- "$POOL"; }
trap cleanup EXIT
python3 "$ROOT/tools/research/m1_p42_make_conditional_pool.py" "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
timeout --signal=TERM --kill-after=5s 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-wait-publish
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-multi-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-multi-producer
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-close-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-close-conditional
echo "P42_CONDITIONAL_RACE_GATE_PASS compiler=$DC"
