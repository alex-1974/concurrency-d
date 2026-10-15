#!/usr/bin/env bash
# Native XPS capture for P30. Runs ON THE USER'S XPS, NOT on GitHub CI.
# No result is fabricated, no timing threshold decides a production API.
set -euo pipefail
DC="${P30_COMPILER:-ldc2}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
GEN="$BASE/concurrency/research/m1_p23_owned.d"
OUT="${1:-$HOME/Downloads/concurrency-p30-xps-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p -- "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ ! -e "$GEN" ]] || { echo "P30 generated research copy already exists" >&2; exit 1; }
command -v "$DC" >/dev/null
command -v dub >/dev/null
python3 "$ROOT/tools/research/m1_p30_analyze.py" --self-test
trap 'rm -f -- "$GEN"' EXIT
python3 "$ROOT/tools/research/m1_p23_make_owned.py" \
    "$ROOT/source/concurrency/internal/owned_task.d" "$GEN"

# Record exactly which machine, source and build ran each experiment.
python3 - "$ROOT" "$OUT/metadata.json" "$DC" <<'PY'
import datetime
import json
import os
import platform
import subprocess
import sys
from pathlib import Path

root, destination, dc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
def cmd(*args):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT,
                                       text=True, timeout=10).strip()
    except Exception as ex:
        return f"unavailable: {ex}"
governor = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
frequency = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
metadata = {
    "utc_timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "hostname": platform.node(),
    "os": platform.platform(),
    "machine": platform.machine(),
    "cpu": cmd("lscpu"),
    "governor": governor.read_text().strip() if governor.exists() else "unavailable",
    "frequency_khz_at_start": frequency.read_text().strip() if frequency.exists() else "unavailable",
    "compiler": cmd(dc, "--version"),
    "dub": cmd("dub", "--version"),
    "git_head": cmd("git", "-C", str(root), "rev-parse", "HEAD"),
    "git_status": cmd("git", "-C", str(root), "status", "--porcelain"),
    "original_owned_blob": cmd("git", "-C", str(root), "hash-object",
                              "source/concurrency/internal/owned_task.d"),
    "original_pool_blob": cmd("git", "-C", str(root), "hash-object",
                             "source/concurrency/internal/submission_pool.d"),
    "build": "dub --build=release --config=p29-generational-optimized --d-version=P30Benchmark",
    "warmup": 3,
    "measured_triplets": 9,
    "purpose": "paired same-work diagnostic, NOT automatically a release decision",
}
destination.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY

bench() {
    local name="$1" count="$2" workers="$3" producers="$4"
    local ingress="$5" retained="$6"
    echo "P30 XPS capture: $name"
    timeout --signal=TERM --kill-after=5s 720s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
        --config=p29-generational-optimized --d-version=P30Benchmark -- \
        --count "$count" --workers "$workers" --producers "$producers" \
        --ingress "$ingress" --retained "$retained" --warmup 3 --rounds 9 \
        >"$OUT/$name.raw" 2>&1 || {
            cat "$OUT/$name.raw" >&2; exit 1;
        }
    grep -Fx 'P30_M0_OWNERSHIP_BENCHMARK_PASS' "$OUT/$name.raw" >/dev/null || {
        cat "$OUT/$name.raw" >&2; exit 1;
    }
    grep -E '^(phase,round,mode|warmup,|measure,)' \
        "$OUT/$name.raw" > "$OUT/$name.csv"
    python3 "$ROOT/tools/research/m1_p30_analyze.py" \
        --input "$OUT/$name.csv" --min-rounds 9 \
        --json "$OUT/$name-summary.json" | tee "$OUT/$name-analysis.txt"
}

# Separate one/multi-producer and work-stealing profiles. Same three
# implementations per profile, same TaskRef/Job/reclamation budgets.
bench single-producer 8192 2 1 64 1024
bench two-producer 8192 2 2 64 1024
bench four-producer 16384 4 4 128 1024

# Record end-of-run governor/frequency for basic run provenance.
python3 - "$OUT/metadata.json" <<'PY'
import datetime
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
obj = json.loads(path.read_text())
obj["utc_finished"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
freq = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
obj["frequency_khz_at_finish"] = (
    freq.read_text().strip() if freq.exists() else "unavailable"
)
path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")
PY

# One portable upload artifact, with SHA-256 alongside it. Do not
# write generated measurements into the Git research branch.
ARCHIVE="$OUT.tar.gz"
tar -C "$OUT" -czf "$ARCHIVE" .
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "P30_XPS_ARTIFACTS_READY $ARCHIVE"
echo "P30_XPS_SHA256 $ARCHIVE.sha256"
echo "Review raw CSV, metadata, thermal state and sample variance before claims."
