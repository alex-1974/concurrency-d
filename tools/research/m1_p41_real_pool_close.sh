#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p38_pool.d"
if [[ -e "$POOL" ]]; then echo "P41 refuses existing: $POOL" >&2; exit 2; fi
cleanup() { rm -f -- "$POOL"; }
trap cleanup EXIT
python3 "$ROOT/tools/research/m1_p38_source_audit.py"
python3 "$ROOT/tools/research/m1_p38_make_pool.py" "$ROOT" \
 "$ROOT/source/concurrency/internal/submission_pool.d" "$POOL"
timeout --signal=TERM --kill-after=5s 90s dub run --root="$BASE" \
 --compiler="$DC" --build=debug --config=p41-real-pool-close
echo "P41_REAL_POOL_GATE_PASS compiler=$DC"
