#!/usr/bin/env bash
# Native XPS experiment capture: NO background work, NO repository mutation.
# Usage:
#   bash tools/research/m1_matched_pool_xps.sh ldc2 /tmp/p12-xps-2026-10-13
# Optional: P12_CPUSET=2,3 applies CPU affinity to the benchmark process (and DUB child processes).
set -euo pipefail
DC="${1:-ldc2}"
DEST="${2:-$PWD/p12-matched-pool-$(date +%Y%m%d-%H%M%S)}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p12_matched_pool"
mkdir -p -- "$DEST"
DEST="$(cd "$DEST" && pwd)"
mkdir -p "$DEST/raw" "$DEST/csv"
command -v "$DC" >/dev/null 2>&1
command -v dub >/dev/null 2>&1

{
    echo "Research P12 matched M0 scheduler / no performance verdict without review"
    echo "date_utc=$(date -u -Iseconds)"
    echo "repository=$ROOT"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
    echo "compiler=$(command -v "$DC")"
    "$DC" --version | head -n 3
    dub --version
    uname -a
    if command -v lscpu >/dev/null; then lscpu; fi
    echo "P12_CPUSET=${P12_CPUSET:-none}"
    echo "kernel=32 iterations, equivalent TaskRef/worker API"
    echo "mode=release; values/checksum checked via explicit throw even if assertions off"
    echo "warmup_pairs=3"
    echo "measured_pairs=11"
    echo "order=AB/BA alternating; phase timings from MonoTime"
    echo "compiler_deps=actual DUB concurrency-d + containers-d 0.2.0"
    echo "NO-GO: public @safe, native join recovery, C++ comparisons"
} >"$DEST/manifest.txt"

for workers in 1 2 4; do
    for count in 2048 16384; do
        label="workers${workers}-tasks${count}"
        raw="$DEST/raw/$label.log"
        csv="$DEST/csv/$label.csv"
        echo "P12 capturing $label" >&2
        # Record build diagnostics separately. Bench timing begins inside
        # executable after DUB build and never includes compiler time.
        if [[ -n "${P12_CPUSET:-}" ]]; then
            taskset -c "$P12_CPUSET" \
                dub run --root="$BASE" --compiler="$DC" --build=release \
                --config=release-mode -- --count "$count" --warmup 3 \
                --rounds 11 --workers "$workers" --ingress 64 >"$raw" 2>&1
        else
            dub run --root="$BASE" --compiler="$DC" --build=release \
                --config=release-mode -- --count "$count" --warmup 3 \
                --rounds 11 --workers "$workers" --ingress 64 >"$raw" 2>&1
        fi
        grep -E '^(phase,pair,mode,|warmup,|measure,)' "$raw" >"$csv"
    done
done

python3 - "$DEST" <<'PY'
from pathlib import Path
from collections import defaultdict
import csv
import statistics
import sys

root = Path(sys.argv[1])
lines = []
for path in sorted((root / "csv").glob("*.csv")):
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    paired = defaultdict(dict)
    for row in rows:
        key = (row["phase"], int(row["pair"]))
        if row["mode"] not in ("stack", "heap"):
            raise SystemExit(f"Invalid mode: {row}")
        paired[key][row["mode"]] = row

    data = []
    for (phase, pair), modes in paired.items():
        if set(modes) != {"stack", "heap"}:
            raise SystemExit(f"Incomplete pair {path}: {phase}/{pair}")
        if modes["stack"]["checksum"] != modes["heap"]["checksum"]:
            raise SystemExit(f"Checksum mismatch: {path}/{pair}")
        if phase == "measure":
            data.append((pair, modes["stack"], modes["heap"]))
    data.sort()
    if len(data) != 11:
        raise SystemExit(f"Expected 11 measured pairs, got {len(data)} for {path}")

    # Single-run contrast and paired sample distribution are both retained.
    for mode, position in (("stack", 1), ("heap", 2)):
        samples = sorted(int(pair[position]["total_ns"]) for pair in data)
        med = statistics.median(samples)
        lines.append([
            path.stem, mode, len(samples), f"{med:.0f}",
            str(samples[0]), str(samples[-1]),
            f"{(samples[8] - samples[2]):.0f}",
            data[0][1]["checksum"],
            "CI not used; XPS evidence requires independent noise review",
        ])
    differences = [
        int(pair[1]["total_ns"]) - int(pair[2]["total_ns"])
        for pair in data
    ]
    differences.sort()
    lines.append([
        path.stem, "paired_stack_minus_heap", len(differences),
        f"{statistics.median(differences):.0f}",
        str(differences[0]), str(differences[-1]),
        f"{differences[8] - differences[2]:.0f}",
        data[0][1]["checksum"], "positive means heap faster",
    ])

with (root / "summary.csv").open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["case", "metric", "pairs", "median_ns",
                     "min_ns", "max_ns", "p80minus20_ns", "checksum", "note"])
    writer.writerows(lines)
print(f"P12 native evidence: {root / 'summary.csv'}")
PY
tar -czf "$DEST.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
echo "P12 native evidence archive: $DEST.tar.gz"
