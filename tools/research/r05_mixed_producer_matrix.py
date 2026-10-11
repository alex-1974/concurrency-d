#!/usr/bin/env python3
"""R0.5 multi-producer mixed-callable comparison, Linux process-isolated.

This is a research instrument, not an absolute performance gate. Every
GC/recycle pair executes the same task IDs, producer count, worker count,
result-observation schedule and mixed callable types. Peak RSS is taken
from Linux wait4() for each fresh child process.
"""

import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


COLUMNS = (
    "metric", "scenario", "policy", "workers", "producers", "budget",
    "tasks", "elapsed_ms", "throughput_per_s", "fresh_nodes",
    "reused_nodes", "producer_gc_bytes", "used_close_delta",
    "used_after_collect_delta", "observed_handles", "completed",
)


def build(root, compiler):
    subprocess.run(
        [
            "dub", "build", "--config=task-pipeline-mixed-benchmark",
            "--build=release", "--compiler=" + compiler, "--force",
        ],
        cwd=root, check=True,
    )
    target = root / "concurrency-task-pipeline-mixed"
    if not target.is_file():
        raise RuntimeError("DUB did not produce " + str(target))
    return target


def run_one(binary, root, workers, producers, tasks, budget, policy, round_id):
    command = [
        str(binary), str(workers), str(producers), str(tasks),
        str(budget), policy,
    ]
    with tempfile.TemporaryFile(mode="w+t") as output_file:
        proc = subprocess.Popen(
            command, cwd=root, stdout=output_file,
            stderr=subprocess.STDOUT, text=True,
        )
        pid, status, usage = os.wait4(proc.pid, 0)
        proc.returncode = os.waitstatus_to_exitcode(status)
        output_file.seek(0)
        output = output_file.read()

    if proc.returncode != 0:
        raise RuntimeError(
            f"mixed case p={producers} b={budget} {policy} "
            f"round={round_id} failed (exit {proc.returncode}):\n"
            + output[-5000:]
        )

    lines = [s for s in output.splitlines()
             if s.startswith("multi,mixed,")]
    if len(lines) != 1:
        raise RuntimeError("expected one mixed metric row:\n" + output)

    values = next(csv.reader(lines))
    if len(values) != len(COLUMNS):
        raise RuntimeError(
            f"expected {len(COLUMNS)} CSV fields, got {len(values)}: "
            + lines[0]
        )

    row = dict(zip(COLUMNS, values))
    if (row["policy"] != policy or row["scenario"] != "mixed"
            or int(row["completed"]) != tasks
            or int(row["tasks"]) != tasks
            or int(row["workers"]) != workers
            or int(row["producers"]) != producers):
        raise RuntimeError("mixed benchmark returned invalid accounting")

    row["matrix_round"] = str(round_id)
    row["peak_rss_kib"] = str(usage.ru_maxrss)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=12000)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--producers", type=int, nargs="+", default=[1, 4, 8])
    parser.add_argument("--budgets", type=int, nargs="+",
                        default=[8, 64, 512, 4096])
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-mixed-producers"))
    args = parser.parse_args()

    if platform.system() != "Linux":
        parser.error("this benchmark requires Linux wait4()")
    if (args.workers < 1 or args.workers > 64 or
            args.tasks < 1 or args.tasks > 2_000_000 or
            args.rounds < 1 or args.rounds > 20 or
            not args.producers or not args.budgets or
            any(n < 1 or n > 64 for n in args.producers) or
            any(n not in [8, 64, 512, 4096] for n in args.budgets)):
        parser.error("invalid worker/producer/task/round/budget")

    root = Path(__file__).resolve().parents[2]
    binary = build(root, args.compiler)
    args.output.mkdir(parents=True, exist_ok=True)

    rows = []
    for round_id in range(args.rounds):
        for producers in args.producers:
            for budget in args.budgets:
                policies = ("gc", "recycle") if round_id % 2 == 0 else (
                    "recycle", "gc")
                for policy in policies:
                    row = run_one(
                        binary, root, args.workers, producers, args.tasks,
                        budget, policy, round_id)
                    rows.append(row)
                    print(
                        f"R05 mixed producers={producers} budget={budget} "
                        f"policy={policy} round={round_id} "
                        f"tasks_per_s={float(row['throughput_per_s']):.1f} "
                        f"rss_kib={row['peak_rss_kib']} "
                        f"gc_producer_bytes={row['producer_gc_bytes']} "
                        f"fresh={row['fresh_nodes']} reused={row['reused_nodes']}",
                        flush=True,
                    )

    with (args.output / "raw.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    pairs = {}
    for row in rows:
        key = (
            int(row["producers"]),
            int(row["budget"]),
            int(row["matrix_round"]),
        )
        pairs.setdefault(key, {})[row["policy"]] = row

    summaries = []
    for producers in args.producers:
        for budget in args.budgets:
            cases = [pairs[(producers, budget, r)]
                     for r in range(args.rounds)]
            if any(set(c) != {"gc", "recycle"} for c in cases):
                raise RuntimeError("incomplete paired comparison")

            speedups = [
                float(pair["recycle"]["throughput_per_s"]) /
                float(pair["gc"]["throughput_per_s"])
                for pair in cases
            ]

            def median_of(policy, name):
                return statistics.median(
                    float(pair[policy][name]) for pair in cases
                )

            summaries.append({
                "producers": producers,
                "budget": budget,
                "workers": args.workers,
                "tasks": args.tasks,
                "rounds": args.rounds,
                "median_paired_speedup_recycle": round(
                    statistics.median(speedups), 4),
                "median_gc_tasks_per_s": round(
                    median_of("gc", "throughput_per_s"), 1),
                "median_recycle_tasks_per_s": round(
                    median_of("recycle", "throughput_per_s"), 1),
                "median_gc_peak_rss_kib": int(
                    median_of("gc", "peak_rss_kib")),
                "median_recycle_peak_rss_kib": int(
                    median_of("recycle", "peak_rss_kib")),
                "median_gc_producer_gc_bytes": int(
                    median_of("gc", "producer_gc_bytes")),
                "median_recycle_producer_gc_bytes": int(
                    median_of("recycle", "producer_gc_bytes")),
                "median_gc_fresh_nodes": int(
                    median_of("gc", "fresh_nodes")),
                "median_recycle_fresh_nodes": int(
                    median_of("recycle", "fresh_nodes")),
                "median_recycle_reused_nodes": int(
                    median_of("recycle", "reused_nodes")),
            })

    with (args.output / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)

    with (args.output / "environment.txt").open("w") as stream:
        stream.write("compiler=" + args.compiler + "\n")
        stream.write("platform=" + platform.platform() + "\n")
        stream.write("machine=" + platform.machine() + "\n")
        stream.write(
            f"workers={args.workers} tasks={args.tasks} "
            f"rounds={args.rounds}\nproducers={args.producers} "
            f"budgets={args.budgets}\n"
        )
        try:
            stream.write(subprocess.run(
                ["lscpu"], text=True, capture_output=True, check=True,
            ).stdout)
        except (OSError, subprocess.CalledProcessError):
            stream.write("lscpu unavailable\n")

    print("R05 MIXED PAIRED MEDIANS (recycle throughput / gc throughput)")
    for row in summaries:
        print(
            f"producers={row['producers']} budget={row['budget']} "
            f"recycle_over_gc={row['median_paired_speedup_recycle']:.4f}x "
            f"gc_rss_kib={row['median_gc_peak_rss_kib']} "
            f"recycle_rss_kib={row['median_recycle_peak_rss_kib']}"
        )
    print(f"evidence: {args.output}/raw.csv {args.output}/summary.csv")


if __name__ == "__main__":
    main()
