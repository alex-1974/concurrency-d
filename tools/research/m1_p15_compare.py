#!/usr/bin/env python3
"""P15 control-vs-timed M0 comparison: exact work, checked lock call counts.

Timing probes are invasive: timestamp work is INSIDE the mutex.
No throughput threshold, no attribution of summed CPU-thread wait ns to
wall-clock ns, and no subtraction of an assumed per-clock calibration.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

KEYS = ("phase", "round", "order", "seed", "workers", "count",
        "waves", "iterations", "ingress", "checksum")
SITES = ("submit", "batch", "complete", "generation", "local_signal")
FIELDS = ("calls", "wait_ns", "hold_ns", "max_wait_ns", "max_hold_ns")

def load(path):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ValueError(f"P15 no CSV records in {path}")
    required = set(KEYS) | {f"{s}_{f}" for s in SITES for f in FIELDS}
    if not required.issubset(rows[0]):
        raise ValueError(f"P15 malformed CSV columns in {path}: {required - set(rows[0])}")
    return rows

def compare(control, timed, minimum):
    left, right = load(control), load(timed)
    if len(left) != len(right) or len(left) < minimum:
        raise ValueError("P15 missing control/timed rows")
    ratios = defaultdict(list)
    metrics = defaultdict(lambda: defaultdict(list))
    measured = 0
    for i, (a, b) in enumerate(zip(left, right)):
        for key in KEYS:
            if a[key] != b[key]:
                raise ValueError(f"P15 row={i} mismatch in {key}: {a[key]} != {b[key]}")
        for key in ("retries", "park_count"):
            if int(a[key]) < 0 or int(b[key]) < 0:
                raise ValueError(f"P15 row={i} negative {key}")
        count = int(b["count"]) * int(b["waves"])
        for site in SITES:
            a_fields = [int(a[f"{site}_{field}"]) for field in FIELDS]
            b_fields = [int(b[f"{site}_{field}"]) for field in FIELDS]
            if any(a_fields) or any(x < 0 for x in b_fields):
                raise ValueError(f"P15 row={i} invalid control/timed {site} events")
            calls, wait, hold, maximum_wait, maximum_hold = b_fields
            if calls and (maximum_wait > wait or maximum_hold > hold):
                raise ValueError(f"P15 row={i} impossible max time at {site}")
            if calls == 0 and any((wait, hold, maximum_wait, maximum_hold)):
                raise ValueError(f"P15 row={i} time without calls at {site}")
            if site == "submit" and calls != count + int(b["retries"]):
                raise ValueError(f"P15 row={i} submit vs retries mismatch")
            if site == "complete" and calls != count:
                raise ValueError(f"P15 row={i} completion accounting loss")
            if site == "batch" and calls == 0:
                raise ValueError(f"P15 row={i} no inbox batch drain")
            if b["phase"] == "measure" and calls > 0:
                k = (int(b["workers"]), int(b["iterations"]), int(b["ingress"]))
                metrics[k][site + "_wait_per_call_ns"].append(wait / calls)
                metrics[k][site + "_hold_per_call_ns"].append(hold / calls)
        if int(b["waves_ns"]) <= 0 or int(a["waves_ns"]) <= 0:
            raise ValueError(f"P15 row={i} invalid elapsed waves")
        if b["phase"] == "measure":
            measured += 1
            key = (int(b["workers"]), int(b["iterations"]), int(b["ingress"]))
            ratios[key].append(int(b["waves_ns"]) / int(a["waves_ns"]))
    if not measured:
        raise ValueError("P15 missing measured profiles")

    for k, values in sorted(ratios.items()):
        observed = metrics[k]
        print(f"P15 CI-DIAGNOSTIC workers={k[0]} iterations={k[1]} "
              f"ingress={k[2]} timed/control median={median(values):.3f} "
              f"submit_wait_per_call_ns={median(observed['submit_wait_per_call_ns']):.1f} "
              f"complete_wait_per_call_ns={median(observed['complete_wait_per_call_ns']):.1f} "
              f"complete_hold_per_call_ns={median(observed['complete_hold_per_call_ns']):.1f} "
              f"samples={len(values)}")
    print(f"P15 PASS exact control/timed workload/checksum and lock-call "
          f"conservation: rows={len(left)} measured={measured} cases={len(ratios)}")

def main():
    args = argparse.ArgumentParser()
    args.add_argument("control", type=Path)
    args.add_argument("timed", type=Path)
    args.add_argument("--min-rows", type=int, default=6)
    options = args.parse_args()
    compare(options.control, options.timed, options.min_rows)

if __name__ == "__main__":
    main()
