#!/usr/bin/env python3
"""R0.5 paired owned-task benchmark: isolated subprocess and RSS evidence.

Each policy/budget/scenario/round runs in its own fresh process, measuring
peak RSS with Linux wait4 rather than reading a process-global high-water
mark which cannot decrease between experiments.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


def build(root, compiler):
    subprocess.run(
        ["dub", "build", "--config=task-pipeline-benchmark",
         "--build=release", "--compiler=" + compiler, "--force"],
        cwd=root, check=True,
    )
    binary = root / "concurrency-task-pipeline-benchmark"
    if not binary.is_file():
        raise RuntimeError("DUB target not found at " + str(binary))
    return binary


def sample(binary, root, workers, tasks, scenario, policy, budget, run):
    command = [str(binary), str(workers), str(tasks), "1",
               scenario, policy, str(budget)]

    # Redirect output to a file to avoid pipe deadlocks while wait4 blocks.
    with tempfile.TemporaryFile(mode="w+t") as log:
        child = subprocess.Popen(
            command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
            text=True,
        )
        pid, status, usage = os.wait4(child.pid, 0)
        child.returncode = os.waitstatus_to_exitcode(status)
        log.seek(0)
        output = log.read()

    if child.returncode != 0:
        raise RuntimeError(
            f"case {scenario}/{policy}/{budget}/{run} failed "
            f"(exit {child.returncode}):\n{output[-5000:]}"
        )

    rows = [line for line in output.splitlines()
            if line.startswith("pipeline,")]
    if len(rows) != 1:
        raise RuntimeError(f"expected one metric row; output:\n{output}")

    header = [
        "metric", "scenario", "policy", "workers", "budget", "tasks",
        "round", "elapsed_ms", "throughput_per_s", "fresh_nodes",
        "reused_nodes", "producer_gc_bytes", "gc_used_delta",
        "observed_handles",
    ]
    data = dict(zip(header, next(csv.reader(rows))))
    if len(data) != len(header):
        raise RuntimeError("incomplete pipeline metric row: " + rows[0])

    data["matrix_round"] = str(run)
    data["peak_rss_kib"] = str(usage.ru_maxrss)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=12000)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--scenarios", nargs="+",
                        default=["scalar", "wide", "void"],
                        choices=["scalar", "wide", "void"])
    parser.add_argument("--budgets", nargs="+", type=int,
                        default=[8, 64, 512, 4096])
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-owned-task-pipeline"))
    args = parser.parse_args()

    if (args.workers < 1 or args.tasks < 1 or args.rounds < 1 or
            any(b not in [8, 64, 512, 4096] for b in args.budgets)):
        parser.error("worker/task/round values must be positive; known budgets only")
    if platform.system() != "Linux":
        parser.error("this RSS qualification harness requires Linux wait4")

    root = Path(__file__).resolve().parents[2]
    binary = build(root, args.compiler)
    args.output.mkdir(parents=True, exist_ok=True)

    rows = []
    for run in range(args.rounds):
        for scenario in args.scenarios:
            for budget in args.budgets:
                # Pair the two modes closely, then reverse their order
                # next round to mitigate host warmup/thermal order drift.
                policies = ("gc", "recycle") if run % 2 == 0 else ("recycle", "gc")
                for policy in policies:
                    item = sample(binary, root, args.workers, args.tasks,
                                  scenario, policy, budget, run)
                    rows.append(item)
                    print(
                        f"r05 scenario={scenario} budget={budget} "
                        f"policy={policy} round={run} "
                        f"tasks_per_s={float(item['throughput_per_s']):.1f} "
                        f"rss_kib={item['peak_rss_kib']} "
                        f"new={item['fresh_nodes']} reused={item['reused_nodes']}",
                        flush=True,
                    )

    raw_file = args.output / "raw.csv"
    fields = list(rows[0])
    with raw_file.open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    groups = {}
    for row in rows:
        key = (row["scenario"], int(row["budget"]), int(row["matrix_round"]))
        groups.setdefault(key, {})[row["policy"]] = row

    summaries = []
    for scenario in args.scenarios:
        for budget in args.budgets:
            paired = [groups[(scenario, budget, run)]
                      for run in range(args.rounds)]
            if any("gc" not in pair or "recycle" not in pair for pair in paired):
                raise RuntimeError("incomplete pair for " + scenario)

            ratios = [
                float(pair["recycle"]["throughput_per_s"]) /
                float(pair["gc"]["throughput_per_s"])
                for pair in paired
            ]
            for policy in ("gc", "recycle"):
                items = [pair[policy] for pair in paired]
                summaries.append({
                    "scenario": scenario,
                    "budget": budget,
                    "policy": policy,
                    "rounds": args.rounds,
                    "median_tasks_per_s": round(statistics.median(
                        float(x["throughput_per_s"]) for x in items), 1),
                    "median_peak_rss_kib": int(statistics.median(
                        int(x["peak_rss_kib"]) for x in items)),
                    "median_producer_gc_bytes": int(statistics.median(
                        int(x["producer_gc_bytes"]) for x in items)),
                    "median_fresh_nodes": int(statistics.median(
                        int(x["fresh_nodes"]) for x in items)),
                    "median_reused_nodes": int(statistics.median(
                        int(x["reused_nodes"]) for x in items)),
                    "median_paired_recycle_speedup": round(
                        statistics.median(ratios), 4),
                })

    summary_file = args.output / "summary.csv"
    with summary_file.open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)

    # Environment is evidence, not a claim of equal hardware across runners.
    with (args.output / "environment.txt").open("w") as out:
        out.write(f"compiler={args.compiler}\n")
        out.write(f"platform={platform.platform()}\n")
        out.write(f"machine={platform.machine()}\n")
        out.write(f"workers={args.workers} tasks={args.tasks} rounds={args.rounds}\n")
        out.write(f"scenarios={args.scenarios} budgets={args.budgets}\n")
        try:
            out.write(subprocess.run(
                ["lscpu"], capture_output=True, check=True, text=True,
            ).stdout)
        except (OSError, subprocess.CalledProcessError):
            out.write("lscpu unavailable\n")

    print("\nPAIRED MEDIAN SPEEDUPS (recycle / gc):")
    for item in summaries:
        if item["policy"] == "recycle":
            print(f"{item['scenario']} budget={item['budget']}: "
                  f"{item['median_paired_recycle_speedup']:.4f}x")
    print(f"evidence: {raw_file} {summary_file}", flush=True)


if __name__ == "__main__":
    main()
