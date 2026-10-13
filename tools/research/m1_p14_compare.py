#!/usr/bin/env python3
"""Compare P14 exact same-work control and instrumented M0 CSV.

Requires equal row-by-row order, task shape, seed and checksums.
Events describe the traced run, not the control run. CI timings are
DIAGNOSTIC ONLY; instrumentation overhead must be remeasured on XPS.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

KEYS = (
    "phase", "round", "order", "seed", "workers", "count",
    "waves", "iterations", "ingress",
)
EVENTS = (
    "full_submits", "accepted_submits", "submit_signals",
    "local_signals", "complete_calls", "final_signals",
    "close_signals", "park_waits", "local_hits", "local_misses",
    "batch_attempts", "batch_claims", "batch_tasks", "local_pushes",
    "local_push_failures", "steal_attempts", "steal_successes",
    "park_attempts", "executed", "worker_count",
    *(f"worker{i}_executed" for i in range(16)),
)

def read(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as file:
        rows = list(csv.DictReader(file))
    if not rows:
        raise ValueError(f"P14 empty CSV: {path}")
    if not set(KEYS + EVENTS + ("checksum", "waves_ns")).issubset(rows[0]):
        raise ValueError(f"P14 wrong CSV header: {path}")
    return rows

def compare(control_path: Path, trace_path: Path, min_rows: int) -> None:
    original = read(control_path)
    traced = read(trace_path)
    if len(original) != len(traced) or len(original) < min_rows:
        raise ValueError("P14 control and trace do not have the same row count")
    overhead = defaultdict(list)
    steals = defaultdict(list)
    worker_spreads = defaultdict(list)
    total_trace_tasks = 0
    for index, (plain, trace) in enumerate(zip(original, traced)):
        context = f"row {index}: "
        for key in KEYS + ("checksum",):
            if plain[key] != trace[key]:
                raise ValueError(context + f"{key} mismatch: {plain[key]} != {trace[key]}")
        if any(int(plain[field]) != 0 for field in EVENTS):
            raise ValueError(context + "uninstrumented control emitted events")
        if int(plain["checksum"]) != int(trace["checksum"]):
            raise ValueError(context + "different arithmetic results")
        total = int(trace["count"]) * int(trace["waves"])
        total_trace_tasks += total
        if any(int(trace[field]) != total for field in
               ("accepted_submits", "submit_signals", "complete_calls",
                "batch_tasks", "executed")):
            raise ValueError(context + "traced task conservation wrong")
        if int(trace["full_submits"]) != int(trace["retries"]):
            raise ValueError(context + "producer/backpressure mismatch")
        if int(trace["park_waits"]) != int(trace["park_count"]):
            raise ValueError(context + "park count mismatch")
        if int(trace["local_pushes"]) != (
            int(trace["local_hits"]) + int(trace["steal_successes"])
        ):
            raise ValueError(context + "deque conservation mismatch")
        if int(trace["executed"]) != (
            int(trace["local_hits"]) + int(trace["steal_successes"]) +
            int(trace["batch_claims"]) + int(trace["local_push_failures"])
        ):
            raise ValueError(context + "execution provenance mismatch")
        if int(trace["steal_successes"]) > int(trace["steal_attempts"]):
            raise ValueError(context + "steal accounting mismatch")

        worker_count = int(trace["worker_count"])
        if worker_count != int(trace["workers"]) or not 1 <= worker_count <= 16:
            raise ValueError(context + "incorrect worker distribution shape")
        workers = [int(trace[f"worker{i}_executed"]) for i in range(16)]
        if sum(workers) != total or any(workers[worker_count:]):
            raise ValueError(context + "per-worker completion total mismatch")

        ctrl_time = int(plain["waves_ns"])
        trace_time = int(trace["waves_ns"])
        if ctrl_time <= 0 or trace_time <= 0:
            raise ValueError(context + "nonpositive wave duration")
        if plain["phase"] == "measure":
            key = (int(trace["workers"]), int(trace["iterations"]),
                   int(trace["ingress"]))
            overhead[key].append(trace_time / ctrl_time)
            worker_spreads[key].append((min(workers[:worker_count]),
                                        max(workers[:worker_count])))
            steals[key].append(
                (int(trace["steal_successes"]), int(trace["steal_attempts"]),
                 int(trace["batch_claims"]), int(trace["park_waits"])))
    if not overhead:
        raise ValueError("P14 no measured rows")
    for key, samples in sorted(overhead.items()):
        successes = sum(x[0] for x in steals[key])
        attempts = sum(x[1] for x in steals[key])
        claims = sum(x[2] for x in steals[key])
        parks = sum(x[3] for x in steals[key])
        min_work = int(median(x[0] for x in worker_spreads[key]))
        max_work = int(median(x[1] for x in worker_spreads[key]))
        print(f"P14 CI-DIAGNOSTIC workers={key[0]} iters={key[1]} "
              f"ingress={key[2]} trace/control-wave median={median(samples):.3f} "
              f"stolen={successes} attempts={attempts} "
              f"claimed_batches={claims} park_waits={parks} "
              f"per_worker_min_max_medians={min_work}/{max_work} n={len(samples)}")
    print(f"P14 PASS identical scenario/checksum order, trace conservation: "
          f"rows={len(original)}, logical_tasks_per_arm={total_trace_tasks}, "
          f"configurations={len(overhead)}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("control", type=Path)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--min-rows", type=int, default=4)
    args = parser.parse_args()
    compare(args.control, args.trace, args.min_rows)

if __name__ == "__main__":
    main()
