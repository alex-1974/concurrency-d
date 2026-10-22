#!/usr/bin/env python3
"""P18 producer-ingress EVENT ONLY: exact TaskRefs and queue accounting.

There is no wall-clock speed verdict here. Do not compare the instrumented
elapsed times against uninstrumented P18/M0 timing evidence.
"""
import argparse
from pathlib import Path
from collections import defaultdict
from statistics import median

from m1_p18_512_trace_compare import compare as base_trace_compare, load

FIELDS = (
    "submitCalls", "submitAccepted", "submitFull", "submitClosed",
    "takeCalls", "takeEmpty", "takenTasks", "peakUsed",
    "acceptOccupancy1to8", "acceptOccupancy9to256",
    "acceptOccupancy257Plus", "completeCalls", "wakeReads",
    "drainReads", "announceCalls", "pollYields",
)


def audit(original, candidate, minimum, count, waves):
    # This validates the source-pinned TaskRef checksum, exact work,
    # all pre-existing worker-grace invariants, and park conservation.
    base_trace_compare(original, candidate, minimum)
    a, b = load(original), load(candidate)
    if any(not set(FIELDS).issubset(row) for row in a + b):
        raise ValueError("P18 PI required producer/ingress fields missing")
    aggregate = defaultdict(lambda: defaultdict(list))
    for rownum, pair in enumerate(zip(a, b)):
        for arm, row in zip(("M0", "P18"), pair):
            try:
                data = {field: int(row[field]) for field in FIELDS}
                tasks = int(row["count"]) * int(row["waves"])
                ingress = int(row["ingress"])
                producer_retries = int(row["retries"])
            except (ValueError, KeyError) as exc:
                raise ValueError(f"P18 PI invalid numeric field {rownum}") from exc
            if int(row["count"]) != count or int(row["waves"]) != waves:
                raise ValueError("P18 PI count/waves not fixed")
            if min(data.values()) < 0:
                raise ValueError("P18 PI negative counter")
            if (data["submitAccepted"] != tasks or
                data["submitClosed"] != 0 or
                data["submitCalls"] != data["submitAccepted"] +
                    data["submitFull"] + data["submitClosed"] or
                data["submitFull"] != producer_retries or
                data["takeCalls"] < data["takeEmpty"] or
                data["takeCalls"] - data["takeEmpty"] != int(row["batch_claims"]) or
                data["takenTasks"] != tasks or
                data["takenTasks"] != int(row["batch_tasks"]) or
                data["completeCalls"] != tasks or
                data["acceptOccupancy1to8"] +
                    data["acceptOccupancy9to256"] +
                    data["acceptOccupancy257Plus"] != tasks or
                not 0 < data["peakUsed"] <= ingress or
                (data["submitFull"] and data["peakUsed"] != ingress) or
                (ingress >= count and data["submitFull"] != 0) or
                data["wakeReads"] < data["takeCalls"] or
                data["announceCalls"] > int(row["batch_claims"])):
                raise ValueError(f"P18 PI counter invariant failed: {arm} row {rownum}")
            if row["phase"] == "measure":
                key = int(row["iterations"]), ingress
                for name in FIELDS:
                    aggregate[key][arm + "_" + name].append(data[name])

    for (iterations, ingress), measures in sorted(aggregate.items()):
        def med(arm, field):
            return median(measures[arm + "_" + field])
        print(
            f"P18 PI EVENT ONLY iterations={iterations} ingress={ingress} "
            f"producer_full_M0/P18={med('M0','submitFull'):.0f}/"
            f"{med('P18','submitFull'):.0f} "
            f"peak_occupancy_M0/P18={med('M0','peakUsed'):.0f}/"
            f"{med('P18','peakUsed'):.0f} "
            f"take_empty_M0/P18={med('M0','takeEmpty'):.0f}/"
            f"{med('P18','takeEmpty'):.0f} "
            f"generation_reads_M0/P18={med('M0','wakeReads'):.0f}/"
            f"{med('P18','wakeReads'):.0f} "
            f"completion_poll_yields_M0/P18={med('M0','pollYields'):.0f}/"
            f"{med('P18','pollYields'):.0f} "
            f"n={len(measures['M0_submitFull'])}")
    if set(aggregate) != {(k, i) for k in (128,512,1024) for i in (8,64,256,2048)}:
        raise ValueError("P18 PI measured matrix missing one-worker ingress cases")
    print(f"P18 PI PASS rows={len(a)} event-only, no timing qualification")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("control", type=Path)
    parser.add_argument("grace", type=Path)
    parser.add_argument("--min-rows", type=int, default=84)
    parser.add_argument("--count", type=int, default=2048)
    parser.add_argument("--waves", type=int, default=3)
    args = parser.parse_args()
    audit(args.control, args.grace, args.min_rows, args.count, args.waves)


if __name__ == "__main__":
    main()
