#!/usr/bin/env python3
"""P33 same-work pairing; startup barrier changes schedule (diagnostic only)."""
import argparse
import csv
from pathlib import Path
from statistics import median

KEYS = ("phase", "round", "work", "producers", "mode")
SAME = ("count", "workers", "ingress", "retained", "accepted",
        "completed", "executed", "checksum")
TIMES = ("submit_ns", "join_release_ns", "total_ns")


def load(path):
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames or not set(KEYS + SAME + TIMES).issubset(
                reader.fieldnames):
            raise ValueError("P33 comparison invalid schema")
        out = {}
        for row in reader:
            key = tuple(row[name] for name in KEYS)
            if key in out:
                raise ValueError("P33 duplicate row")
            out[key] = row
        return out


def compare(control, phases, min_rounds):
    left, right = load(control), load(phases)
    if left.keys() != right.keys():
        raise ValueError("P33 mismatched profiles")
    rounds = {key[1] for key in left if key[0] == "measure"}
    if len(rounds) < min_rounds:
        raise ValueError("P33 insufficient measured rounds")
    ratios = {}
    for key in left:
        original, gated = left[key], right[key]
        for field in SAME:
            if original[field] != gated[field]:
                raise ValueError(f"P33 mismatched work {key}: {field}")
        for field in TIMES:
            if int(original[field]) <= 0 or int(gated[field]) <= 0:
                raise ValueError("P33 invalid phase time")
        if key[0] == "measure":
            ratio = int(gated["submit_ns"]) / int(original["submit_ns"])
            ratios.setdefault(key[2:], []).append(ratio)
    for key, samples in sorted(ratios.items()):
        print("P33_PAIRED_DIAGNOSTIC",
              "work=" + key[0], "producers=" + key[1], "mode=" + key[2],
              "gated_over_original_submit_median=" + f"{median(samples):.4f}")
    print("P33_PAIRED_WORK_PASS rounds=" + str(len(rounds)) +
          " diagnostic_only=true")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("control", type=Path)
    p.add_argument("phases", type=Path)
    p.add_argument("--min-rounds", type=int, default=9)
    a = p.parse_args()
    compare(a.control, a.phases, a.min_rounds)
