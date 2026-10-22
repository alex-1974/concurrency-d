#!/usr/bin/env python3
"""P34 source-preserving P31 observation report, no timing causality claim."""
import argparse
import csv
import json
import statistics
from pathlib import Path

from m1_p31_analyze import validate, WORK, MODES, PRODUCERS


def report(path, rounds):
    with path.open(newline="") as stream:
        measured, dims = validate(stream, rounds)
    output = {"diagnostic_only": True, "task_dimensions": dims, "profiles": {}}
    for work in WORK:
        for owner in MODES:
            for producers in PRODUCERS:
                rows = [
                    arms[owner] for (round_id, kind, nprod), arms in measured.items()
                    if kind == work and nprod == producers
                ]
                key = f"{work}/{owner}/{producers}"
                output["profiles"][key] = {
                    "rounds": len(rows),
                    "producer_alloc_bytes_median": statistics.median(
                        row["producer_alloc_bytes"] for row in rows),
                    "producer_alloc_bytes_min": min(
                        row["producer_alloc_bytes"] for row in rows),
                    "producer_alloc_bytes_max": max(
                        row["producer_alloc_bytes"] for row in rows),
                    "submit_ns_median": statistics.median(
                        row["submit_ns"] for row in rows),
                    "create_start_ns_median": statistics.median(
                        row["create_start_ns"] for row in rows),
                    "join_release_ns_median": statistics.median(
                        row["join_release_ns"] for row in rows),
                    "failed_attempts_median": statistics.median(
                        row["attempts"] - row["accepted"] for row in rows),
                }
    return output


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--min-rounds", type=int, default=9)
    p.add_argument("--json", type=Path)
    args = p.parse_args()
    data = report(args.input, args.min_rounds)
    rendered = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.write_text(rendered)
    else:
        print(rendered)
    print("P34_P31_OBSERVATIONAL_PROFILE_PASS")


if __name__ == "__main__":
    main()
