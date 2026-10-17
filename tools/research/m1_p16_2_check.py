#!/usr/bin/env python3
"""Validate P16.2 paired unchanged M0 and seq-cst research data.

This checks workload/observable semantics, not performance acceptance.
Native speed evidence must use actual XPS release data.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

KEY = ("phase", "round", "order", "seed", "workers",
       "count", "waves", "iterations", "ingress", "checksum")
PHASE = ("prepare_ns", "pool_start_ns", "waves_ns",
         "join_ns", "verify_ns")

def read(path):
    with path.open(newline="") as h:
        rows = list(csv.DictReader(h))
    if not rows or not set(KEY + PHASE + ("total_ns",)).issubset(rows[0]):
        raise ValueError(f"P16.2 invalid benchmark CSV: {path}")
    return rows

def compare(original, alternative, min_rows=12):
    a, b = read(original), read(alternative)
    if len(a) != len(b) or len(a) < min_rows:
        raise ValueError("P16.2 original/candidate record count differs")
    ratios = defaultdict(list)
    for index, (base, candidate) in enumerate(zip(a, b)):
        for k in KEY:
            if base[k] != candidate[k]:
                raise ValueError(f"P16.2 mismatch row {index} field {k}")
        for row in (base, candidate):
            times = [int(row[k]) for k in PHASE]
            if min(times) < 0 or sum(times) != int(row["total_ns"]):
                raise ValueError(f"P16.2 invalid clock-stage accounting row {index}")
            if int(row["total_ns"]) <= 0 or int(row["waves_ns"]) <= 0:
                raise ValueError("P16.2 invalid duration")
            if int(row["retries"]) < 0 or int(row["park_count"]) < 0:
                raise ValueError("P16.2 invalid scheduler observation")
        if base["phase"] == "measure":
            k = (int(base["workers"]), int(base["iterations"]),
                 int(base["ingress"]))
            ratios[k].append(int(candidate["waves_ns"]) /
                             int(base["waves_ns"]))
    if not ratios:
        raise ValueError("P16.2 no measured records")
    for key, vals in sorted(ratios.items()):
        print(f"P16.2 CI DIAGNOSTIC workers={key[0]} "
              f"iterations={key[1]} ingress={key[2]} "
              f"atomic/original median={median(vals):.3f} n={len(vals)}")
    print(f"P16.2 PASS identical source workloads and results "
          f"rows={len(a)} measured_cases={len(ratios)}")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("control", type=Path)
    p.add_argument("atomic", type=Path)
    p.add_argument("--min-rows", type=int, default=12)
    a = p.parse_args()
    compare(a.control, a.atomic, a.min_rows)

if __name__ == "__main__":
    main()
