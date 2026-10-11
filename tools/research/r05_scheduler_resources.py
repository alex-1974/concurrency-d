#!/usr/bin/env python3
"""R0.5 Linux process-vs-producer CPU and scheduling diagnostics.

One isolated child per workload/policy/producer-count/round. The D benchmark
takes RUSAGE_THREAD snapshots only at producer-thread boundaries; Python's
wait4 records whole-child user/system CPU time, context switches and faults.
No privileged perf counters, no hot-path timestamping.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


MAIN = ("metric", "scenario", "policy", "workers", "producers",
        "budget", "tasks", "elapsed_ms", "throughput_per_s",
        "fresh_nodes", "reused_nodes", "producer_gc_bytes",
        "used_close_delta", "used_after_collect_delta",
        "observed_handles", "completed")

RESOURCE = ("metric", "policy", "counter", "workers", "producers",
            "budget", "tasks", "producer_user_us", "producer_system_us",
            "producer_voluntary", "producer_involuntary",
            "producer_minor_faults", "producer_major_faults")


def run_one(binary, root, workers, tasks, budget, producers, policy,
            workload, counter, round_id):
    command = [
        str(binary), str(workers), str(producers),
        str(tasks), str(budget), policy, counter, "off", workload,
    ]
    with tempfile.TemporaryFile(mode="w+t") as stream:
        child = subprocess.Popen(
            command, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
        )
        _, status, usage = os.wait4(child.pid, 0)
        exit_code = os.waitstatus_to_exitcode(status)
        stream.seek(0)
        output = stream.read()
    if exit_code != 0:
        raise RuntimeError(
            f"case {workload}/{policy}/p{producers} round {round_id}"
            f" failed with {exit_code}:\n" + output[-7000:]
        )

    def parse(prefix, expected):
        lines = [s for s in output.splitlines() if s.startswith(prefix)]
        if len(lines) != 1:
            raise RuntimeError("missing or duplicate " + prefix + "\n" + output)
        values = next(csv.reader(lines))
        if len(values) != len(expected):
            raise RuntimeError(
                f"schema mismatch {prefix}: {len(values)} != {len(expected)}"
                "\n" + lines[0])
        return dict(zip(expected, values))

    total = parse("multi,mixed,", MAIN)
    producer = parse("resource,", RESOURCE)
    work = [s for s in output.splitlines() if s.startswith("workload,")]
    if len(work) != 1:
        raise RuntimeError("missing workload mode line")
    fields = next(csv.reader(work))
    if len(fields) != 4 or fields[1] != workload:
        raise RuntimeError("unexpected workload mode: " + work[0])

    if (total["policy"] != policy or
            producer["policy"] != policy or
            producer["counter"] != counter or
            int(total["tasks"]) != tasks or
            int(total["completed"]) != tasks or
            int(producer["producers"]) != producers or
            int(producer["budget"]) != budget or
            int(producer["tasks"]) != tasks):
        raise RuntimeError("wrong D-side workload or accepted/completed counts")

    cpu_user = round(usage.ru_utime * 1_000_000)
    cpu_system = round(usage.ru_stime * 1_000_000)
    producer_user = int(producer["producer_user_us"])
    producer_system = int(producer["producer_system_us"])
    # Minor kernel/accounting granularity differences can occur between
    # RUSAGE_THREAD per-thread boundaries and RUSAGE_CHILDREN wait4.
    # Record both; do not reinterpret the subtraction as exact worker CPU.
    row = {
        "round": round_id, "workload": workload,
        "policy": policy, "counter": counter,
        "workers": workers, "producers": producers, "budget": budget,
        "tasks": tasks,
        "elapsed_ms": total["elapsed_ms"],
        "throughput_per_s": total["throughput_per_s"],
        "producer_user_us": producer_user,
        "producer_system_us": producer_system,
        "producer_voluntary": int(producer["producer_voluntary"]),
        "producer_involuntary": int(producer["producer_involuntary"]),
        "producer_minor_faults": int(producer["producer_minor_faults"]),
        "producer_major_faults": int(producer["producer_major_faults"]),
        "process_user_us": cpu_user,
        "process_system_us": cpu_system,
        "process_voluntary": usage.ru_nvcsw,
        "process_involuntary": usage.ru_nivcsw,
        "process_minor_faults": usage.ru_minflt,
        "process_major_faults": usage.ru_majflt,
        "peak_rss_kib": usage.ru_maxrss,
        "producer_gc_bytes": total["producer_gc_bytes"],
        "fresh_nodes": total["fresh_nodes"],
        "reused_nodes": total["reused_nodes"],
        "observed_handles": total["observed_handles"],
    }
    return row


def median(values):
    return statistics.median(values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=30000)
    parser.add_argument("--budget", type=int, default=512)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--producers", type=int, nargs="+", default=[1, 4, 8])
    parser.add_argument("--policies", nargs="+", default=["gc"],
                        choices=["gc", "recycle"])
    parser.add_argument("--workloads", nargs="+", default=["minimal", "compute"],
                        choices=["minimal", "compute"])
    parser.add_argument("--counter", choices=["shared", "striped"],
                        default="striped")
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-scheduler"))
    args = parser.parse_args()

    if platform.system() != "Linux":
        parser.error("Linux wait4/RUSAGE_THREAD required")
    if (args.workers < 1 or args.workers > 64 or
        args.tasks < 1 or args.tasks > 2_000_000 or
        args.rounds < 1 or args.rounds > 20 or
        args.budget not in (8, 64, 512, 4096) or
        not args.producers or any(p < 1 or p > 64 for p in args.producers)):
        parser.error("invalid benchmark configuration")

    root = Path(__file__).resolve().parents[2]
    subprocess.run(
        ["dub", "build", "--config=task-pipeline-mixed-benchmark",
         "--build=release", "--compiler=" + args.compiler, "--force"],
        cwd=root, check=True,
    )
    binary = root / "concurrency-task-pipeline-mixed"
    if not binary.is_file():
        raise RuntimeError("DUB binary missing: " + str(binary))
    args.output.mkdir(parents=True, exist_ok=True)

    rows = []
    for round_id in range(args.rounds):
        for workload in args.workloads:
            for policy in args.policies:
                producer_counts = (args.producers if round_id % 2 == 0
                                   else list(reversed(args.producers)))
                for producers in producer_counts:
                    row = run_one(
                        binary, root, args.workers, args.tasks, args.budget,
                        producers, policy, workload, args.counter, round_id)
                    rows.append(row)
                    cpu_total = row["process_user_us"] + row["process_system_us"]
                    print(
                        f"R05 scheduler mode={workload} policy={policy} "
                        f"producers={producers} round={round_id} "
                        f"rate={float(row['throughput_per_s']):.1f} "
                        f"process_cpu_us={cpu_total} "
                        f"producer_cpu_us={row['producer_user_us'] + row['producer_system_us']} "
                        f"process_switches={row['process_voluntary'] + row['process_involuntary']} "
                        f"producer_switches={row['producer_voluntary'] + row['producer_involuntary']}",
                        flush=True,
                    )

    with (args.output / "raw.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    index = {}
    for row in rows:
        key = (row["workload"], row["policy"],
               row["producers"], row["round"])
        if key in index:
            raise RuntimeError("duplicate observation")
        index[key] = row

    summary = []
    for workload in args.workloads:
        for policy in args.policies:
            baseline = [index[(workload, policy, 1, r)]
                        for r in range(args.rounds)] if 1 in args.producers else None
            for producers in args.producers:
                sample = [index[(workload, policy, producers, r)]
                          for r in range(args.rounds)]
                ratios = [
                    float(pair["throughput_per_s"]) /
                    float(ref["throughput_per_s"])
                    for pair, ref in zip(sample, baseline)
                ] if baseline is not None else []
                summary.append({
                    "workload": workload,
                    "policy": policy,
                    "producers": producers,
                    "rounds": args.rounds,
                    "median_throughput": round(median(
                        float(x["throughput_per_s"]) for x in sample), 1),
                    "median_relative_to_one_producer": (
                        round(median(ratios), 4) if ratios else "NA"),
                    "median_process_cpu_ms": round(median(
                        (x["process_user_us"] + x["process_system_us"]) / 1000
                        for x in sample), 2),
                    "median_producer_cpu_ms": round(median(
                        (x["producer_user_us"] + x["producer_system_us"]) / 1000
                        for x in sample), 2),
                    "median_process_switches": median(
                        x["process_voluntary"] + x["process_involuntary"]
                        for x in sample),
                    "median_producer_switches": median(
                        x["producer_voluntary"] + x["producer_involuntary"]
                        for x in sample),
                    "median_peak_rss_kib": median(
                        x["peak_rss_kib"] for x in sample),
                })

    with (args.output / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)

    with (args.output / "environment.txt").open("w") as stream:
        stream.write(
            f"compiler={args.compiler}\nplatform={platform.platform()}\n"
            f"machine={platform.machine()}\n"
            f"workers={args.workers} tasks={args.tasks} rounds={args.rounds}\n"
            f"producers={args.producers} policies={args.policies}\n"
            f"workloads={args.workloads} budget={args.budget}\n")
        commands = (["git", "rev-parse", "HEAD"],
                    [args.compiler, "--version"],
                    ["lscpu"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"])
        for cmd in commands:
            try:
                stream.write("$ " + " ".join(cmd) + "\n")
                stream.write(subprocess.run(
                    cmd, cwd=root, check=True, text=True,
                    capture_output=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                stream.write("command unavailable\n")

    print("R05 PROCESS/PRODUCER CPU AND SCHEDULER SUMMARY")
    for s in summary:
        print(f"workload={s['workload']} policy={s['policy']} "
              f"producers={s['producers']} median_rate={s['median_throughput']} "
              f"scaling={s['median_relative_to_one_producer']} "
              f"producer_cpu_ms={s['median_producer_cpu_ms']} "
              f"process_switches={s['median_process_switches']}")
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
