#!/usr/bin/env bash
# P23: compiler and runtime contract gate; research only.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
python3 "$ROOT/tools/research/m1_p23_make_owned.py" "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"
for build in debug release; do
    timeout 160s dub run --root="$BASE" --compiler="$DC" --build="$build" --config=p23-lifecycle
done
