#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
python3 "$ROOT/tools/research/m1_p37_source_audit.py"
python3 "$ROOT/tools/research/m1_p37_make_pool.py" \
  "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/m1_p37_pool.d"
python3 "$ROOT/tools/research/m1_p37_make_owner.py" \
  "$ROOT" "$TMP/m1_p23_owned.d" "$TMP/m1_p37_owned.d"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
pool=(root/"m1_p37_pool.d").read_text()
owner=(root/"m1_p37_owned.d").read_text()
for token in ("module concurrency.research.m1_p37_pool;",
              "p37Local.waitNs", "p37Local.queueNs", "p37Local.notifyNs",
              "_changed.notify();", "return SubmissionResult.accepted;"):
    if token not in pool: raise SystemExit("P37 pool overlay missing: "+token)
if "import concurrency.research.m1_p37_pool :" not in owner:
    raise SystemExit("P37 owner not routed to overlay")
if "_retained ~= RetainedTask" not in owner:
    raise SystemExit("P37 owner lost strong-root installation")
print("P37_OVERLAY_PREFLIGHT_PASS source_only=true no_compiler_claim=true")
PY
