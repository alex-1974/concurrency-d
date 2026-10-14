#!/usr/bin/env python3
"""Validate source-pinned P18 phase-boundary records. No speed acceptance.

The phase instrumenter adds a few timestamps per wave; its measured wave
timings are not the uninstrumented original-M0/P18 performance baseline.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median
import tempfile

from m1_p18_compare import KEY, STAGES

PHASES = ("first_accept_ns", "submit_span_ns", "completion_wait_ns",
          "phase_residual_ns")
EXTRA = PHASES + ("completed_at_submit",)
CASES = {(1, iteration, cap)
         for iteration in (128, 512, 1024)
         for cap in (8, 64, 256, 2048)}


def read(path):
    with path.open(newline="") as stream:
        rd = csv.DictReader(stream)
        need = set(KEY + STAGES + EXTRA +
                   ("total_ns", "retries", "park_count"))
        if not rd.fieldnames or not need.issubset(rd.fieldnames):
            raise ValueError(f"P18 phase fields missing in {path}")
        rows = list(rd)
    if not rows:
        raise ValueError(f"P18 empty phase rows {path}")
    return rows


def compare(original, grace, minimum, count, waves):
    left = read(original)
    right = read(grace)
    if len(left) != len(right) or len(left) < minimum:
        raise ValueError("P18 phase rows mismatch or incomplete")
    summaries = defaultdict(lambda: defaultdict(list))
    paired = defaultdict(lambda: defaultdict(list))
    for index, (a, b) in enumerate(zip(left, right)):
        if any(a[key] != b[key] for key in KEY):
            raise ValueError(f"P18 phase changed TaskRef/seed/order at {index}")
        for arm, rec in (("M0", a), ("P18", b)):
            try:
                timings = [int(rec[key]) for key in STAGES]
                phases = [int(rec[key]) for key in PHASES]
                completed = int(rec["completed_at_submit"])
                total = int(rec["total_ns"])
                n = int(rec["count"])
                number_of_waves = int(rec["waves"])
                retries = int(rec["retries"])
                parks = int(rec["park_count"])
                key = (int(rec["workers"]), int(rec["iterations"]),
                       int(rec["ingress"]))
            except (ValueError, KeyError) as exc:
                raise ValueError(f"P18 phase malformed field at {index}") from exc
            if (n != count or number_of_waves != waves or key not in CASES or
                min(timings + phases + [retries, parks, completed]) < 0 or
                sum(timings) != total or
                timings[2] <= 0 or
                sum(phases) != timings[2] or
                completed > count * waves):
                raise ValueError(f"P18 phase conservation failed: {arm} row {index}")
            if key[2] >= count and retries:
                raise ValueError(f"P18 phase retry at no-full capacity: {index}")
            if rec["phase"] == "measure":
                for field in EXTRA:
                    summaries[key][arm + "_" + field].append(int(rec[field]))
                summaries[key][arm + "_retries"].append(retries)
        if a["phase"] == "measure":
            for field in EXTRA:
                paired[key][field].append(int(b[field]) - int(a[field]))
            # The numerator is the sum over waves of acquired counts.
            # Percentage points, not timing, and no independent session claim.
            denom = count * waves
            paired[key]["overlap_delta_pp"].append(
                100.0 * (int(b["completed_at_submit"]) -
                         int(a["completed_at_submit"])) / denom)
    if set(summaries) != CASES:
        raise ValueError("P18 phase missing one-worker iteration/ingress cells")
    for (worker, iteration, ingress), fields in sorted(summaries.items()):
        def m(arm, name):
            return median(fields[arm + "_" + name])
        print(f"P18 PHASE OBSERVATION workers={worker} iterations={iteration} "
              f"ingress={ingress} "
              f"first_accept_ns_M0/P18="
              f"{m('M0','first_accept_ns'):.0f}/{m('P18','first_accept_ns'):.0f} "
              f"submit_span_ns_M0/P18="
              f"{m('M0','submit_span_ns'):.0f}/{m('P18','submit_span_ns'):.0f} "
              f"completion_wait_ns_M0/P18="
              f"{m('M0','completion_wait_ns'):.0f}/{m('P18','completion_wait_ns'):.0f} "
              f"completed_at_submit_M0/P18="
              f"{m('M0','completed_at_submit'):.0f}/"
              f"{m('P18','completed_at_submit'):.0f} "
              f"retries_M0/P18="
              f"{m('M0','retries'):.0f}/{m('P18','retries'):.0f} "
              f"paired_delta_submit_span_ns="
              f"{median(paired[(worker,iteration,ingress)]['submit_span_ns']):+.0f} "
              f"paired_delta_completion_wait_ns="
              f"{median(paired[(worker,iteration,ingress)]['completion_wait_ns']):+.0f} "
              f"paired_delta_completed_at_submit="
              f"{median(paired[(worker,iteration,ingress)]['completed_at_submit']):+.0f} "
              f"paired_delta_completed_fraction_pp="
              f"{median(paired[(worker,iteration,ingress)]['overlap_delta_pp']):+.3f} "
              f"n={len(fields['M0_first_accept_ns'])}")
    print(f"P18 PHASE PASS exact TaskRef, stage + phase conservation "
          f"rows={len(left)} measured_cells={len(summaries)} "
          "PHASE-BOUNDARY OBSERVATIONS ARE NOT UNINSTRUMENTED SPEED")


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        a = Path(tmp) / "a.csv"
        b = Path(tmp) / "b.csv"
        names = (list(KEY) + list(STAGES) +
                 ["total_ns", "retries", "park_count"] + list(EXTRA))
        base = {field: "0" for field in names}
        base.update(phase="measure", round="0", order="0", seed="10",
                    workers="1", count="16", waves="2", iterations="512",
                    ingress="8", checksum="123", prepare_ns="5",
                    pool_start_ns="4", waves_ns="100", join_ns="3",
                    verify_ns="2", total_ns="114", first_accept_ns="6",
                    submit_span_ns="70", completion_wait_ns="22",
                    phase_residual_ns="2", completed_at_submit="25",
                    retries="4", park_count="1")
        for path in (a, b):
            with path.open("w", newline="") as stream:
                w = csv.DictWriter(stream, fieldnames=names)
                w.writeheader()
                for it in (128, 512, 1024):
                    for cap in (8, 64, 256, 2048):
                        base["iterations"] = str(it)
                        base["ingress"] = str(cap)
                        base["order"] = str(
                            (128, 512, 1024).index(it)*4
                            + (8, 64, 256, 2048).index(cap))
                        base["retries"] = "0" if cap >= 16 else "4"
                        w.writerow(base)
        compare(a, b, 12, 16, 2)
        with b.open(newline="") as stream:
            dr = csv.DictReader(stream)
            rows = list(dr)
        rows[0]["phase_residual_ns"] = "3"
        with b.open("w", newline="") as stream:
            w = csv.DictWriter(stream, fieldnames=names)
            w.writeheader()
            w.writerows(rows)
        try:
            compare(a, b, 12, 16, 2)
        except ValueError:
            pass
        else:
            raise AssertionError("bad phase conservation was accepted")
    print("P18 PHASE synthetic negative test PASS")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("control", type=Path, nargs="?")
    p.add_argument("grace", type=Path, nargs="?")
    p.add_argument("--min-rows", type=int, default=84)
    p.add_argument("--count", type=int, default=2048)
    p.add_argument("--waves", type=int, default=3)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.control is None or args.grace is None:
            p.error("requires control and grace")
        compare(args.control, args.grace, args.min_rows,
                args.count, args.waves)
