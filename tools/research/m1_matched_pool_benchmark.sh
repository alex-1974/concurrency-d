#!/usr/bin/env bash
# P12: correct, paired, RESEARCH-ONLY diagnostic on genuine M0 scheduler.
# Never assert a CI throughput threshold or promote CI numbers as a verdict.
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p12_matched_pool"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v "$DC" >/dev/null 2>&1
command -v dub >/dev/null 2>&1
# The native XPS capture script is shell-parsed in CI, but never launched
# there: its full 6-workload measurement belongs on the target hardware.
bash -n "$ROOT/tools/research/m1_matched_pool_xps.sh"

echo "P12 compiler=$("$DC" --version | head -n 1)"
echo "P12 dub=$(dub --version)"
echo "P12 host=$(uname -srm)"
if command -v lscpu >/dev/null 2>&1; then
    lscpu | grep -m1 '^Model name:' || true
fi

# Controlled smoke: identical 16,384-record storage capacity in BOTH arms,
# only 2,048 active jobs. 1 warm-up pair + 3 measured AB/BA pairs.
# Keep asserts and checksums ON in all configurations.
timeout --signal=TERM --kill-after=5s 150s \
    dub run --root="$BASE" --compiler="$DC" --build=debug \
        --config=smoke -- --count 2048 --warmup 1 --rounds 3 \
        --workers 2 --ingress 64 >"$TMP/smoke.raw"
# DUB may write build/run status to stdout; accept CSV records only.
grep -E '^(phase,pair,mode,|warmup,|measure,)' "$TMP/smoke.raw" >"$TMP/smoke.csv"
cat "$TMP/smoke.csv"

if [[ "$(basename -- "$DC")" == ldc2* ]]; then
    timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=debug \
            --config=optimized -- --count 8192 --warmup 2 --rounds 5 \
            --workers 2 --ingress 64 >"$TMP/optimized.raw"
    grep -E '^(phase,pair,mode,|warmup,|measure,)' "$TMP/optimized.raw" >"$TMP/optimized.csv"
    cat "$TMP/optimized.csv"

    # Production-like compiler flags across the DUB dependency graph.
    # Explicit per-task/oracle checks in P12 source remain active when
    # ordinary compiler 'assert' checks are disabled by release mode.
    timeout --signal=TERM --kill-after=5s 150s \
        dub run --root="$BASE" --compiler="$DC" --build=release \
            --config=release-mode -- --count 8192 --warmup 2 \
            --rounds 5 --workers 2 --ingress 64 >"$TMP/release.raw"
    grep -E '^(phase,pair,mode,|warmup,|measure,)' "$TMP/release.raw" >"$TMP/release.csv"
    cat "$TMP/release.csv"
fi

# Check comparable work, paired samples, deterministic checksum and order.
python3 - "$TMP/smoke.csv" "$TMP/optimized.csv" "$TMP/release.csv" <<'PY'
import csv
import statistics
import sys
from pathlib import Path

for name in sys.argv[1:]:
    path = Path(name)
    if not path.exists():
        continue
    with path.open(newline="") as stream:
        samples = list(csv.DictReader(stream))
    if not samples:
        raise SystemExit(f"FAIL P12 no samples in {name}")
    pairs = {}
    for sample in samples:
        if sample["mode"] not in ("stack", "heap"):
            raise SystemExit(f"FAIL P12 unknown mode: {sample}")
        key = (sample["phase"], sample["pair"])
        pairs.setdefault(key, {})[sample["mode"]] = sample
        for field in ("total_ns", "prepare_ns", "pool_start_ns",
                      "submit_join_ns", "verify_ns"):
            if int(sample[field]) < 0:
                raise SystemExit(f"FAIL P12 negative timing: {sample}")
    measured = []
    for (phase, pair), item in sorted(pairs.items()):
        if set(item) != {"stack", "heap"}:
            raise SystemExit(f"FAIL P12 incomplete pair {phase}:{pair}")
        if item["stack"]["checksum"] != item["heap"]["checksum"]:
            raise SystemExit(f"FAIL P12 unequal checksums: {item}")
        if item["stack"]["count"] != item["heap"]["count"]:
            raise SystemExit(f"FAIL P12 unequal operations: {item}")
        if phase == "measure":
            measured.append(item)
    if len(measured) < 3:
        raise SystemExit(f"FAIL P12 fewer than three measured pairs: {name}")

    # Diagnostic ONLY. Do not treat medians on GitHub's shared runners as
    # evidence to select a production representation.
    for mode in ("stack", "heap"):
        totals = sorted(int(pair[mode]["total_ns"]) for pair in measured)
        print(f"P12 DIAGNOSTIC {path.name} {mode} "
              f"median_ns={statistics.median(totals):.0f} "
              f"min_ns={totals[0]} max_ns={totals[-1]}")
    print(f"P12 correctness/paired-shape PASS: {path.name} "
          f"pairs={len(measured)} checksum={measured[0]['stack']['checksum']}")
PY
echo "P12 matched M0 worker benchmark smoke: PASS (NO CI speed gate)"
