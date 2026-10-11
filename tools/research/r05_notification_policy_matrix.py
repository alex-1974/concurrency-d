#!/usr/bin/env python3
"""R0.5 controlled baseline-vs-waiter-aware notification experiment.

Two policies run in fresh Linux subprocesses. The *OFF* pairs measure
uninstrumented throughput; independent *ON* pairs count actual/skipped
Condition.notify and useful post-wait searches. Each task, result,
and shutdown invariant is checked by the underlying D benchmark.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

BASE = ("metric", "scenario", "policy", "workers", "producers", "budget",
        "tasks", "elapsed_ms", "throughput_per_s", "fresh_nodes",
        "reused_nodes", "producer_gc_bytes", "used_close_delta",
        "used_after_collect_delta", "observed_handles", "completed")
PARK = ("metric", "policy", "workload", "producers", "workers", "budget",
        "tasks", "local_misses", "ingress_misses", "steal_attempts",
        "steal_successes", "park_checks", "condition_waits",
        "wait_returns", "skipped_parks", "executions",
        "ingress_notifications", "local_notifications",
        "close_broadcasts", "drain_broadcasts",
        "claimed_batches", "claimed_tasks", "peak_queued")
WAKE = ("metric", "policy", "workload", "producers", "workers", "budget",
        "tasks", "still_blocked", "exit_inbox", "exit_generation",
        "exit_drained", "useful_local", "useful_inbox",
        "useful_steal", "no_work", "drained")
NOTIFY = ("metric", "policy", "workload", "producers", "workers", "budget",
          "tasks", "mode", "ingress_calls", "ingress_skipped",
          "local_calls", "local_skipped")


def metric(text, prefix, schema, required):
    matches = [row for row in text.splitlines() if row.startswith(prefix)]
    if not required and not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError(f"expected one {prefix} row:\n{text[-4000:]}")
    values = next(csv.reader(matches))
    if len(values) != len(schema):
        raise RuntimeError(f"unexpected {prefix} CSV size: {matches[0]}")
    return dict(zip(schema, values))


def run(binary, root, workers, tasks, budget, producers, policy,
        workload, notify_mode, profile, rnd):
    command = [str(binary), str(workers), str(producers), str(tasks),
               str(budget), policy, "striped", "off", workload,
               profile, notify_mode]
    with tempfile.TemporaryFile(mode="w+t") as fd:
        proc = subprocess.Popen(
            command, cwd=root, stdout=fd, stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(proc.pid, 0)
        fd.seek(0)
        stdout = fd.read()
    code = os.waitstatus_to_exitcode(status)
    if code != 0:
        raise RuntimeError(
            f"{workload}/{policy}/{notify_mode}/{profile}/p{producers}"
            f" round={rnd} exited {code}:\n" + stdout[-7000:])

    perf = metric(stdout, "multi,mixed,", BASE, True)
    p = metric(stdout, "parking,", PARK, profile == "on")
    w = metric(stdout, "wakeup,", WAKE, profile == "on")
    n = metric(stdout, "notification,", NOTIFY, profile == "on")
    for key, expected in (
        (perf["policy"], policy), (perf["producers"], str(producers)),
        (perf["budget"], str(budget)), (perf["tasks"], str(tasks)),
        (perf["completed"], str(tasks)),
    ):
        if key != expected:
            raise RuntimeError("incomplete execution or bad workload header")
    if profile == "off" and any(line.startswith(
            ("parking,", "wakeup,", "notification,"))
            for line in stdout.splitlines()):
        raise RuntimeError("diagnostic output from unprofiled path")
    if profile == "on":
        for label, expected in (
            (n["mode"], notify_mode), (n["policy"], policy),
            (n["workload"], workload),
            (n["producers"], str(producers)),
            (p["executions"], str(tasks)),
            (p["claimed_tasks"], str(tasks)),
        ):
            if label != expected:
                raise RuntimeError("wrong notification diagnostic or task count")
        if (int(n["ingress_calls"]) + int(n["ingress_skipped"]) != tasks or
            int(n["local_calls"]) + int(n["local_skipped"]) !=
                int(p["local_notifications"])):
            raise RuntimeError("notification split accounting failed")
        if (notify_mode == "always" and (
                int(n["ingress_skipped"]) != 0 or
                int(n["local_skipped"]) != 0)):
            raise RuntimeError("baseline must not skip notification")
        exits = sum(int(w[x]) for x in
                    ("exit_inbox", "exit_generation", "exit_drained"))
        searches = sum(int(w[x]) for x in
                       ("useful_local", "useful_inbox", "useful_steal",
                        "no_work", "drained"))
        if (int(p["condition_waits"]) != int(p["wait_returns"]) or
            exits != searches or
            exits + int(w["still_blocked"]) != int(p["wait_returns"])):
            raise RuntimeError("worker wait accounting changed")

    row = {
        "round": rnd, "workload": workload, "policy": policy,
        "producers": producers, "workers": workers, "tasks": tasks,
        "budget": budget, "notify_mode": notify_mode,
        "profile": profile, "throughput_per_s": perf["throughput_per_s"],
        "elapsed_ms": perf["elapsed_ms"],
        "process_user_us": round(usage.ru_utime * 1_000_000),
        "process_system_us": round(usage.ru_stime * 1_000_000),
        "process_voluntary": usage.ru_nvcsw,
        "process_involuntary": usage.ru_nivcsw,
        "peak_rss_kib": usage.ru_maxrss,
        "producer_gc_bytes": perf["producer_gc_bytes"],
    }
    for key in NOTIFY[8:]:
        row[key] = int(n[key]) if n is not None else ""
    for key in ("condition_waits", "steal_attempts", "steal_successes"):
        row[key] = int(p[key]) if p is not None else ""
    for key in ("still_blocked", "useful_inbox", "useful_local",
                "useful_steal", "no_work", "drained", "exit_generation"):
        row[key] = int(w[key]) if w is not None else ""
    return row


def main():
    arg = argparse.ArgumentParser(description=__doc__)
    arg.add_argument("--compiler", default="ldc2")
    arg.add_argument("--workers", type=int, default=4)
    arg.add_argument("--tasks", type=int, default=30000)
    arg.add_argument("--rounds", type=int, default=5)
    arg.add_argument("--budget", type=int, default=512)
    arg.add_argument("--producers", type=int, nargs="+", default=[1, 4, 8])
    arg.add_argument("--workloads", nargs="+", default=["minimal", "compute"],
                     choices=["minimal", "compute"])
    arg.add_argument("--policies", nargs="+", default=["gc", "recycle"],
                     choices=["gc", "recycle"])
    arg.add_argument("--output", type=Path,
                     default=Path("evidence/r05-notification-policy"))
    cfg = arg.parse_args()

    if platform.system() != "Linux":
        arg.error("requires Linux wait4")
    if (cfg.workers < 1 or cfg.workers > 64 or
        cfg.tasks < 1 or cfg.tasks > 2_000_000 or
        cfg.rounds < 1 or cfg.rounds > 20 or
        cfg.budget not in (8, 64, 512, 4096) or
        not cfg.producers or not cfg.workloads or not cfg.policies or
        any(x < 1 or x > 64 for x in cfg.producers)):
        arg.error("invalid benchmark arguments")

    root = Path(__file__).resolve().parents[2]
    subprocess.run(["dub", "build",
                    "--config=task-pipeline-mixed-benchmark",
                    "--build=release", "--compiler=" + cfg.compiler,
                    "--force"], cwd=root, check=True)
    binary = root / "concurrency-task-pipeline-mixed"
    if not binary.is_file():
        raise RuntimeError("DUB executable missing")

    rows = []
    cfg.output.mkdir(parents=True, exist_ok=True)
    for rnd in range(cfg.rounds):
        for workload in cfg.workloads:
            for policy in cfg.policies:
                producers_seq = (cfg.producers if rnd % 2 == 0
                                 else list(reversed(cfg.producers)))
                for producers in producers_seq:
                    # Rotate policy first to avoid a static always->waiter
                    # clock/power-order bias within each matched round.
                    modes = ("always", "waiter") if rnd % 2 == 0 else (
                        "waiter", "always")
                    for profile in ("off", "on"):
                        for mode in modes:
                            row = run(binary, root, cfg.workers, cfg.tasks,
                                      cfg.budget, producers, policy,
                                      workload, mode, profile, rnd)
                            rows.append(row)
                            print(
                                f"R05 notify workload={workload} "
                                f"policy={policy} producers={producers} "
                                f"profile={profile} notify={mode} "
                                f"round={rnd} rate={row['throughput_per_s']} "
                                f"calls={row['ingress_calls']} "
                                f"skipped={row['ingress_skipped']}",
                                flush=True,
                            )
    with (cfg.output / "raw.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    keyed = {}
    for row in rows:
        key = (row["round"], row["workload"], row["policy"],
               row["producers"], row["profile"], row["notify_mode"])
        if key in keyed:
            raise RuntimeError("duplicate case")
        keyed[key] = row

    summaries = []
    for workload in cfg.workloads:
        for policy in cfg.policies:
            for p in cfg.producers:
                paired = [
                    (keyed[r, workload, policy, p, "off", "always"],
                     keyed[r, workload, policy, p, "off", "waiter"])
                    for r in range(cfg.rounds)]
                profile = [
                    keyed[r, workload, policy, p, "on", "waiter"]
                    for r in range(cfg.rounds)]
                ratios = [float(c["throughput_per_s"]) /
                          float(b["throughput_per_s"]) for b, c in paired]
                median = statistics.median
                summaries.append({
                    "workload": workload, "policy": policy,
                    "producers": p, "rounds": cfg.rounds,
                    "paired_waiter_over_baseline": round(median(ratios), 4),
                    "waiter_wins": sum(x > 1 for x in ratios),
                    "median_baseline_tps": round(median(
                        float(x["throughput_per_s"]) for x, _ in paired), 1),
                    "median_waiter_tps": round(median(
                        float(x["throughput_per_s"]) for _, x in paired), 1),
                    "median_candidate_ingress_skipped_pct": round(
                        median(100 * x["ingress_skipped"] / cfg.tasks
                               for x in profile), 2),
                    "median_candidate_condition_waits_per_task": round(
                        median(x["condition_waits"] / cfg.tasks
                               for x in profile), 4),
                    "median_candidate_no_work_after_wait_pct": round(
                        median(100 * x["no_work"] / max(
                            1, x["condition_waits"] - x["still_blocked"])
                               for x in profile), 2),
                    "median_candidate_process_switches": median(
                        x["process_voluntary"] + x["process_involuntary"]
                        for x in profile),
                })
    with (cfg.output / "summary.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)

    with (cfg.output / "environment.txt").open("w") as f:
        f.write(f"compiler={cfg.compiler}\nplatform={platform.platform()}\n"
                f"machine={platform.machine()}\n"
                f"workers={cfg.workers} tasks={cfg.tasks} rounds={cfg.rounds}\n"
                f"budget={cfg.budget} producers={cfg.producers}\n"
                f"workloads={cfg.workloads} policies={cfg.policies}\n"
                f"profiles=['off','on'] notification_modes=['always','waiter']\n")
        for command in (["git", "rev-parse", "HEAD"],
                        [cfg.compiler, "--version"], ["lscpu"],
                        ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            try:
                f.write("$ " + " ".join(command) + "\n")
                f.write(subprocess.run(command, cwd=root,
                        capture_output=True, check=True, text=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                f.write("unavailable\n")

    print("R05 NOTIFICATION POLICY (uninstrumented paired throughput)")
    for row in summaries:
        print(f"workload={row['workload']} policy={row['policy']} "
              f"producers={row['producers']} "
              f"waiter/always={row['paired_waiter_over_baseline']}x "
              f"wins={row['waiter_wins']}/{row['rounds']} "
              f"candidate-skipped={row['median_candidate_ingress_skipped_pct']}%")
    print("evidence: " + str(cfg.output))


if __name__ == "__main__":
    main()
