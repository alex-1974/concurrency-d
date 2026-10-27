#!/usr/bin/env python3
"""Summarize paired bounded-streaming benchmark CSV captures."""
import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


def percentile(values, p):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(p * len(ordered)) - 1)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_file", type=Path)
    args = parser.parse_args()

    required = {
        "phase", "sample", "arm", "workers", "producers",
        "in_flight_capacity", "batch_size", "producer_wall_ns", "shutdown_ns",
        "shutdown_drain_ns", "total_ns", "producer_wait_ns",
        "submit_p50_ns", "task_latency_p50_ns", "task_latency_p95_ns",
        "task_latency_p99_ns",
    }
    with args.csv_file.open(newline="") as source:
        reader = csv.DictReader(source)
        if not required.issubset(reader.fieldnames or ()):
            raise SystemExit("CSV is missing required streaming benchmark columns")
        rows = [row for row in reader if row["phase"] == "measure"]
    if not rows:
        raise SystemExit("CSV contains no measured rows")

    groups = defaultdict(list)
    pairs = defaultdict(dict)
    for row in rows:
        key = (int(row["workers"]), int(row["producers"]),
               int(row["in_flight_capacity"]), int(row["batch_size"]),
               row.get("work_size", "small"), row["arm"])
        groups[key].append(row)
        pair = (row.get("session", ""), row["sample"], key[:5])
        pairs[pair][row["arm"]] = int(row["producer_wall_ns"])

    summaries = []
    for (workers, producers, capacity, batch_size, work_size, arm), samples in sorted(groups.items()):
        def med(field):
            return int(statistics.median(int(row[field]) for row in samples))

        summaries.append({
            "workers": workers,
            "producers": producers,
            "in_flight_capacity": capacity,
            "batch_size": batch_size,
            "work_size": work_size,
            "arm": arm,
            "samples": len(samples),
            "producer_wall_ns_p50": med("producer_wall_ns"),
            "total_ns_p50": med("total_ns"),
            "shutdown_ns_p50": med("shutdown_ns"),
            "shutdown_drain_ns_p50": med("shutdown_drain_ns"),
            "producer_wait_ns_p50": med("producer_wait_ns"),
            "submit_p50_ns_p50": med("submit_p50_ns"),
            "task_latency_ns": {
                p: med(f"task_latency_{p}_ns") for p in ("p50", "p95", "p99")
            },
        })

    ratios = defaultdict(list)
    for (_, _, dimensions), arms in pairs.items():
        if "concurrency" in arms and "phobos" in arms:
            ratios[dimensions].append(arms["concurrency"] / arms["phobos"])
    comparisons = [{
        "workers": workers,
        "producers": producers,
        "in_flight_capacity": capacity,
        "batch_size": batch_size,
        "work_size": work_size,
        "paired_samples": len(values),
        "concurrency_over_phobos_producer_wall_ratio": {
            "p50": round(percentile(values, 0.50), 4),
            "p95": round(percentile(values, 0.95), 4),
            "p99": round(percentile(values, 0.99), 4),
        },
    } for (workers, producers, capacity, batch_size, work_size), values in sorted(ratios.items())]

    print(json.dumps({"input": str(args.csv_file), "summaries": summaries,
                      "paired_comparisons": comparisons}, indent=2))


if __name__ == "__main__":
    main()
