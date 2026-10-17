#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/research/m1_task_lifetime/prototypes/p41_deterministic_protocol/p41_condition_runtime.d"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
python3 "$ROOT/tools/research/m1_p41_protocol_model.py" "$ROOT/source/concurrency/internal/submission_pool.d"
python3 "$ROOT/tools/research/m1_p41_ordered_scenarios.py"
"$DC" -of="$TMP/p41-condition" "$SRC"
timeout --signal=TERM --kill-after=5s 30s "$TMP/p41-condition"
echo "P41_NATIVE_GATE_PASS compiler=$DC"
