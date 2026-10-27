#!/usr/bin/env python3
"""Summarize end-to-end benchmark CSV without adding a data-science dependency."""
import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path
import statistics


def nearest_rank(values, percentile):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_file", type=Path)
    parser.add_argument("--workload")
    parser.add_argument("--workers", type=int)
    args = parser.parse_args()

    with args.csv_file.open(newline="") as source:
        reader = csv.DictReader(source)
        required = {"phase", "sample", "workload", "arm", "workers", "batch_size",
                    "elapsed_ns", "ns_per_chunk", "chunks_per_second"}
        if not required.issubset(reader.fieldnames or ()):
            raise SystemExit("CSV is missing required benchmark columns")
        rows = [row for row in reader if row["phase"] == "measure"]

    if args.workload:
        rows = [row for row in rows if row["workload"] == args.workload]
    if args.workers:
        rows = [row for row in rows if int(row["workers"]) == args.workers]
    if not rows:
        raise SystemExit("no measured rows matched the requested filters")

    grouped = defaultdict(list)
    paired = defaultdict(dict)
    for row in rows:
        key = (row["workload"], int(row["workers"]), int(row["batch_size"]), row["arm"])
        grouped[key].append(row)
        session = row.get("session", "")
        pair_key = (session, row["workload"], int(row["workers"]),
                    int(row["batch_size"]), int(row["sample"]))
        paired[pair_key][row["arm"]] = int(row["elapsed_ns"])

    summaries = []
    for (workload, workers, batch_size, arm), samples in sorted(grouped.items()):
        elapsed = [int(row["elapsed_ns"]) for row in samples]
        per_chunk = [int(row["ns_per_chunk"]) for row in samples]
        throughput = [float(row["chunks_per_second"]) for row in samples]
        summaries.append({
            "workload": workload,
            "workers": workers,
            "batch_size": batch_size,
            "arm": arm,
            "samples": len(samples),
            "elapsed_ns": {
                "p50": int(nearest_rank(elapsed, 0.50)),
                "p95": int(nearest_rank(elapsed, 0.95)),
                "p99": int(nearest_rank(elapsed, 0.99)),
            },
            "median_ns_per_chunk": int(statistics.median(per_chunk)),
            "median_chunks_per_second": statistics.median(throughput),
        })

    ratios = defaultdict(list)
    comparison_arms = (("concurrency", "phobos"), ("parallelFor", "phobos"),
                       ("parallelForReused", "phobosReused"),
                       ("dynamicForReused", "phobosReused"),
                       ("dynamicForReused", "parallelForReused"),
                       ("parallelForAdaptiveReused", "phobosReused"),
                       ("parallelForAdaptiveReused", "parallelForReused"),
                       ("parallelForAdaptiveReused", "dynamicForReused"))
    for (_, workload, workers, batch_size, _), arms in paired.items():
        for arm, reference in comparison_arms:
            if arm in arms and reference in arms:
                ratios[(workload, workers, batch_size, arm, reference)].append(
                    arms[arm] / arms[reference])
    comparisons = [{
        "workload": workload,
        "workers": workers,
        "batch_size": batch_size,
        "arm": arm,
        "reference": reference,
        "paired_samples": len(values),
        "elapsed_ratio": {
            "p50": round(nearest_rank(values, 0.50), 4),
            "p95": round(nearest_rank(values, 0.95), 4),
            "p99": round(nearest_rank(values, 0.99), 4),
        },
    } for (workload, workers, batch_size, arm, reference), values in sorted(ratios.items())]

    print(json.dumps({"input": str(args.csv_file), "summaries": summaries,
                      "paired_comparisons": comparisons}, indent=2))


if __name__ == "__main__":
    main()
