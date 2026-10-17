#!/usr/bin/env python3
"""P33 phase-invariant gate, no native performance thresholds."""
import argparse
import csv
from pathlib import Path

FIELDS = ("phase", "round", "work", "producers", "mode", "count",
          "workers", "ingress", "retained", "accepted", "completed",
          "executed", "checksum", "attempts", "producer_alloc_bytes",
          "create_start_ns", "submit_ns", "join_release_ns", "total_ns",
          "prepare_ns", "launch_ns", "reach_gate_ns", "release_ns",
          "submit_after_gate_ns", "worker_join_ns")


def validate(path, minimum):
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("P33 CSV schema drift")
        seen = set()
        rounds = set()
        dims = None
        for row in reader:
            if row["phase"] not in ("warmup", "measure") or row["work"] not in (
                    "minimal", "shared_atomic", "sharded_atomic") or row["mode"] not in (
                    "m0", "deferred", "managed"):
                raise ValueError("P33 unknown arm")
            for name in FIELDS:
                if name not in ("phase", "work", "mode"):
                    row[name] = int(row[name])
                    if row[name] < 0:
                        raise ValueError("P33 negative " + name)
            key = (row["phase"], row["round"], row["work"],
                   row["producers"], row["mode"])
            if key in seen:
                raise ValueError("P33 repeated arm")
            seen.add(key)
            if row["phase"] == "measure":
                rounds.add(row["round"])
            curr = tuple(row[x] for x in ("count", "workers", "ingress", "retained"))
            if dims is None:
                dims = curr
            if curr != dims:
                raise ValueError("P33 dimension drift")
            n = row["count"]
            if row["producers"] not in (1, 2, 4) or n % row["producers"]:
                raise ValueError("P33 invalid producer division")
            if row["accepted"] != n or row["completed"] != n or row["attempts"] < n:
                raise ValueError("P33 lost admission/completion")
            expected = 0 if row["work"] == "minimal" else n
            if row["executed"] != expected or row["checksum"] != 60 * expected:
                raise ValueError("P33 task-side oracle failed")
            if (row["prepare_ns"] <= 0 or row["launch_ns"] <= 0 or
                    row["reach_gate_ns"] < 0 or row["release_ns"] < 0 or
                    row["submit_after_gate_ns"] <= 0 or row["worker_join_ns"] <= 0):
                raise ValueError("P33 impossible phase")
            # submit_ns originally covered preparation, startup, release and join.
            phase_sum = sum(row[x] for x in (
                "prepare_ns", "launch_ns", "reach_gate_ns",
                "release_ns", "submit_after_gate_ns"))
            if abs(phase_sum - row["submit_ns"]) > 100_000:
                raise ValueError("P33 phase decomposition mismatch")
        if len(rounds) < minimum:
            raise ValueError("P33 insufficient measurement rounds")
        for k in rounds:
            for w in ("minimal", "shared_atomic", "sharded_atomic"):
                for p in (1, 2, 4):
                    for m in ("m0", "deferred", "managed"):
                        if ("measure", k, w, p, m) not in seen:
                            raise ValueError("P33 incomplete measured matrix")
    print("P33_PHASE_VALIDATION_PASS rounds=" + str(len(rounds)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("csv", type=Path)
    p.add_argument("--min-rounds", type=int, default=3)
    a = p.parse_args()
    validate(a.csv, a.min_rounds)


if __name__ == "__main__":
    main()
