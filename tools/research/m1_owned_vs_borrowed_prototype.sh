#!/usr/bin/env bash
# M1 P08: owned-vs-borrowed lifetime research, NOT production ownership proof.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/research/m1_task_lifetime/prototypes/p08_owned_vs_borrowed/concurrency/research/m1_owned_uncertainty.d"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1 || exit 2

# Read-only structural checks of the ACTUAL repository-owned M0 implementation,
# not a claim that the P08 minimal worker is semantically the same scheduler.
python3 - "$ROOT/source/concurrency/internal/owned_task.d" \
    "$ROOT/source/concurrency/internal/submission_pool.d" <<'PY'
from pathlib import Path
import sys
owned = Path(sys.argv[1]).read_text()
pool = Path(sys.argv[2]).read_text()
expected = {
    "OwnedTaskExecutor accepts arbitrary @system callable":
        "auto trySubmit(F)(F callable) @system" in owned,
    "TaskHandle retains the result cell only":
        "private ResultCell!R _cell;" in owned,
    "Executor retains owned task nodes":
        "private RetainedTask[] _retained;" in owned
        and "Object node;" in owned,
    "Executor retains nodes when shutdown has failed":
        "if (failure is null)" in owned
        and "foreach (ref entry; _retained)" in owned,
    "Executor marks stopped after failed shutdown too":
        "_shutdownFailure = failure;" in owned
        and "_lifecycle = Lifecycle.stopped;" in owned,
    "Pool raw task transport does not own submitted record":
        "Keep every admitted record alive until closeAndJoin completes" in pool,
    "Pool uses default throwing worker joins":
        "_workers[index].join();" in pool,
}
for name, ok in expected.items():
    if not ok:
        raise SystemExit(f"FAIL: P08 source contract changed; re-audit: {name}")
    print(f"P08 source audit: {name}: CONFIRMED")
PY

"$DC" --version
"$DC" -preview=dip1000 "-of=$TMP/m1-p08-owned-value" "$SRC"
timeout --signal=TERM --kill-after=2s 20s "$TMP/m1-p08-owned-value"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    "$DC" -O3 -preview=dip1000 "-of=$TMP/m1-p08-owned-value-O3" "$SRC"
    timeout --signal=TERM --kill-after=2s 20s "$TMP/m1-p08-owned-value-O3"
fi
echo "P08 owned-value isolation research: PASS"
