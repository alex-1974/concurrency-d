#!/usr/bin/env python3
"""P18 single-worker ingress capacity audit. No speed thresholds.

Ingress >= count means the producer can admit one complete wave without a
full-inbox rejection, independent of worker progress; the previous wave is
completed before the next begins. Does not claim the scheduler is unchanged:
inbox capacity is an intentional workload variable.
"""
import argparse
import csv
from pathlib import Path
import tempfile

ITERATIONS = (128, 512, 1024)
INGRESS = (8, 64, 256, 2048)
CELLS = {(1, it, cap) for it in ITERATIONS for cap in INGRESS}


def audit(path, count=2048, waves=3, warmup=2, rounds=5):
    with path.open(newline="") as source:
        reader = csv.DictReader(source)
        required = {"phase", "round", "order", "seed", "workers", "count",
                    "waves", "iterations", "ingress", "retries", "checksum"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise ValueError("P18 single-ingress CSV missing required columns")
        rows = list(reader)
    expected = len(CELLS) * (warmup + rounds)
    if len(rows) != expected:
        raise ValueError(f"P18 single-ingress row count {len(rows)} != {expected}")
    retry_by_cap = {c: 0 for c in INGRESS}
    all_seeds = set()
    for trial in range(warmup + rounds):
        phase = "warmup" if trial < warmup else "measure"
        current = [r for r in rows if r["round"] == str(trial)]
        if len(current) != len(CELLS):
            raise ValueError(f"P18 single-ingress missing trial {trial}")
        seen = set()
        orders = set()
        for r in current:
            if r["phase"] != phase:
                raise ValueError(f"P18 single-ingress unexpected phase {trial}")
            w, it, cap = (int(r["workers"]), int(r["iterations"]),
                          int(r["ingress"]))
            if (w, it, cap) not in CELLS or (w, it, cap) in seen:
                raise ValueError("P18 single-ingress duplicate/unexpected case")
            seen.add((w, it, cap))
            orders.add(int(r["order"]))
            all_seeds.add(int(r["seed"]))
            if int(r["count"]) != count or int(r["waves"]) != waves:
                raise ValueError("P18 single-ingress count/waves mismatch")
            retries = int(r["retries"])
            if retries < 0:
                raise ValueError("P18 single-ingress negative retries")
            if cap >= count and retries != 0:
                raise ValueError(
                    f"P18 single-ingress capacity {cap} >= count {count}, "
                    f"but full-inbox retries={retries}")
            retry_by_cap[cap] += retries
        if seen != CELLS or orders != set(range(len(CELLS))):
            raise ValueError(f"P18 single-ingress missing/duplicate order {trial}")
    if len(all_seeds) != 1 or min(all_seeds) <= 0:
        raise ValueError("P18 single-ingress seed inconsistency")
    print(f"P18 SINGLE-INGRESS PASS rows={expected} cases={len(CELLS)} "
          f"rounds={rounds} warmups={warmup} count={count} "
          f"wave_count={waves} total_retries={retry_by_cap}")
    if retry_by_cap[8] == 0:
        print("P18 SINGLE-INGRESS ATTENTION: no tight-ingress producer-full "
              "backpressure observed in this process")
    return retry_by_cap


def self_test():
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / "data.csv"
        header = ("phase", "round", "order", "seed", "workers", "count",
                  "waves", "iterations", "ingress", "retries", "checksum")
        with path.open("w", newline="") as dest:
            writer = csv.DictWriter(dest, fieldnames=header)
            writer.writeheader()
            for trial in (0, 1):
                order = 0
                for it in ITERATIONS:
                    for cap in INGRESS:
                        writer.writerow(dict(phase="warmup" if trial == 0 else "measure",
                                             round=trial, order=order, seed=77,
                                             workers=1, count=16, waves=2,
                                             iterations=it, ingress=cap,
                                             retries=1 if cap == 8 else 0,
                                             checksum=123))
                        order += 1
        audit(path, 16, 2, 1, 1)
        content = path.read_text()
        bad = content.replace(",2048,0,123", ",2048,1,123", 1)
        if bad == content:
            raise AssertionError("bad fixture did not change")
        path.write_text(bad)
        try:
            audit(path, 16, 2, 1, 1)
        except ValueError:
            pass
        else:
            raise AssertionError("missing fail-closed high-capacity check")
    print("P18 single-ingress synthetic negative self-test PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path, nargs="?")
    parser.add_argument("--count", type=int, default=2048)
    parser.add_argument("--waves", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.path is None:
            parser.error("CSV path required")
        if (args.count < 1 or args.waves < 1 or args.warmup < 0 or
            args.rounds < 1):
            parser.error("positive task, wave, and measured-round counts required")
        audit(args.path, args.count, args.waves, args.warmup, args.rounds)
