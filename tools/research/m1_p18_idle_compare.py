#!/usr/bin/env python3
"""P18 independent no-task idle CPU-time oracle; NOT a power/energy benchmark.

Reject mismatched experimental work or invalid timing. Report per-process
CPU-time / wall-time occupancy and paired differences (not ratios of near-zero
CPU times). Measurements on shared CI are correctness smoke ONLY.
"""
import argparse
import csv
from pathlib import Path
from statistics import median
import tempfile

COLUMNS = ("phase", "workers", "round", "settle_ms", "hold_ms",
           "wall_ns", "process_cpu_ns", "parks_before", "parks_after",
           "accepted", "completed")


def parse(path):
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames != list(COLUMNS):
            raise ValueError(f"{path}: invalid idle CSV schema")
        records = list(reader)
    if not records:
        raise ValueError(f"{path}: empty idle CSV")
    keyed = {}
    for rec in records:
        if rec["phase"] != "measure":
            raise ValueError(f"{path}: unexpected phase")
        values = {k: int(v) for k, v in rec.items() if k != "phase"}
        if (values["workers"] not in (1, 2, 4) or
            values["round"] < 0 or
            values["settle_ms"] < 20 or values["hold_ms"] < 20 or
            values["wall_ns"] <= 0 or values["process_cpu_ns"] < 0 or
            values["parks_before"] < 0 or
            values["parks_after"] < values["parks_before"] or
            values["accepted"] != 0 or values["completed"] != 0):
            raise ValueError(f"{path}: impossible no-task idle observation")
        key = values["workers"], values["round"]
        if key in keyed:
            raise ValueError(f"{path}: duplicate {key}")
        keyed[key] = values
    return keyed


def compare(control, grace, minimum=3):
    a, b = parse(control), parse(grace)
    if len(a) != len(b) or len(a) < minimum or set(a) != set(b):
        raise ValueError("P18 idle control/grace sample count or key mismatch")
    if {key[0] for key in a} != {1, 2, 4}:
        raise ValueError("P18 idle missing worker count")
    observed_rounds = {key[1] for key in a}
    if observed_rounds != set(range(len(observed_rounds))) or (
        len(a) != 3 * len(observed_rounds)):
        raise ValueError("P18 idle incomplete worker/round matrix")
    metrics = {w: {"original": [], "grace": [], "delta": [],
                   "control_parks": [], "grace_parks": []}
               for w in (1, 2, 4)}
    for key in sorted(a):
        left, right = a[key], b[key]
        if (left["hold_ms"] != right["hold_ms"] or
            left["settle_ms"] != right["settle_ms"]):
            raise ValueError(f"P18 idle nonidentical work at {key}")
        w = key[0]
        control_load = left["process_cpu_ns"] / left["wall_ns"]
        grace_load = right["process_cpu_ns"] / right["wall_ns"]
        metrics[w]["original"].append(control_load)
        metrics[w]["grace"].append(grace_load)
        metrics[w]["delta"].append(grace_load - control_load)
        metrics[w]["control_parks"].append(
            left["parks_after"] - left["parks_before"])
        metrics[w]["grace_parks"].append(
            right["parks_after"] - right["parks_before"])
    for w, v in sorted(metrics.items()):
        print(f"P18 IDLE DIAGNOSTIC workers={w} "
              f"original_cpu_ms_per_wall_s={1000*median(v['original']):.6f} "
              f"grace_cpu_ms_per_wall_s={1000*median(v['grace']):.6f} "
              f"paired_delta_cpu_ms_per_wall_s={1000*median(v['delta']):+.6f} "
              f"parks_original/grace={median(v['control_parks']):.1f}/"
              f"{median(v['grace_parks']):.1f} n={len(v['delta'])}")
    print(f"P18 IDLE PASS zero TaskRefs; matching worker/round/idle intervals "
          f"rows={len(a)}")
    return metrics


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        a, b = root / "a.csv", root / "b.csv"
        header = ",".join(COLUMNS) + "\n"
        a.write_text(header + "".join(
            f"measure,{w},0,60,80,81000000,100000,1,1,0,0\n"
            for w in (1, 2, 4)))
        b.write_text(header + "".join(
            f"measure,{w},0,60,80,82000000,150000,2,2,0,0\n"
            for w in (1, 2, 4)))
        assert len(compare(a, b)) == 3
        b.write_text(b.read_text().replace(",0,0\n", ",1,0\n", 1))
        try:
            compare(a, b)
        except ValueError:
            pass
        else:
            raise AssertionError("P18 idle oracle accepted one TaskRef")
    print("P18 idle comparator self-test PASS")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("control", type=Path, nargs="?")
    p.add_argument("grace", type=Path, nargs="?")
    p.add_argument("--min-rows", type=int, default=3)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.control is None or args.grace is None:
            p.error("control and grace CSV files required")
        compare(args.control, args.grace, args.min_rows)
