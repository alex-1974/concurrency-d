#!/usr/bin/env python3
"""R0.5 optional worker parking/steal study (isolated Linux processes).

Pairs opt-in parking counters with an uninstrumented control under
identical work and lifetime/result semantics. Worker stats are sampled
only after join; there are no added timestamps on task execution.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


BASE = (
    "metric", "scenario", "policy", "workers", "producers", "budget",
    "tasks", "elapsed_ms", "throughput_per_s", "fresh_nodes",
    "reused_nodes", "producer_gc_bytes", "used_close_delta",
    "used_after_collect_delta", "observed_handles", "completed",
)
PARK = (
    "metric", "policy", "workload", "producers", "workers", "budget",
    "tasks", "local_misses", "ingress_misses", "steal_attempts",
    "steal_successes", "park_checks", "condition_waits",
    "wait_returns", "skipped_parks", "executions",
    "ingress_notifications", "local_notifications",
    "close_broadcasts", "drain_broadcasts",
    "claimed_batches", "claimed_tasks", "peak_queued",
)
WAKE = (
    "metric", "policy", "workload", "producers", "workers", "budget",
    "tasks", "still_blocked", "exit_inbox", "exit_generation",
    "exit_drained", "useful_local", "useful_inbox", "useful_steal",
    "no_work", "drained",
)


def read_metric(output, prefix, columns, required=True):
    matches = [line for line in output.splitlines()
               if line.startswith(prefix)]
    if not required and not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one {prefix} line:\n" +
                           output[-7000:])
    fields = next(csv.reader(matches))
    if len(fields) != len(columns):
        raise RuntimeError(
            f"bad {prefix} CSV field count {len(fields)} "
            f"(expected {len(columns)}): {matches[0]}")
    return dict(zip(columns, fields))


def trial(binary, root, workers, tasks, producers, budget, policy,
          workload, counter, profile, round_id):
    command = [str(binary), str(workers), str(producers), str(tasks),
               str(budget), policy, counter, "off", workload, profile]
    with tempfile.TemporaryFile(mode="w+t") as fd:
        child = subprocess.Popen(
            command, cwd=root, stdout=fd, stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(child.pid, 0)
        code = os.waitstatus_to_exitcode(status)
        fd.seek(0)
        output = fd.read()
    if code != 0:
        raise RuntimeError(
            f"{workload}/{policy}/{profile}/p{producers} "
            f"round={round_id}, exit={code}:\n" + output[-7000:])
    perf = read_metric(output, "multi,mixed,", BASE)
    park = read_metric(output, "parking,", PARK, required=profile == "on")
    wake = read_metric(output, "wakeup,", WAKE, required=profile == "on")
    if profile == "off" and any(
        x.startswith(("parking,", "wakeup,"))
        for x in output.splitlines()
    ):
        raise RuntimeError("worker counters leaked into OFF case")

    if (perf["policy"] != policy or int(perf["tasks"]) != tasks or
        int(perf["completed"]) != tasks or
        int(perf["producers"]) != producers or
        int(perf["budget"]) != budget):
        raise RuntimeError("D-side task completion mismatch")
    if park is not None:
        if (park["policy"] != policy or
            park["workload"] != workload or
            int(park["executions"]) != tasks or
            int(park["claimed_tasks"]) != tasks or
            int(park["ingress_notifications"]) != tasks or
            int(park["condition_waits"]) != int(park["wait_returns"]) or
            int(park["steal_successes"]) > int(park["steal_attempts"])):
            raise RuntimeError("D-side parked worker accounting mismatch")
        if (wake["policy"] != policy or wake["workload"] != workload or
            int(wake["producers"]) != producers or
            int(wake["workers"]) != workers or
            int(wake["budget"]) != budget or
            int(wake["tasks"]) != tasks):
            raise RuntimeError("wake outcome metadata mismatch")
        completed_waits = (int(wake["exit_inbox"]) +
                           int(wake["exit_generation"]) +
                           int(wake["exit_drained"]))
        observed_outcomes = sum(int(wake[key]) for key in (
            "useful_local", "useful_inbox", "useful_steal",
            "no_work", "drained"))
        if (completed_waits != observed_outcomes or
            int(park["wait_returns"]) !=
                completed_waits + int(wake["still_blocked"])):
            raise RuntimeError("wake exit/search conservation mismatch")

    row = {
        "round": round_id, "workload": workload, "policy": policy,
        "producers": producers, "workers": workers, "budget": budget,
        "tasks": tasks, "profile": profile, "counter": counter,
        "throughput_per_s": perf["throughput_per_s"],
        "elapsed_ms": perf["elapsed_ms"],
        "producer_gc_bytes": perf["producer_gc_bytes"],
        "fresh_nodes": perf["fresh_nodes"],
        "reused_nodes": perf["reused_nodes"],
        "process_user_us": round(usage.ru_utime * 1_000_000),
        "process_system_us": round(usage.ru_stime * 1_000_000),
        "process_voluntary": usage.ru_nvcsw,
        "process_involuntary": usage.ru_nivcsw,
        "peak_rss_kib": usage.ru_maxrss,
    }
    for label in PARK[7:]:
        row[label] = int(park[label]) if park is not None else ""
    for label in WAKE[7:]:
        row[label] = int(wake[label]) if wake is not None else ""
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=30000)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--budget", type=int, default=512)
    parser.add_argument("--producers", type=int, nargs="+", default=[1, 4, 8])
    parser.add_argument("--workloads", nargs="+", choices=["minimal", "compute"],
                        default=["minimal", "compute"])
    parser.add_argument("--policies", nargs="+", choices=["gc", "recycle"],
                        default=["gc", "recycle"])
    parser.add_argument("--counter", choices=["shared", "striped"],
                        default="striped")
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-worker-parking"))
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("requires Linux wait4")
    if (args.workers < 1 or args.workers > 64 or
        args.tasks < 1 or args.tasks > 2_000_000 or
        args.rounds < 1 or args.rounds > 20 or
        args.budget not in [8, 64, 512, 4096] or
        not args.producers or not args.workloads or not args.policies or
        any(p < 1 or p > 64 for p in args.producers)):
        parser.error("invalid worker/task/budget/round/producer count")

    root = Path(__file__).resolve().parents[2]
    subprocess.run(
        ["dub", "build", "--config=task-pipeline-mixed-benchmark",
         "--build=release", "--compiler=" + args.compiler, "--force"],
        check=True, cwd=root,
    )
    binary = root / "concurrency-task-pipeline-mixed"
    if not binary.is_file():
        raise RuntimeError("missing DUB benchmark executable")
    args.output.mkdir(parents=True, exist_ok=True)

    rows = []
    for rnd in range(args.rounds):
        counts = (args.producers if rnd % 2 == 0
                  else list(reversed(args.producers)))
        for workload in args.workloads:
            for policy in args.policies:
                for producers in counts:
                    modes = ("off", "on") if rnd % 2 == 0 else ("on", "off")
                    for mode in modes:
                        row = trial(binary, root, args.workers, args.tasks,
                                    producers, args.budget, policy,
                                    workload, args.counter, mode, rnd)
                        rows.append(row)
                        print(
                            f"R05 parking workload={workload} policy={policy} "
                            f"producers={producers} profile={mode} "
                            f"round={rnd} rate={float(row['throughput_per_s']):.1f} "
                            f"parks={row['condition_waits']} "
                            f"steal_attempts={row['steal_attempts']} "
                            f"steal_successes={row['steal_successes']}",
                            flush=True,
                        )

    path = args.output / "raw.csv"
    with path.open("w", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    unique = {}
    for row in rows:
        key = (row["round"], row["workload"], row["policy"],
               row["producers"], row["profile"])
        if key in unique:
            raise RuntimeError("duplicate matrix case")
        unique[key] = row

    summary = []
    for workload in args.workloads:
        for policy in args.policies:
            for producers in args.producers:
                pairs = [(unique[rnd, workload, policy, producers, "on"],
                          unique[rnd, workload, policy, producers, "off"])
                         for rnd in range(args.rounds)]
                ratios = [float(on["throughput_per_s"]) /
                          float(off["throughput_per_s"]) for on, off in pairs]
                p = [on for on, _ in pairs]
                median = statistics.median
                summary.append({
                    "workload": workload, "policy": policy,
                    "producers": producers, "budget": args.budget,
                    "rounds": args.rounds,
                    "median_profile_over_baseline": round(median(ratios), 4),
                    "median_parks_per_task": round(median(
                        x["condition_waits"] / args.tasks for x in p), 4),
                    "median_steals_per_task": round(median(
                        x["steal_successes"] / args.tasks for x in p), 4),
                    "median_failed_steals_per_task": round(median(
                        (x["steal_attempts"] - x["steal_successes"]) /
                        args.tasks for x in p), 4),
                    "median_park_checks_per_task": round(median(
                        x["park_checks"] / args.tasks for x in p), 4),
                    "median_ingress_misses_per_task": round(median(
                        x["ingress_misses"] / args.tasks for x in p), 4),
                    "median_ingress_batch_size": round(median(
                        x["claimed_tasks"] / x["claimed_batches"] for x in p), 3),
                    "median_useful_after_wait_pct": round(median(
                        100.0 * (
                            x["useful_local"] +
                            x["useful_inbox"] +
                            x["useful_steal"]
                        ) / max(1, x["condition_waits"] - x["still_blocked"])
                        for x in p), 2),
                    "median_no_work_after_wait_pct": round(median(
                        100.0 * x["no_work"] /
                        max(1, x["condition_waits"] - x["still_blocked"])
                        for x in p), 2),
                    "median_generation_only_exit_pct": round(median(
                        100.0 * x["exit_generation"] /
                        max(1, x["condition_waits"] - x["still_blocked"])
                        for x in p), 2),
                    "median_profile_throughput": round(median(
                        float(x["throughput_per_s"]) for x in p), 1),
                    "median_unprofiled_throughput": round(median(
                        float(off["throughput_per_s"]) for _, off in pairs), 1),
                })
    summary_path = args.output / "summary.csv"
    with summary_path.open("w", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)

    with (args.output / "environment.txt").open("w") as fd:
        fd.write(
            f"compiler={args.compiler}\nplatform={platform.platform()}\n"
            f"machine={platform.machine()}\n"
            f"workers={args.workers} tasks={args.tasks} rounds={args.rounds}\n"
            f"budget={args.budget} producers={args.producers}\n"
            f"workloads={args.workloads} policies={args.policies}\n"
            f"counter={args.counter}\n"
        )
        for cmd in (
            ["git", "rev-parse", "HEAD"],
            [args.compiler, "--version"],
            ["lscpu"],
            ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"],
        ):
            try:
                fd.write("$ " + " ".join(cmd) + "\n")
                fd.write(subprocess.run(
                    cmd, cwd=root, capture_output=True, text=True,
                    check=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")

    print("R05 WORKER PARKING SUMMARY (instrumented vs uninstrumented)")
    for s in summary:
        print(
            f"workload={s['workload']} policy={s['policy']} "
            f"producers={s['producers']} "
            f"ratio={s['median_profile_over_baseline']:.4f}x "
            f"parks/task={s['median_parks_per_task']} "
            f"failed-steals/task={s['median_failed_steals_per_task']} "
            f"useful-after-wait={s['median_useful_after_wait_pct']}% "
            f"empty-after-wait={s['median_no_work_after_wait_pct']}% "
            f"generation-only-exit={s['median_generation_only_exit_pct']}%")
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
