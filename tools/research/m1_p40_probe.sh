#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
bash "$ROOT/tools/research/m1_p39_probe.sh"
python3 "$ROOT/tools/research/m1_p40_make_pool.py" "$ROOT" \
 "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/m1_p40_pool.d"
python3 - "$TMP/m1_p40_pool.d" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
for token in ("postLocal","postInbox","postSteal","postRepark","postDrained"):
    if s.count("++p38ThreadCounters."+token+";")!=1:
        raise ValueError("P40 outcome counter missing: "+token)
if s.count("p40Pending = true;")!=1:
    raise ValueError("P40 pending arm drift")
if s.count("const p40Delta = p38ThreadCounters.waitReturns - p40Before;")!=1:
    raise ValueError("P40 wait-return delta drift")
if s.count("p38ThreadCounters.postRepark += p40Delta - 1;")!=1:
    raise ValueError("P40 internal re-wait attribution drift")
# Deterministic arithmetic regression: one park invocation may contain
# multiple Condition.wait returns, but only one returns to worker-loop search.
for delta in (0,1,2,3,17):
    internal = max(delta-1, 0)
    pending = 1 if delta else 0
    assert internal + pending == delta
print("P40_OUTCOME_PREFLIGHT_PASS source_only=true compiler_untested=true")
PY

python3 - "$ROOT/tools/research/m1_p40_xps.sh" <<'PY'
from pathlib import Path
import sys
script=Path(sys.argv[1]).read_text()
for arm in ("null", "timed"):
    anchor=f"{arm}) config=p40-{arm}-optimized; marker=P40_OUTCOME_BENCHMARK_PASS;;"
    if script.count(anchor)!=1:
        raise ValueError(f"P40 XPS completion marker drift: {arm}")
print("P40_XPS_MARKER_PREFLIGHT_PASS")
PY
