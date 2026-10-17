#!/usr/bin/env python3
"""P32-A: independently classify failed admissions in verified P31 CSV.

Observational only: an accepted first attempt does not measure mutex wait.
"""
import argparse
import csv
import io
import json
import statistics
from pathlib import Path

from m1_p31_analyze import validate, WORK, MODES, PRODUCERS


def analyze(path, min_rounds):
    with path.open(newline="") as f:
        measured, fixed = validate(f, min_rounds)
    groups = {}
    for work in WORK:
        for mode in MODES:
            for producers in PRODUCERS:
                rows = [
                    group[mode] for (rnd, w, p), group in measured.items()
                    if w == work and p == producers
                ]
                retries = [r["attempts"] - r["accepted"] for r in rows]
                if any(v < 0 for v in retries):
                    raise ValueError("negative retry count")
                groups[f"{work}/{mode}/{producers}"] = {
                    "rounds": len(rows),
                    "zero_retry_rounds": sum(v == 0 for v in retries),
                    "retry_median": statistics.median(retries),
                    "retry_max": max(retries),
                    "submit_ms_median": statistics.median(
                        r["submit_ns"] / 1e6 for r in rows),
                }
    return {
        "source": str(path),
        "dimensions": dict(zip(("count", "workers", "ingress", "retained"), fixed)),
        "measured_rows": sum(v["rounds"] for v in groups.values()),
        "total_zero_retry_rows": sum(v["zero_retry_rounds"] for v in groups.values()),
        "total_groups": len(groups),
        "diagnostic_only": True,
        "groups": groups,
    }


def self_test():
    # Positive-control validation is delegated to the original P31 parser.
    # Reject a nonexistent input (rather than silently producing empty findings).
    try:
        analyze(Path("/unlikely-p32-missing-input-2026.csv"), 1)
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("missing input was accepted")
    print("P32_A_ANALYZER_SELFTEST_PASS")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", type=Path)
    p.add_argument("--min-rounds", type=int, default=9)
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--json", type=Path)
    args = p.parse_args()
    if args.self_test:
        self_test()
        if args.input is None:
            return
    if args.input is None:
        p.error("--input is required")
    report = analyze(args.input, args.min_rounds)
    if report["measured_rows"] != 27 * report["groups"]["minimal/m0/1"]["rounds"]:
        raise ValueError("incomplete profile grid")
    print("P32_A_CLASSIFICATION_PASS measured_rows=" +
          str(report["measured_rows"]) +
          " zero_retry_rows=" + str(report["total_zero_retry_rows"]))
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    else:
        print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
