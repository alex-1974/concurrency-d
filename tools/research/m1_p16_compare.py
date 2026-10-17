#!/usr/bin/env python3
"""P16.1: verify same-work M0 control, null-clock and sampled completeOne.

No attempt to subtract null-clock average from sampled call duration:
sampled scheduling can differ across separate runs/processes.
CI timing numbers are diagnostic only, not speed gates.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

MATCH = ("phase", "round", "order", "seed", "workers", "count",
         "waves", "iterations", "ingress", "checksum")
FIELDS = ("sample_calls", "sample_count", "sample_sum_ns",
          "sample_max_ns", "sample_anomalies")

def load(path):
    with path.open(newline="") as h:
        rows = list(csv.DictReader(h))
    if not rows:
        raise ValueError(f"P16 empty CSV: {path}")
    if not set(MATCH + FIELDS + ("waves_ns", "retries")).issubset(rows[0]):
        raise ValueError(f"P16 malformed CSV: {path}")
    return rows

def compare(control, null_probe, measured, minimum):
    data = [load(x) for x in (control, null_probe, measured)]
    n = len(data[0])
    if any(len(x) != n for x in data) or n < minimum:
        raise ValueError("P16 incomplete control/null/sample case sequences")
    groups = defaultdict(lambda: defaultdict(list))
    completed = 0
    for i, triple in enumerate(zip(*data)):
        a, b, c = triple
        for field in MATCH:
            if a[field] != b[field] or a[field] != c[field]:
                raise ValueError(f"P16 row {i}: {field} differs among arms")
        if any(int(a[k]) for k in FIELDS):
            raise ValueError(f"P16 row {i}: baseline published probe data")
        task_count = int(a["count"]) * int(a["waves"])
        for tag, row in (("null", b), ("sample", c)):
            calls = int(row["sample_calls"])
            samples = int(row["sample_count"])
            duration = int(row["sample_sum_ns"])
            maximum = int(row["sample_max_ns"])
            anomalies = int(row["sample_anomalies"])
            workers = int(row["workers"])
            if (calls != task_count or anomalies != 0 or
                not 0 <= maximum <= duration or
                samples > task_count // 64 or
                samples < max(0, task_count // 64 - workers) or
                (samples == 0 and task_count >= 64 * workers)):
                raise ValueError(f"P16 row {i}: {tag} probe conservation failed")
            if int(row["waves_ns"]) <= 0:
                raise ValueError(f"P16 row {i}: nonpositive sampled wave time")
            if row["phase"] == "measure":
                key = (int(a["workers"]), int(a["iterations"]),
                       int(a["ingress"]))
                groups[key][tag + "_over_control"].append(
                    int(row["waves_ns"]) / int(a["waves_ns"])
                )
                if samples:
                    groups[key][tag + "_ns_per_sample"].append(
                        duration / samples
                    )
                groups[key][tag + "_n_samples"].append(samples)
        completed += task_count
    if not groups:
        raise ValueError("P16 missing measured profiles")
    for key, measures in sorted(groups.items()):
        counts = measures["sample_n_samples"]
        nulls = measures["null_n_samples"]
        print(f"P16 CI-DIAGNOSTIC workers={key[0]} iterations={key[1]} "
              f"ingress={key[2]} null/control="
              f"{median(measures['null_over_control']):.3f} "
              f"sample/control={median(measures['sample_over_control']):.3f} "
              f"clock_pair_ns={median(measures['null_ns_per_sample']) if measures['null_ns_per_sample'] else float('nan'):.1f} "
              f"complete_call_ns={median(measures['sample_ns_per_sample']) if measures['sample_ns_per_sample'] else float('nan'):.1f} "
              f"median_samples={median(counts):.1f}/null_{median(nulls):.1f} "
              f"n={len(counts)}")
    print(f"P16 correctness PASS baseline/null/sample matched "
          f"rows={n}, configurations={len(groups)}, "
          f"scheduled_tasks_per_three_arms={3*completed}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("control", type=Path)
    p.add_argument("null_clock", type=Path)
    p.add_argument("sample", type=Path)
    p.add_argument("--min-rows", type=int, default=6)
    args = p.parse_args()
    compare(args.control, args.null_clock, args.sample, args.min_rows)

if __name__ == "__main__":
    main()
