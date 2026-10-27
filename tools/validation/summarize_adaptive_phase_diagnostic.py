#!/usr/bin/env python3
"""Summarize phase diagnostic timings by session and pooled percentile."""
import csv
import pathlib
import statistics
import sys
from collections import defaultdict


def percentile(values, p):
    ordered = sorted(values)
    return ordered[max(0, (len(ordered) * p + 99) // 100 - 1)]


if len(sys.argv) != 3:
    raise SystemExit("usage: summarize_adaptive_phase_diagnostic.py INPUT.csv OUTPUT.csv")
source, destination = map(pathlib.Path, sys.argv[1:])
with source.open(newline="") as stream:
    rows = [row for row in csv.DictReader(stream) if row["phase"] == "measure"]
if not rows:
    raise SystemExit("no measured rows")

groups = defaultdict(list)
paired = defaultdict(dict)
for row in rows:
    session = int(row["session"])
    if row["arm"] == "scope_spawn_drain":
        for metric in ("elapsed_ns", "submit_body_ns", "post_body_ns"):
            groups[(row["scenario"], metric, str(session))].append(int(row[metric]))
    else:
        groups[(row["scenario"], row["arm"], str(session))].append(int(row["elapsed_ns"]))
        key = (session, int(row["sample"]), row["scenario"])
        paired[key][row["arm"]] = int(row["elapsed_ns"])

for (session, sample, scenario), arms in paired.items():
    if set(arms) != {"serial", "parallel_fixed", "parallel_adaptive"}:
        raise SystemExit(f"incomplete paired range sample: {(session, sample, scenario)}")
    groups[(scenario, "adaptive_over_fixed", str(session))].append(
        arms["parallel_adaptive"] / arms["parallel_fixed"])

for key, values in list(groups.items()):
    groups[(key[0], key[1], "pooled")].extend(values)

with destination.open("w", newline="") as stream:
    fields = ["scenario", "metric", "session", "samples", "p50", "p95", "p99"]
    writer = csv.DictWriter(stream, fieldnames=fields)
    writer.writeheader()
    for (scenario, metric, session), values in sorted(groups.items()):
        writer.writerow({
            "scenario": scenario, "metric": metric, "session": session,
            "samples": len(values), "p50": statistics.median(values),
            "p95": percentile(values, 95), "p99": percentile(values, 99),
        })
print(f"wrote {destination} ({len(groups)} summaries)")
