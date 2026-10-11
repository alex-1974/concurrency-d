#!/usr/bin/env python3
"""Measure the old hot shared atomic vs producer-stripe atomic, no timers.

Controls: identical callable/task ID partition, workers, storage policy,
result observations, and thread count; only execution-counter address
distribution differs. Each trial runs in a fresh Linux child.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

HEADERS = ("metric", "scenario", "policy", "workers", "producers",
           "budget", "tasks", "elapsed_ms", "throughput_per_s",
           "fresh_nodes", "reused_nodes", "producer_gc_bytes",
           "used_close_delta", "used_after_collect_delta",
           "observed_handles", "completed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=30000)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--producers", nargs="+", type=int, default=[1, 4, 8])
    parser.add_argument("--budgets", nargs="+", type=int, default=[8, 512])
    parser.add_argument("--policies", nargs="+", default=["gc", "recycle"],
                        choices=["gc", "recycle"])
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-counter-control"))
    a = parser.parse_args()

    if platform.system() != "Linux":
        parser.error("Linux wait4 required")
    if (a.workers < 1 or a.workers > 64 or
        a.tasks < 1 or a.tasks > 2_000_000 or
        a.rounds < 1 or a.rounds > 20 or
        not a.producers or not a.budgets or
        any(p < 1 or p > 64 for p in a.producers) or
        any(b not in [8, 64, 512, 4096] for b in a.budgets)):
        parser.error("invalid matrix parameter")

    root = Path(__file__).resolve().parents[2]
    subprocess.run(["dub", "build",
                    "--config=task-pipeline-mixed-benchmark",
                    "--build=release", "--compiler=" + a.compiler, "--force"],
                   cwd=root, check=True)
    binary = root / "concurrency-task-pipeline-mixed"
    if not binary.is_file():
        raise RuntimeError("no DUB binary: " + str(binary))

    a.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for rnd in range(a.rounds):
        for producers in a.producers:
            for budget in a.budgets:
                for policy in a.policies:
                    modes = ("shared", "striped") if rnd % 2 == 0 else (
                        "striped", "shared")
                    for mode in modes:
                        command = [
                            str(binary), str(a.workers), str(producers),
                            str(a.tasks), str(budget), policy, mode, "off",
                        ]
                        with tempfile.TemporaryFile(mode="w+t") as fd:
                            child = subprocess.Popen(
                                command, cwd=root, stdout=fd,
                                stderr=subprocess.STDOUT,
                            )
                            _, status, usage = os.wait4(child.pid, 0)
                            code = os.waitstatus_to_exitcode(status)
                            fd.seek(0)
                            output = fd.read()

                        if code != 0:
                            raise RuntimeError(
                                f"counter {policy}/{mode}, p={producers}, "
                                f"b={budget}, round={rnd}, exit={code}:\n"
                                + output[-5000:])

                        line = [x for x in output.splitlines()
                                if x.startswith("multi,mixed,")]
                        if len(line) != 1:
                            raise RuntimeError("missing data: " + output)
                        fields = next(csv.reader(line))
                        if len(fields) != len(HEADERS):
                            raise RuntimeError("invalid baseline CSV schema")
                        row = dict(zip(HEADERS, fields))
                        if (row["policy"] != policy or
                                int(row["completed"]) != a.tasks or
                                int(row["tasks"]) != a.tasks):
                            raise RuntimeError("bad counter control result")
                        row.pop("metric")
                        row.pop("scenario")
                        row["counter_mode"] = mode
                        row["round"] = rnd
                        row["peak_rss_kib"] = usage.ru_maxrss
                        rows.append(row)
                        print(f"R05 unprofiled p={producers} b={budget} "
                              f"policy={policy} counter={mode} "
                              f"rate={row['throughput_per_s']}", flush=True)

    with (a.output / "raw.csv").open("w", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    cases = {}
    for row in rows:
        key = (int(row["producers"]), int(row["budget"]),
               row["policy"], int(row["round"]))
        cases.setdefault(key, {})[row["counter_mode"]] = row

    summary = []
    for producers in a.producers:
        for budget in a.budgets:
            for policy in a.policies:
                pairs = [cases[(producers, budget, policy, r)]
                         for r in range(a.rounds)]
                if any(set(pair) != {"shared", "striped"} for pair in pairs):
                    raise RuntimeError("incomplete shared/striped pair")
                ratios = [float(pair["striped"]["throughput_per_s"]) /
                          float(pair["shared"]["throughput_per_s"])
                          for pair in pairs]
                summary.append({
                    "producers": producers, "budget": budget,
                    "policy": policy, "rounds": a.rounds,
                    "median_striped_over_shared": round(
                        statistics.median(ratios), 4),
                    "striped_wins": sum(x > 1 for x in ratios),
                    "min_ratio": round(min(ratios), 4),
                    "max_ratio": round(max(ratios), 4),
                })
    with (a.output / "summary.csv").open("w", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)

    with (a.output / "environment.txt").open("w") as fd:
        fd.write(f"compiler={a.compiler}\nplatform={platform.platform()}\n"
                 f"workers={a.workers} tasks={a.tasks} rounds={a.rounds}\n"
                 f"producers={a.producers} budgets={a.budgets}\n")
        for cmd in (["git", "rev-parse", "HEAD"],
                    ["ldc2", "--version"], ["lscpu"]):
            try:
                fd.write("$ " + " ".join(cmd) + "\n" +
                         subprocess.run(
                             cmd, cwd=root, check=True, capture_output=True,
                             text=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("command unavailable\n")

    print("R05 UNPROFILED STRIPED/SHARED")
    for x in summary:
        print("p={producers} budget={budget} policy={policy}: "
              "{median_striped_over_shared:.4f}x "
              "(wins={striped_wins}/{rounds})".format(**x))


if __name__ == "__main__":
    main()
