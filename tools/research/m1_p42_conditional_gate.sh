#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
POOL="$BASE/concurrency/research/m1_p42_pool.d"
OBSERVED_BASELINE="$BASE/concurrency/research/m1_p42_baseline_pool.d"
FLOW_CONDITIONAL="$BASE/concurrency/research/m1_p42_flow_pool.d"
FLOW_BASELINE="$BASE/concurrency/research/m1_p42_flow_baseline_pool.d"
for path in "$POOL" "$OBSERVED_BASELINE" "$FLOW_CONDITIONAL" "$FLOW_BASELINE"; do
    [[ ! -e "$path" ]] || { echo "P42 refuses overwrite: $path" >&2; exit 2; }
done
cleanup() { rm -f -- "$POOL" "$OBSERVED_BASELINE" "$FLOW_CONDITIONAL" "$FLOW_BASELINE"; }
trap cleanup EXIT
GEN="$ROOT/tools/research/m1_p42_make_conditional_pool.py"
SOURCE="$ROOT/source/concurrency/internal/submission_pool.d"
python3 -m py_compile "$GEN" "$ROOT/tools/research/m1_p42_multi_idle_extract.py" \
    "$ROOT/tools/research/m1_p42_flow_extract.py" \
    "$ROOT/tools/research/m1_p42_e2e_analyze.py" \
    "$ROOT/tools/research/m1_p42_thermal_guard.py"
bash -n "$ROOT/tools/research/m1_p42_multi_idle_native.sh"
bash -n "$ROOT/tools/research/m1_p42_flow_native.sh"
bash -n "$ROOT/tools/research/m1_p42_e2e_native.sh"
bash -n "$ROOT/tools/research/m1_p42_cool_replication_native.sh"
python3 "$ROOT/tools/research/m1_p42_multi_idle_extract.py" --self-test
python3 "$ROOT/tools/research/m1_p42_flow_extract.py" --self-test
python3 "$ROOT/tools/research/m1_p42_e2e_analyze.py" --self-test
python3 "$ROOT/tools/research/m1_p42_thermal_guard.py" --self-test
python3 "$GEN" "$SOURCE" "$POOL" conditional
python3 "$GEN" "$SOURCE" "$OBSERVED_BASELINE" baseline
python3 "$GEN" "$SOURCE" "$FLOW_CONDITIONAL" flow-conditional
python3 "$GEN" "$SOURCE" "$FLOW_BASELINE" flow-baseline
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
# P42.17 opt-in flow overlays must be identical except the publication policy.
# In particular, no asymmetric wait-return instrumentation is permitted.
python3 - "$FLOW_CONDITIONAL" "$FLOW_BASELINE" <<'PY'
from pathlib import Path
import sys
cond, base = (Path(x).read_text() for x in sys.argv[1:])
cond = cond.replace("module concurrency.research.m1_p42_flow_pool;",
                    "module concurrency.research.p42_matched_flow;")
base = base.replace("module concurrency.research.m1_p42_flow_baseline_pool;",
                    "module concurrency.research.p42_matched_flow;")
def normalize(text):
    begin = "// P42_FLOW_POLICY_BEGIN"
    end = "// P42_FLOW_POLICY_END"
    assert text.count(begin) == 1 and text.count(end) == 1
    before, rest = text.split(begin)
    _, after = rest.split(end)
    return before + "P42_POLICY" + after
assert normalize(cond) == normalize(base), (
    "P42.17 flow overlays differ outside the intended notify policy")
print("P42_MATCHED_FLOW_PREFLIGHT_PASS")
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
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-flow-baseline
timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug --config=p42-flow-conditional
# All preceding P42.16/P42.17 consumers needed the *observed* overlay.
# P42.18 must instead compile the minimally instrumented historical
# two-argument legacy overlay, exactly as the native E2E runner does.
# This file is our own temporary generator output; the initial guard
# guaranteed it did not pre-exist, and the exit trap still owns cleanup.
rm -f -- "$POOL"
python3 "$GEN" "$SOURCE" "$POOL"
if grep -q -e 'P42FlowSnapshot' -e '_p42WorkerIndex' "$POOL"; then
    echo "P42.18 unexpectedly compiled observed diagnostics" >&2
    exit 3
fi
# Same pre-existing P42 consumer in both arms; debug tests only.
for cost in light medium; do
    for arm in baseline conditional; do
        timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config="p42-e2e-$arm-$cost" -- 4 4 256
        timeout 90s dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config="p42-e2e-$arm-$cost" -- 1 1 256
    done
done
echo "P42_CONDITIONAL_RACE_GATE_PASS compiler=$DC"
