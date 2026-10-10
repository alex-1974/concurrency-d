#!/usr/bin/env bash

main() {
    REPO="$(git rev-parse --show-toplevel 2>/dev/null)"

    if [ -z "$REPO" ]; then
        printf '%s\n' "ERROR: run from inside the concurrency-d repository" >&2
        return 1
    fi

    cd "$REPO" || return 1

    STAMP="$(date +%Y%m%d-%H%M%S)"
    OUT_DIR="research/r0_3_worker_scheduling/evidence"
    mkdir -p "$OUT_DIR" || return 1

    SUMMARY="$OUT_DIR/xps-${STAMP}-p05-summary.txt"

    {
        echo "=== R0.3 P05 XPS QUALIFICATION ==="
        echo "timestamp=$STAMP"
        echo "commit=$(git rev-parse HEAD)"
        echo
        echo "=== SELECTED X86_64 POLICY ==="
        echo "recursive=P01 enqueue-all implementation"
        echo "irregular=P01 enqueue-all implementation"
        echo "duplicate-candidate comparison=disabled"
        echo
        echo "=== PLATFORM ==="
        uname -a
        echo
        lscpu
        echo
        echo "=== TOOLCHAIN ==="
        ldc2 --version
        dub --version
        echo
    } | tee "$SUMMARY"

    RC=0

    FLAT="research/r0_3_worker_scheduling/probes/p05a_combined_flat"
    REC="research/r0_3_worker_scheduling/probes/p01b_baseline_recursive"
    IRR="research/r0_3_worker_scheduling/probes/p01c_baseline_irregular"

    FLAT_LOG="$OUT_DIR/xps-${STAMP}-p05a-flat.log"

    echo "=== P05a FLAT COMBINED ===" | tee -a "$SUMMARY"

    dub run \
        --root="$FLAT" \
        --compiler=ldc2 \
        --build=release \
        --force \
        2>&1 | tee "$FLAT_LOG"

    FLAT_RC=${PIPESTATUS[0]}

    echo "flat_rc=$FLAT_RC" | tee -a "$SUMMARY"
    echo "flat_log=$FLAT_LOG" | tee -a "$SUMMARY"
    echo | tee -a "$SUMMARY"

    if [ "$FLAT_RC" -ne 0 ]; then
        RC="$FLAT_RC"
    fi

    for i in 1 2 3; do
        echo "=== SELECTED X86 ROUND $i ===" | tee -a "$SUMMARY"

        dub run \
            --root="$REC" \
            --compiler=ldc2 \
            --build=release \
            --force \
            > "$OUT_DIR/xps-${STAMP}-rec-$i.log" 2>&1

        REC_RC=$?

        dub run \
            --root="$IRR" \
            --compiler=ldc2 \
            --build=release \
            --force \
            > "$OUT_DIR/xps-${STAMP}-irr-$i.log" 2>&1

        IRR_RC=$?

        printf 'round=%s rec_rc=%s irr_rc=%s\n' \
            "$i" \
            "$REC_RC" \
            "$IRR_RC" \
            | tee -a "$SUMMARY"

        if [ "$REC_RC" -ne 0 ]; then RC="$REC_RC"; fi
        if [ "$IRR_RC" -ne 0 ]; then RC="$IRR_RC"; fi
    done

    python3 - "$OUT_DIR" "$STAMP" <<'PY' | tee -a "$SUMMARY"
import re
import statistics
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
stamp = sys.argv[2]

def recursive(path):
    text = path.read_text()
    out = {}
    rx = re.compile(
        r"^(single|batch)\s+workers=(\d+)\s+"
        r"median=\s*([0-9.]+) ns/task",
        re.M,
    )
    for mode, workers, value in rx.findall(text):
        out[(mode, int(workers))] = float(value)
    if len(out) != 6:
        raise SystemExit(
            f"{path}: expected 6 recursive medians, got {len(out)}"
        )
    return out

def irregular(path):
    text = path.read_text()
    out = {}
    rx = re.compile(
        r"^(single|batch)\s+median=\s*([0-9.]+) ns/task",
        re.M,
    )
    for mode, value in rx.findall(text):
        out[mode] = float(value)
    if len(out) != 2:
        raise SystemExit(
            f"{path}: expected 2 irregular medians, got {len(out)}"
        )
    return out

rec_runs = [
    recursive(out_dir / f"xps-{stamp}-rec-{i}.log")
    for i in (1, 2, 3)
]

irr_runs = [
    irregular(out_dir / f"xps-{stamp}-irr-{i}.log")
    for i in (1, 2, 3)
]

print()
print("=== SELECTED X86 RECURSIVE ===")

for key in sorted(rec_runs[0], key=lambda x: (x[1], x[0])):
    values = [x[key] for x in rec_runs]
    median = statistics.median(values)
    spread = max(values) / min(values)

    print(
        f"{key[0]:6s} workers={key[1]} "
        f"median={median:8.3f} ns/task spread={spread:7.4f}x"
    )

print()
print("=== SELECTED X86 IRREGULAR ===")

for mode in ("single", "batch"):
    values = [x[mode] for x in irr_runs]
    median = statistics.median(values)
    spread = max(values) / min(values)

    print(
        f"{mode:6s} median={median:8.3f} ns/task "
        f"spread={spread:7.4f}x"
    )

print()
print("R0.3 P05 XPS SELECTED-X86 QUALIFICATION: PASS")
PY

    PARSE_RC=${PIPESTATUS[0]}

    if [ "$PARSE_RC" -ne 0 ]; then
        RC="$PARSE_RC"
    fi

    {
        echo
        echo "=== RESULT FILES ==="
        echo "$SUMMARY"
        echo "$FLAT_LOG"
        echo "$OUT_DIR/xps-${STAMP}-rec-{1,2,3}.log"
        echo "$OUT_DIR/xps-${STAMP}-irr-{1,2,3}.log"
        echo
        echo "overall_rc=$RC"
    } | tee -a "$SUMMARY"

    return "$RC"
}

main "$@"
