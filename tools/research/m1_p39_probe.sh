#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
python3 "$ROOT/tools/research/m1_p38_source_audit.py"
python3 "$ROOT/tools/research/m1_p39_make_pool.py" \
  "$ROOT" "$ROOT/source/concurrency/internal/submission_pool.d" "$TMP/m1_p39_pool.d"
python3 - "$TMP/m1_p39_pool.d" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
expected={
    "++_p39Notifications.publish;":1,
    "++_p39Notifications.localWork;":1,
    "++_p39Notifications.closeAll;":1,
    "++_p39Notifications.finalCompletionAll;":1,
    "P39NotificationStats researchNotificationStats()":2,
}
for anchor,n in expected.items():
    if s.count(anchor)!=n: raise ValueError(f"P39 insertion drift: {anchor}")
assert s.count("_changed.notify();")==2
assert s.count("_changed.notifyAll();")==2
assert "_generation == observed &&" in s
assert "_used == 0 &&" in s
assert "++p38ThreadCounters.waitEntries;" in s
assert "++p38ThreadCounters.waitReturns;" in s
print("P39_NOTIFICATION_SITE_PREFLIGHT_PASS source_only=true compiler_untested=true")
PY
