#!/usr/bin/env python3
"""P30: validate paired same-work CSV and summarize phase-separated ratios.

No CI timing is a production-performance verdict. Positive ratios
managed/deferred above 1 mean managed is slower on that phase.
"""
import argparse
import csv
import json
import statistics
from pathlib import Path

MODES = ("m0", "deferred", "managed")
TIMES = ("create_start_ns", "submit_ns", "join_release_ns", "total_ns")
FIELDS = (
    "phase", "round", "mode", "count", "workers", "producers", "ingress",
    "retained", "accepted", "completed", "checksum", "attempts",
    "producer_alloc_bytes", *TIMES,
)
NUMERIC = set(FIELDS) - {"phase", "mode"}


def validate(lines, min_rounds):
    reader = csv.DictReader(lines)
    if tuple(reader.fieldnames or ()) != FIELDS:
        raise ValueError(f"P30 schema drift: {reader.fieldnames}")
    pairs = {}
    for row in reader:
        if row["phase"] not in ("warmup", "measure"):
            raise ValueError(f"P30 invalid phase: {row}")
        if row["mode"] not in MODES:
            raise ValueError(f"P30 invalid mode: {row}")
        for col in NUMERIC:
            row[col] = int(row[col])
            if row[col] < 0:
                raise ValueError(f"P30 negative metric {col}")
        if row["accepted"] != row["count"] or row["completed"] != row["count"]:
            raise ValueError("P30 incomplete task acceptance or completion")
        if row["checksum"] != row["count"] * 60:
            raise ValueError("P30 inconsistent worker-side checksum")
        if row["attempts"] < row["accepted"]:
            raise ValueError("P30 fewer attempts than accepted tasks")
        if any(row[key] <= 0 for key in TIMES):
            raise ValueError("P30 zero/nonpositive monotonic interval")
        discrepancy = abs(sum(row[t] for t in TIMES[:3]) - row["total_ns"])
        # MonoTime/Duration conversions can round independent intervals
        # to target time units separately. 1 microsecond is a rounding
        # tolerance, NOT a tolerance for differing task semantics.
        if discrepancy > 1_000:
            raise ValueError(
                f"P30 phase totals inconsistent by {discrepancy} ns: {row}"
            )
        key = (row["phase"], row["round"])
        pair = pairs.setdefault(key, {})
        if row["mode"] in pair:
            raise ValueError(f"P30 duplicate mode {key}:{row['mode']}")
        pair[row["mode"]] = row
    if not pairs:
        raise ValueError("P30 no paired CSV samples")
    measurements = []
    for key, modes in sorted(pairs.items()):
        if set(modes) != set(MODES):
            raise ValueError(f"P30 incomplete mode set: {key} {list(modes)}")
        base = modes["m0"]
        dimensions = (
            "count", "workers", "producers", "ingress", "retained",
            "accepted", "completed", "checksum",
        )
        for mode in MODES[1:]:
            if any(base[col] != modes[mode][col] for col in dimensions):
                raise ValueError(f"P30 same-work violation: {key}/{mode}")
        if key[0] == "measure":
            measurements.append(modes)
    if len(measurements) < min_rounds:
        raise ValueError(f"P30 fewer than {min_rounds} measured triplets")
    return measurements


def summarize(measured):
    report = {
        "diagnostic_only": True,
        "measured_triplets": len(measured),
        "dimensions": {key: measured[0]["m0"][key] for key in
                       ("count", "workers", "producers", "ingress", "retained")},
        "modes": {},
        "paired_ratios": {},
    }
    for mode in MODES:
        report["modes"][mode] = {}
        for field in (*TIMES, "attempts", "producer_alloc_bytes"):
            vals = [sample[mode][field] for sample in measured]
            report["modes"][mode][field] = {
                "median": statistics.median(vals),
                "minimum": min(vals),
                "maximum": max(vals),
            }
    for compared, baseline in (("managed", "deferred"), ("managed", "m0"),
                               ("deferred", "m0")):
        key = f"{compared}_over_{baseline}"
        report["paired_ratios"][key] = {
            field: statistics.median([
                sample[compared][field] / sample[baseline][field]
                for sample in measured
            ])
            for field in TIMES
        }
    return report


def self_test():
    import io
    rows = [",".join(FIELDS)]
    for rnd in range(3):
        for m, k in (("m0", 1), ("deferred", 2), ("managed", 3)):
            rows.append(",".join(map(str, [
                "measure", rnd, m, 64, 2, 2, 32, 128, 64, 64, 3840,
                70, 2000, k * 100, k * 200, k * 50, k * 350,
            ])))
    valid = "\n".join(rows) + "\n"
    x = summarize(validate(io.StringIO(valid), 3))
    if x["paired_ratios"]["managed_over_deferred"]["submit_ns"] != 1.5:
        raise ValueError("P30 median ratio self-test failed")
    try:
        validate(io.StringIO(valid.replace(",3840,", ",3839,", 1)), 3)
    except ValueError:
        pass
    else:
        raise ValueError("P30 invalid checksum was accepted")
    # Allow a bounded conversion difference, but reject mismatched
    # timestamps rather than quietly analyzing incoherent phases.
    near = valid.replace(",350\n", ",600\n", 1)
    validate(io.StringIO(near), 3)
    far = valid.replace(",350\n", ",5350\n", 1)
    if far == valid:
        raise ValueError("P30 timing-negative fixture was not mutated")
    try:
        validate(io.StringIO(far), 3)
    except ValueError:
        pass
    else:
        raise ValueError("P30 inconsistent timing passed self-test")
    print("P30_ANALYZER_SELFTEST_PASS")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", type=Path)
    p.add_argument("--min-rounds", type=int, default=3)
    p.add_argument("--json", type=Path)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        self_test()
        return
    if args.input is None:
        p.error("--input is required")
    with args.input.open(newline="") as stream:
        report = summarize(validate(stream, args.min_rounds))
    print("P30_SAME_WORK_PASS rounds=" + str(report["measured_triplets"]))
    print("P30_DIAGNOSTIC_ONLY " + json.dumps(report, sort_keys=True))
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
