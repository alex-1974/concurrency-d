#!/usr/bin/env bash
# P35 generated-source preflight; no native timing qualification.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
python3 "$ROOT/tools/research/m1_p35_source_audit.py"
python3 "$ROOT/tools/research/m1_p35_make_owner.py" "$ROOT" \
  "$TMP/p23.d" "$TMP/p35.d"
python3 - "$TMP/p35.d" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
required=("module concurrency.research.m1_p35_owned;",
          "struct P35Stats", "p35Take()", "version (P35Timed)",
          "p35ThreadStats.waitNs", "p35ThreadStats.holdNs",
          "Lifecycle.joinedStopped")
for part in required:
    if part not in text:
        raise SystemExit("P35 preflight missing "+part)
print("P35_GENERATED_OWNER_PREFLIGHT_PASS no_compiler_claim=true")
PY
