#!/usr/bin/env python3
"""P31: verify fixed-dimension, same-M0-work scaling triplets.

No shared-runner timing threshold; native XPS observations are required.
"""
import argparse
import csv
import io
import json
import statistics
from pathlib import Path

MODES = ("m0", "deferred", "managed")
WORK = ("shared_atomic", "sharded_atomic", "minimal")
PRODUCERS = (1, 2, 4)
TIMES = ("create_start_ns", "submit_ns", "join_release_ns", "total_ns")
FIELDS = (
    "phase", "round", "work", "producers", "mode", "count", "workers",
    "ingress", "retained", "accepted", "completed", "executed",
    "checksum", "attempts", "producer_alloc_bytes", *TIMES,
)
NUMERIC = set(FIELDS) - {"phase", "work", "mode"}


def validate(stream, min_rounds):
    reader = csv.DictReader(stream)
    if tuple(reader.fieldnames or ()) != FIELDS:
        raise ValueError("P31 CSV schema mismatch: " + str(reader.fieldnames))
    groups = {}
    fixed = None
    for row in reader:
        if (row["phase"] not in ("warmup", "measure") or
                row["work"] not in WORK or row["mode"] not in MODES):
            raise ValueError("P31 invalid categorical value")
        for name in NUMERIC:
            row[name] = int(row[name])
            if row[name] < 0:
                raise ValueError("P31 negative metric " + name)
        if row["producers"] not in PRODUCERS:
            raise ValueError("P31 unknown producer count")
        dims = tuple(row[name] for name in
                     ("count", "workers", "ingress", "retained"))
        if fixed is None:
            fixed = dims
        if dims != fixed:
            raise ValueError("P31 fixed dimensions changed across profiles")
        if row["count"] <= 0 or row["count"] % row["producers"]:
            raise ValueError("P31 invalid task division")
        if not (row["accepted"] == row["completed"] == row["count"]):
            raise ValueError("P31 incomplete native M0 task completion")
        if row["attempts"] < row["accepted"]:
            raise ValueError("P31 fewer attempts than accepted tasks")
        expected_count = 0 if row["work"] == "minimal" else row["count"]
        expected_sum = expected_count * 60
        if row["executed"] != expected_count or row["checksum"] != expected_sum:
            raise ValueError("P31 incorrect task-side work oracle")
        if any(row[n] <= 0 for n in TIMES):
            raise ValueError("P31 nonpositive monotonic phase")
        gap = abs(sum(row[n] for n in TIMES[:3]) - row["total_ns"])
        if gap > 1000:
            raise ValueError("P31 inconsistent phase sum by " + str(gap))
        key = (row["phase"], row["round"], row["work"], row["producers"])
        triple = groups.setdefault(key, {})
        if row["mode"] in triple:
            raise ValueError("P31 duplicate owner mode in profile")
        triple[row["mode"]] = row

    if not groups:
        raise ValueError("P31 empty CSV")
    rounds = set(k[1] for k in groups if k[0] == "measure")
    if len(rounds) < min_rounds:
        raise ValueError("P31 insufficient measurement rounds")
    measured = {}
    for phase, round_num, work, producers in groups:
        triple = groups[(phase, round_num, work, producers)]
        if set(triple) != set(MODES):
            raise ValueError("P31 incomplete owner-mode triple")
    for round_num in rounds:
        for work in WORK:
            for producers in PRODUCERS:
                k = ("measure", round_num, work, producers)
                if k not in groups:
                    raise ValueError("P31 missing fixed-profile measured triplet")
                measured[(round_num, work, producers)] = groups[k]
    return measured, fixed


def summary(measured, fixed):
    report = {
        "diagnostic_only": True,
        "dimensions_fixed": dict(zip(
            ("count", "workers", "ingress", "retained"), fixed)),
        "rounds": len(set(k[0] for k in measured)),
        "profiles": {},
    }
    for work in WORK:
        report["profiles"][work] = {}
        for mode in MODES:
            values = {}
            for producers in PRODUCERS:
                rows = [triple[mode] for (rnd, w, p), triple in
                        measured.items() if w == work and p == producers]
                submit = [r["submit_ns"] for r in rows]
                values[str(producers)] = {
                    "submit_ns_median": statistics.median(submit),
                    "submit_ns_min": min(submit),
                    "submit_ns_max": max(submit),
                    "attempts_median": statistics.median(
                        [r["attempts"] for r in rows]),
                    "producer_alloc_bytes_median": statistics.median(
                        [r["producer_alloc_bytes"] for r in rows]),
                }
            for producers in (2, 4):
                ratios = []
                for rnd in sorted(set(k[0] for k in measured)):
                    baseline = measured[(rnd, work, 1)][mode]["submit_ns"]
                    current = measured[(rnd, work, producers)][mode]["submit_ns"]
                    ratios.append(baseline / current)
                values[str(producers)]["paired_throughput_over_1p_median"] = (
                    statistics.median(ratios))
                values[str(producers)]["paired_ratio_min"] = min(ratios)
                values[str(producers)]["paired_ratio_max"] = max(ratios)
            report["profiles"][work][mode] = values
    return report


def self_test():
    rows = [",".join(FIELDS)]
    for r in range(3):
        for work in WORK:
            for producers in PRODUCERS:
                for mode in MODES:
                    executed = 0 if work == "minimal" else 96
                    rows.append(",".join(map(str, [
                        "measure", r, work, producers, mode,
                        96, 4, 32, 64, 96, 96, executed,
                        executed * 60, 110, 2048,
                        100, (1 + producers) * 300, 100,
                        (1 + producers) * 300 + 200,
                    ])))
    original = "\n".join(rows) + "\n"
    measurements, fixed = validate(io.StringIO(original), 3)
    result = summary(measurements, fixed)
    if (result["rounds"] != 3 or
        len(result["profiles"]) != 3 or
        result["dimensions_fixed"]["count"] != 96):
        raise ValueError("P31 summary self-test failed")

    replacements = [
        (",96,96,96,5760,", ",96,95,96,5760,"),
        (",96,4,32,64,", ",96,8,32,64,"),
        (",96,96,0,0,", ",96,96,1,60,"),
    ]
    for needle, replacement in replacements:
        corrupted = original.replace(needle, replacement, 1)
        if corrupted == original:
            raise ValueError("P31 negative fixture did not mutate")
        try:
            validate(io.StringIO(corrupted), 3)
        except ValueError:
            pass
        else:
            raise ValueError("P31 invalid fixture unexpectedly validated")
    print("P31_ANALYZER_SELFTEST_PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--min-rounds", type=int, default=3)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.input is None:
        parser.error("--input is required")
    with args.input.open(newline="") as stream:
        measured, dimensions = validate(stream, args.min_rounds)
    report = summary(measured, dimensions)
    print("P31_FIXED_WORK_VALIDATED rounds=" + str(report["rounds"]))
    print("P31_DIAGNOSTIC_ONLY " + json.dumps(report, sort_keys=True))
    if args.json:
        args.json.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
