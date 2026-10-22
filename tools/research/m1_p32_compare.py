#!/usr/bin/env python3
"""P32-B exact-work correctness gate. Timings are diagnostic, not speed gates."""
import argparse
import csv
from pathlib import Path
from statistics import median

FIELDS = ("phase", "round", "producers", "count", "workers", "ingress",
          "accepted", "attempts", "completed", "submit_ns", "join_ns",
          "submit_calls", "submit_wait_ns", "submit_hold_ns",
          "batch_calls", "complete_calls")


def read(path):
    with path.open(newline="") as source:
        reader = csv.DictReader(source)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError(f"P32 incorrect CSV schema: {path}")
        rows = {}
        for row in reader:
            if row["phase"] not in ("warmup", "measure"):
                raise ValueError("P32 invalid phase")
            for field in FIELDS[1:]:
                row[field] = int(row[field])
                if row[field] < 0:
                    raise ValueError("P32 negative " + field)
            key = (row["phase"], row["round"], row["producers"])
            if key in rows:
                raise ValueError("P32 duplicate profile")
            if row["producers"] not in (1, 2, 4):
                raise ValueError("P32 invalid producer")
            if not row["count"] == row["accepted"] == row["completed"]:
                raise ValueError("P32 task loss")
            if row["attempts"] < row["accepted"]:
                raise ValueError("P32 negative retries")
            if row["submit_ns"] == 0 or row["join_ns"] == 0:
                raise ValueError("P32 invalid timing")
            rows[key] = row
        return rows


def compare(control, timed, min_rounds):
    a, b = read(control), read(timed)
    if a.keys() != b.keys():
        raise ValueError("P32 incomplete matched profiles")
    measured = set(k[1] for k in a if k[0] == "measure")
    if len(measured) < min_rounds:
        raise ValueError("P32 insufficient rounds")
    for round_ in measured:
        for p in (1, 2, 4):
            if ("measure", round_, p) not in a:
                raise ValueError("P32 missing producer arm")
    ratios = {1: [], 2: [], 4: []}
    for key in a:
        x, y = a[key], b[key]
        for field in ("count", "workers", "ingress", "accepted", "completed"):
            if x[field] != y[field]:
                raise ValueError("P32 unmatched work/dimensions")
        if any(x[k] for k in FIELDS[11:]):
            raise ValueError("P32 control has timing instrumentation")
        if (y["submit_calls"] != y["attempts"] or
                y["complete_calls"] != y["count"] or
                y["batch_calls"] == 0):
            raise ValueError("P32 timed calls not conserved")
        if key[0] == "measure":
            ratios[key[2]].append(y["submit_ns"] / x["submit_ns"])
    for p in (1, 2, 4):
        print(f"P32_B_CI_DIAGNOSTIC producers={p} "
              f"timed/control_submit_median={median(ratios[p]):.4f}")
    print("P32_B_MATCHED_WORK_PASS rounds=" + str(len(measured)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("control", type=Path)
    parser.add_argument("timed", type=Path)
    parser.add_argument("--min-rounds", type=int, default=3)
    args = parser.parse_args()
    compare(args.control, args.timed, args.min_rounds)


if __name__ == "__main__":
    main()
