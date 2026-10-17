#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
OBSERVED_BASELINE="$BASE/concurrency/research/m1_p42_baseline_pool.d"
for path in "$POOL" "$OBSERVED_BASELINE"; do
    [[ ! -e "$path" ]] || { echo "P42 refuses overwrite: $path" >&2; exit 2; }
done
cleanup() { rm -f -- "$POOL" "$OBSERVED_BASELINE"; }
trap cleanup EXIT
GEN="$ROOT/tools/research/m1_p42_make_conditional_pool.py"
SOURCE="$ROOT/source/concurrency/internal/submission_pool.d"
python3 -m py_compile "$GEN" "$ROOT/tools/research/m1_p42_multi_idle_extract.py"
bash -n "$ROOT/tools/research/m1_p42_multi_idle_native.sh"
python3 "$GEN" "$SOURCE" "$POOL" conditional
python3 "$GEN" "$SOURCE" "$OBSERVED_BASELINE" baseline
# Reject any drift beyond the intended publish-notify policy and module name.
python3 - "$POOL" "$OBSERVED_BASELINE" <<'PY'
from pathlib import Path
import sys
cond, base = (Path(x).read_text() for x in sys.argv[1:])
cond = cond.replace("module concurrency.research.m1_p42_pool;",
                    "module concurrency.research.p42_matched;")
base = base.replace("module concurrency.research.m1_p42_baseline_pool;",
                    "module concurrency.research.p42_matched;")
cnotify = """// P42 conditional hypothesis; guarded by the inbox mutex.
            if (_waiters != 0)
                _changed.notify();"""
bnotify = """// P42 baseline: retain unconditional publication notification.
            _changed.notify();"""
assert cond.count(cnotify) == 1 and base.count(bnotify) == 1, (
    "P42 publish policy anchor mismatch")
assert cond.replace(cnotify, "P42_POLICY") == base.replace(bnotify, "P42_POLICY"), (
    "P42 observed overlays differ outside the intended notify policy")
print("P42_MATCHED_OBSERVATION_PREFLIGHT_PASS")
PY
timeout --signal=TERM --kill-after=5s 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-wait-publish
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-multi-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-multi-producer
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-close-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-close-conditional
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-bench-baseline-medium -- 4 4 256
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-bench-conditional-medium -- 4 4 256
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-idle-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-idle-conditional
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-multi-idle-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-multi-idle-conditional
echo "P42_CONDITIONAL_RACE_GATE_PASS compiler=$DC"
