#!/usr/bin/env python3
"""P18 separate event-only M0/grace oracle. Trace timings NEVER rank speed."""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median
import tempfile

WORK = ("phase", "round", "order", "seed", "workers", "count",
        "waves", "iterations", "ingress", "checksum")
STAGES = ("prepare_ns", "pool_start_ns", "waves_ns", "join_ns", "verify_ns")
EVENTS = ("grace_searches", "grace_recovered_local",
          "grace_recovered_inbox", "grace_recovered_steal",
          "grace_fallbacks", "grace_drain_exits", "steal_attempts",
          "steal_successes", "park_attempts", "park_waits",
          "park_no_outstanding", "park_with_outstanding", "batch_claims",
          "batch_tasks", "local_hits", "local_misses", "min_worker_tasks",
          "max_worker_tasks")
GRACE = EVENTS[:6]


def load(path):
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if not rows or not set(WORK + STAGES + EVENTS +
                           ("total_ns", "retries", "park_count")).issubset(rows[0]):
        raise ValueError(f"invalid trace fields: {path}")
    return rows


def compare(left, right, minimum):
    a, b = load(left), load(right)
    if len(a) != len(b) or len(a) < minimum:
        raise ValueError("P18 trace missing/unequal result rows")
    sampled = defaultdict(lambda: defaultdict(list))
    for rownum, (control, grace) in enumerate(zip(a, b)):
        if any(control[k] != grace[k] for k in WORK):
            raise ValueError(f"P18 trace unmatched TaskRef oracle at row {rownum}")
        for mode, record in (("control", control), ("grace", grace)):
            stages = [int(record[k]) for k in STAGES]
            if min(stages) < 0 or sum(stages) != int(record["total_ns"]) or (
                int(record["waves_ns"]) <= 0 or int(record["park_count"]) < 0 or
                int(record["retries"]) < 0):
                raise ValueError(f"P18 trace invalid measured stages at {rownum}")
            v = {key: int(record[key]) for key in EVENTS}
            tasks = int(record["count"]) * int(record["waves"])
            workers = int(record["workers"])
            if (min(v.values()) < 0 or
                v["batch_tasks"] != tasks or
                v["steal_successes"] > v["steal_attempts"] or
                v["park_waits"] != int(record["park_count"]) or
                v["park_no_outstanding"] + v["park_with_outstanding"] !=
                    v["park_waits"] or
                v["park_attempts"] < v["park_waits"] or
                v["local_hits"] + v["steal_successes"] > tasks or
                v["batch_claims"] > tasks or
                not (0 <= v["min_worker_tasks"] <= v["max_worker_tasks"] <= tasks) or
                v["min_worker_tasks"] * workers > tasks or
                v["max_worker_tasks"] * workers < tasks):
                raise ValueError(f"P18 trace event conservation failed at {rownum}")
            if mode == "control" and any(v[k] != 0 for k in GRACE):
                raise ValueError(f"P18 original M0 recorded grace at row {rownum}")
            if (v["grace_searches"] !=
                v["grace_recovered_local"] + v["grace_recovered_inbox"] +
                v["grace_recovered_steal"] + v["grace_fallbacks"] +
                v["grace_drain_exits"]):
                raise ValueError(f"P18 grace search conservation failed at {rownum}")
            if record["phase"] == "measure":
                key = tuple(int(record[k]) for k in
                            ("workers", "iterations", "ingress"))
                for event in EVENTS:
                    sampled[key][mode + "_" + event].append(v[event])
                sampled[key][mode + "_failed_steals"].append(
                    v["steal_attempts"] - v["steal_successes"])
        # No traced timing comparisons: instrumentation alters scheduling.
    if not sampled:
        raise ValueError("P18 trace lacks measured cases")
    for key, ev in sorted(sampled.items()):
        def m(label):
            return median(ev[label])
        print(f"P18 TRACE DIAGNOSTIC workers={key[0]} iterations={key[1]} "
              f"ingress={key[2]} grace_retries={m('grace_grace_searches'):.1f} "
              f"grace_recovered_local/inbox/steal="
              f"{m('grace_grace_recovered_local'):.1f}/"
              f"{m('grace_grace_recovered_inbox'):.1f}/"
              f"{m('grace_grace_recovered_steal'):.1f} "
              f"grace_failed={m('grace_grace_fallbacks'):.1f} "
              f"grace_drained={m('grace_grace_drain_exits'):.1f} "
              f"failed_steals_M0/grace="
              f"{m('control_failed_steals'):.1f}/"
              f"{m('grace_failed_steals'):.1f} "
              f"park_no_outstanding_M0/grace="
              f"{m('control_park_no_outstanding'):.1f}/"
              f"{m('grace_park_no_outstanding'):.1f} "
              f"n={len(ev['grace_grace_searches'])}")
    print(f"P18 TRACE PASS equal-work event invariants rows={len(a)} "
          f"cases={len(sampled)}; TRACE TIMINGS NOT SPEED EVIDENCE")


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        a, b = root / "a.csv", root / "b.csv"
        header = list(WORK) + list(STAGES) + ["total_ns", "retries", "park_count"] + list(EVENTS)
        baseline = dict(zip(header, [0] * len(header)))
        baseline.update(phase="measure", round=0, order=0, seed=1,
                        workers=1, count=2, waves=1, iterations=512,
                        ingress=8, checksum=123, prepare_ns=10,
                        pool_start_ns=10, waves_ns=80, join_ns=10,
                        verify_ns=10, total_ns=120, park_count=0,
                        batch_tasks=2, batch_claims=1,
                        min_worker_tasks=2, max_worker_tasks=2)
        changed = baseline.copy()
        changed.update(grace_searches=3, grace_recovered_inbox=1,
                       grace_fallbacks=2)
        for path, row in ((a, baseline), (b, changed)):
            with path.open("w", newline="") as out:
                writer = csv.DictWriter(out, fieldnames=header)
                writer.writeheader()
                writer.writerow(row)
        compare(a, b, 1)
        changed["grace_searches"] = 4
        with b.open("w", newline="") as out:
            writer = csv.DictWriter(out, fieldnames=header)
            writer.writeheader()
            writer.writerow(changed)
        try:
            compare(a, b, 1)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted broken grace event conservation")
    print("P18 TRACE synthetic validator PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("control", nargs="?", type=Path)
    parser.add_argument("grace", nargs="?", type=Path)
    parser.add_argument("--min-rows", type=int, default=54)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.control is None or args.grace is None:
            parser.error("control and grace paths required")
        compare(args.control, args.grace, args.min_rows)


if __name__ == "__main__":
    main()
