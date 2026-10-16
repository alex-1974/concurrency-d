#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
python3 "$ROOT/tools/research/m1_p38_source_audit.py"
python3 "$ROOT/tools/research/m1_p38_make_pool.py" \
 "$ROOT" "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/m1_p38_pool.d"
python3 - "$TMP/m1_p38_pool.d" <<'PY'
import sys
from pathlib import Path
s=Path(sys.argv[1]).read_text()
markers=[
 "module concurrency.research.m1_p38_pool;",
 "++p38ThreadCounters.parkCalls;",
 "++p38ThreadCounters.waitEntries;",
 "_changed.wait();",
 "++p38ThreadCounters.waitReturns;",
 "_p38Workers[workerIndex] = p38ThreadCounters;",
 "P38WorkerCounters[] researchWorkerCounters()",
]
pos=0
for marker in markers[:1]:
    assert marker in s,marker
for marker in markers[1:]:
    assert marker in s,marker
assert s.index("++p38ThreadCounters.waitEntries;") < s.index("_changed.wait();") < s.index("++p38ThreadCounters.waitReturns;")
print("P38_WORKER_COUNTER_PREFLIGHT_PASS source_only=true compiler_untested=true")
PY
