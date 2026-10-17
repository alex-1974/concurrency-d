#!/usr/bin/env bash
# XPS-only P31 fixed producer scaling (research evidence, no speed gate).
set -euo pipefail
DC="${P31_COMPILER:-ldc2}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
OUT="${1:-$HOME/Downloads/concurrency-p31-xps-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p -- "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ ! -e "$GEN" ]] || { echo "P31 stale research copy" >&2; exit 1; }
command -v "$DC" >/dev/null
command -v dub >/dev/null
python3 "$ROOT/tools/research/m1_p31_analyze.py" --self-test
test "$(git -C "$ROOT" hash-object source/concurrency/internal/owned_task.d)" = \
    e74d6a73f956c562eab176e27687a47249f5815d
test "$(git -C "$ROOT" hash-object source/concurrency/internal/submission_pool.d)" = \
    b7d8fafcb3179f00cba7e89e28c6d6b9b676353a
trap 'rm -f -- "$GEN"' EXIT
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"

python3 - "$ROOT" "$OUT/metadata.json" "$DC" <<'PY'
import datetime
import json
import platform
import subprocess
import sys
from pathlib import Path
root, output, dc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
def run(*command):
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT,
                                       timeout=12).strip()
    except Exception as error:
        return f"unavailable: {error}"
freq = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
gov = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
data = {
    "protocol": "P31 fixed-count/worker/ingress/retention producer sweep",
    "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": platform.node(),
    "os": platform.platform(),
    "cpu": run("lscpu"),
    "compiler": run(dc, "--version"),
    "dub": run("dub", "--version"),
    "git_head": run("git", "-C", str(root), "rev-parse", "HEAD"),
    "git_status": run("git", "-C", str(root), "status", "--porcelain"),
    "owner_blob": run("git", "-C", str(root), "hash-object",
                      "source/concurrency/internal/owned_task.d"),
    "pool_blob": run("git", "-C", str(root), "hash-object",
                     "source/concurrency/internal/submission_pool.d"),
    "governor": gov.read_text().strip() if gov.exists() else "unavailable",
    "cpu0_frequency_start_khz": freq.read_text().strip() if freq.exists()
                               else "unavailable",
    "build": "DUB whole release, p29-generational-optimized, P31Benchmark (-O3)",
    "work": ["shared_atomic", "sharded_atomic", "minimal"],
    "producers": [1, 2, 4],
    "dimensions": {"count": 8192, "workers": 4,
                   "ingress": 128, "retained": 1024},
    "warmup": 3,
    "measured_rounds": 9,
    "purpose": "bounded native XPS diagnosis; no automatic release decision"
}
output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

timeout --signal=TERM --kill-after=5s 1200s \
    dub run --root="$BASE" --compiler="$DC" --build=release \
        --config=p29-generational-optimized --d-version=P31Benchmark -- \
        --count 8192 --workers 4 --ingress 128 --retained 1024 \
        --warmup 3 --rounds 9 >"$OUT/benchmark.raw" 2>&1 || {
            cat "$OUT/benchmark.raw" >&2
            exit 1
        }
grep -Fx 'P31_FIXED_DIMENSIONS_BENCHMARK_PASS' "$OUT/benchmark.raw" >/dev/null || {
    cat "$OUT/benchmark.raw" >&2
    exit 1
}
grep -E '^(phase,round,work|warmup,|measure,)' \
    "$OUT/benchmark.raw" > "$OUT/benchmark.csv"
python3 "$ROOT/tools/research/m1_p31_analyze.py" \
    --input "$OUT/benchmark.csv" --min-rounds 9 \
    --json "$OUT/summary.json" | tee "$OUT/analysis.txt"

python3 - "$OUT/metadata.json" <<'PY'
import datetime
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["completed_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
freq = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
data["cpu0_frequency_end_khz"] = (
    freq.read_text().strip() if freq.exists() else "unavailable"
)
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

ARCHIVE="$OUT.tar.gz"
tar -C "$OUT" -czf "$ARCHIVE" .
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "P31_XPS_ARCHIVE $ARCHIVE"
echo "P31_XPS_SHA256 $ARCHIVE.sha256"
echo "Compare fixed-work profiles; do not equate task work-kinds semantically."
