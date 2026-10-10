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
    REF_REC="research/r0_3_worker_scheduling/probes/p01b_baseline_recursive"
    CAND_REC="research/r0_3_worker_scheduling/probes/p05b_combined_recursive"
    REF_IRR="research/r0_3_worker_scheduling/probes/p01c_baseline_irregular"
    CAND_IRR="research/r0_3_worker_scheduling/probes/p05c_combined_irregular"

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
        echo "=== MATCHED ROUND $i ===" | tee -a "$SUMMARY"

        dub run \
            --root="$REF_REC" \
            --compiler=ldc2 \
            --build=release \
            --force \
            > "$OUT_DIR/xps-${STAMP}-rec-ref-$i.log" 2>&1

        REF_REC_RC=$?

        dub run \
            --root="$CAND_REC" \
            --compiler=ldc2 \
            --build=release \
            --force \
            > "$OUT_DIR/xps-${STAMP}-rec-cand-$i.log" 2>&1

        CAND_REC_RC=$?

        dub run \
            --root="$REF_IRR" \
            --compiler=ldc2 \
            --build=release \
            --force \
            > "$OUT_DIR/xps-${STAMP}-irr-ref-$i.log" 2>&1

        REF_IRR_RC=$?

        dub run \
            --root="$CAND_IRR" \
            --compiler=ldc2 \
            --build=release \
            --force \
            > "$OUT_DIR/xps-${STAMP}-irr-cand-$i.log" 2>&1

        CAND_IRR_RC=$?

        printf 'round=%s rec_ref_rc=%s rec_cand_rc=%s irr_ref_rc=%s irr_cand_rc=%s\n' \
            "$i" \
            "$REF_REC_RC" \
            "$CAND_REC_RC" \
            "$REF_IRR_RC" \
            "$CAND_IRR_RC" \
            | tee -a "$SUMMARY"

        if [ "$REF_REC_RC" -ne 0 ]; then RC="$REF_REC_RC"; fi
        if [ "$CAND_REC_RC" -ne 0 ]; then RC="$CAND_REC_RC"; fi
        if [ "$REF_IRR_RC" -ne 0 ]; then RC="$REF_IRR_RC"; fi
        if [ "$CAND_IRR_RC" -ne 0 ]; then RC="$CAND_IRR_RC"; fi
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

rec_refs = [
    recursive(out_dir / f"xps-{stamp}-rec-ref-{i}.log")
    for i in (1, 2, 3)
]
rec_cands = [
    recursive(out_dir / f"xps-{stamp}-rec-cand-{i}.log")
    for i in (1, 2, 3)
]

failed = False

print()
print("=== RECURSIVE P05 / P01 ===")

for key in sorted(rec_refs[0], key=lambda x: (x[1], x[0])):
    ref = statistics.median(x[key] for x in rec_refs)
    cand = statistics.median(x[key] for x in rec_cands)
    ratio = cand / ref

    print(
        f"{key[0]:6s} workers={key[1]} "
        f"ref={ref:8.3f} cand={cand:8.3f} ratio={ratio:7.4f}x"
    )

    if ratio > 1.10:
        failed = True

irr_refs = [
    irregular(out_dir / f"xps-{stamp}-irr-ref-{i}.log")
    for i in (1, 2, 3)
]
irr_cands = [
    irregular(out_dir / f"xps-{stamp}-irr-cand-{i}.log")
    for i in (1, 2, 3)
]

print()
print("=== IRREGULAR P05 / P01 ===")

for mode in ("single", "batch"):
    ref_values = [x[mode] for x in irr_refs]
    cand_values = [x[mode] for x in irr_cands]

    ref = statistics.median(ref_values)
    cand = statistics.median(cand_values)
    ratio = cand / ref
    spread = max(cand_values) / min(cand_values)

    print(
        f"{mode:6s} ref={ref:8.3f} cand={cand:8.3f} "
        f"ratio={ratio:7.4f}x candidateSpread={spread:7.4f}x"
    )

    if ratio > 1.10:
        failed = True

if failed:
    print()
    print("R0.3 P05 XPS REGRESSION GATE: FAIL")
    raise SystemExit(1)

print()
print("R0.3 P05 XPS REGRESSION GATE: PASS")
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
        echo "$OUT_DIR/xps-${STAMP}-rec-ref-{1,2,3}.log"
        echo "$OUT_DIR/xps-${STAMP}-rec-cand-{1,2,3}.log"
        echo "$OUT_DIR/xps-${STAMP}-irr-ref-{1,2,3}.log"
        echo "$OUT_DIR/xps-${STAMP}-irr-cand-{1,2,3}.log"
        echo
        echo "overall_rc=$RC"
    } | tee -a "$SUMMARY"

    return "$RC"
}

main "$@"
