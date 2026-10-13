#!/usr/bin/env python3
"""Same-source worker resource vs existing parking/wake/steal counters.

No new scheduler instrumentation. Three modes in separate Linux children:
* plain: original uninstrumented full-victim binary, parking=off;
* worker: opt-in worker start/end getrusage binary, parking=off;
* combined: SAME worker binary, existing parking/wakeup counters ON.
Within each case the worker/combined modes share a binary hash.
The third mode changes observation overhead, not scheduler policy.
"""
import argparse
import csv
import hashlib
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

from r05_native_cpu_profile import (
    BUILD_CONFIG, BINARY, FIELDS, RESOURCE, command_output,
    parse_line, write_csv,
)
from r05_worker_resource_matrix import WORKER, WORKER_NUMERIC, CONFIGS
from r05_worker_parking_matrix import PARK, WAKE, read_metric

MODES = ("plain", "worker", "combined")


def median_defined(rows, key):
    """Preserve missing first-search ratios when no worker exited a wait."""
    values = [row[key] for row in rows if row[key] != ""]
    return statistics.median(values) if values else ""


NOTIFY = (
    "metric", "policy", "workload", "producers", "workers",
    "budget", "tasks", "notify_policy", "ingress_calls",
    "ingress_skipped", "local_calls", "local_skipped",
)


def execute(root, binaries, hashes, rnd, workload, producers, policy,
            mode, workers, tasks, budget, counter):
    parking = "on" if mode == "combined" else "off"
    worker_mode = mode != "plain"
    binary = binaries["worker" if worker_mode else "off"]
    args = [
        str(binary), str(workers), str(producers), str(tasks),
        str(budget), policy, counter, "off", workload, parking, "always",
    ]
    start = time.monotonic_ns()
    with tempfile.TemporaryFile(mode="w+t") as log:
        child = subprocess.Popen(args, cwd=root, stdout=log,
                                 stderr=subprocess.STDOUT, text=True)
        _, status, usage = os.wait4(child.pid, 0)
        wall_ns = time.monotonic_ns() - start
        log.seek(0)
        output = log.read()
    if os.waitstatus_to_exitcode(status):
        raise RuntimeError("child failed " + repr(args) + "\n" +
                           output[-6000:])

    perf = parse_line(output, "multi,mixed,", FIELDS)
    producer = parse_line(output, "resource,", RESOURCE)
    checksum = parse_line(
        output, "workload,",
        ("metric", "workload", "compute_rounds", "checksum"))
    worker_lines = [v for v in output.splitlines()
                    if v.startswith("worker-resource,")]
    if len(worker_lines) != (workers if worker_mode else 0):
        raise RuntimeError("missing/unexpected indexed worker resources")
    park = read_metric(output, "parking,", PARK, required=parking == "on")
    wake = read_metric(output, "wakeup,", WAKE, required=parking == "on")
    notification = read_metric(
        output, "notification,", NOTIFY, required=parking == "on")
    if parking == "off" and any(x is not None
                                for x in (park, wake, notification)):
        raise RuntimeError("OFF mode leaked parking/wakeup counters")
    if (perf["policy"] != policy or perf["scenario"] != "mixed" or
            int(perf["workers"]) != workers or
            int(perf["producers"]) != producers or
            int(perf["tasks"]) != tasks or
            int(perf["budget"]) != budget or
            int(perf["completed"]) != tasks or
            int(perf["fresh_nodes"]) + int(perf["reused_nodes"]) != tasks or
            int(perf["observed_handles"]) < 1 or
            float(perf["throughput_per_s"]) <= 0 or
            checksum["workload"] != workload or
            int(checksum["compute_rounds"]) !=
            (1024 if workload == "compute" else 0) or
            producer["policy"] != policy or
            producer["counter_mode"] != counter or
            int(producer["workers"]) != workers or
            int(producer["producers"]) != producers or
            int(producer["budget"]) != budget or
            int(producer["tasks"]) != tasks):
        raise RuntimeError("task/producer/workload metadata mismatch")
    row = dict(
        round=rnd, mode=mode, workload=workload, producers=producers,
        policy=policy, workers=workers, budget=budget,
        tasks=tasks, counter=counter,
        parking=parking, notify_policy="always",
        binary_sha256=hashes["worker" if worker_mode else "off"],
        throughput_per_s=float(perf["throughput_per_s"]),
        completed=int(perf["completed"]),
        fresh_nodes=int(perf["fresh_nodes"]),
        reused_nodes=int(perf["reused_nodes"]),
        observed_handles=int(perf["observed_handles"]),
        checksum=checksum["checksum"],
        child_cpu_us=(usage.ru_utime + usage.ru_stime) * 1_000_000,
        child_voluntary=usage.ru_nvcsw,
        child_involuntary=usage.ru_nivcsw,
        peak_rss_kib=usage.ru_maxrss,
        external_wall_ms=wall_ns / 1_000_000,
        timed_elapsed_ms=float(perf["elapsed_ms"]),
        producer_cpu_us=(int(producer["producer_user_us"]) +
                         int(producer["producer_system_us"])),
        producer_voluntary=int(producer["producer_voluntary"]),
        producer_involuntary=int(producer["producer_involuntary"]),
    )
    if row["external_wall_ms"] + 0.01 < row["timed_elapsed_ms"]:
        raise RuntimeError("process wall < benchmark internal timer")

    samples = []
    for line in worker_lines:
        fields = next(csv.reader([line]))
        if len(fields) != len(WORKER):
            raise RuntimeError("worker resource CSV width")
        w = dict(zip(WORKER, fields))
        if (w["policy"] != policy or w["counter_mode"] != counter or
                int(w["workers"]) != workers or
                int(w["producers"]) != producers or
                int(w["budget"]) != budget or
                int(w["tasks"]) != tasks or w["sampled"] != "1"):
            raise RuntimeError("worker resource identity/sample marker")
        sample = dict(
            round=rnd, workload=workload, producers=producers,
            policy=policy, mode=mode, budget=budget,
            worker_index=int(w["worker_index"]),
        )
        sample.update({key: int(w[key]) for key in WORKER_NUMERIC})
        sample["cpu_us"] = sample["cpu_user_us"] + sample["cpu_system_us"]
        samples.append(sample)
    if len({x["worker_index"] for x in samples}) != len(samples) or any(
            not 0 <= x["worker_index"] < workers for x in samples):
        raise RuntimeError("duplicate/out-of-range worker resource identity")
    row["worker_count"] = len(samples) if worker_mode else ""
    row["worker_cpu_us"] = sum(x["cpu_us"] for x in samples) if worker_mode else ""
    row["worker_voluntary"] = (sum(x["voluntary_switches"] for x in samples)
                                if worker_mode else "")
    row["worker_involuntary"] = (sum(x["involuntary_switches"] for x in samples)
                                  if worker_mode else "")
    row["other_cpu_us"] = (row["child_cpu_us"] - row["worker_cpu_us"]
                           - row["producer_cpu_us"] if worker_mode else "")
    row["other_voluntary"] = (
        row["child_voluntary"] - row["worker_voluntary"] -
        row["producer_voluntary"] if worker_mode else "")

    for metric in PARK[7:]:
        row[metric] = int(park[metric]) if park is not None else ""
    for metric in WAKE[7:]:
        row[metric] = int(wake[metric]) if wake is not None else ""
    for metric in NOTIFY[8:]:
        row[metric] = int(notification[metric]) if notification is not None else ""
    if park is not None:
        if (park["policy"] != policy or park["workload"] != workload or
                int(park["producers"]) != producers or
                int(park["workers"]) != workers or
                int(park["budget"]) != budget or
                int(park["tasks"]) != tasks or
                wake["policy"] != policy or wake["workload"] != workload or
                int(wake["producers"]) != producers or
                int(wake["workers"]) != workers or
                int(wake["budget"]) != budget or
                int(wake["tasks"]) != tasks or
                notification["notify_policy"] != "always" or
                notification["policy"] != policy or
                notification["workload"] != workload or
                int(notification["producers"]) != producers or
                int(notification["workers"]) != workers or
                int(notification["budget"]) != budget or
                int(notification["tasks"]) != tasks):
            raise RuntimeError("parking/wakeup/notification metadata mismatch")
        final_wait = sum(row[k] for k in (
            "exit_inbox", "exit_generation", "exit_drained"))
        useful = sum(row[k] for k in (
            "useful_local", "useful_inbox", "useful_steal"))
        if (row["condition_waits"] != row["wait_returns"] or
                row["condition_waits"] !=
                row["still_blocked"] + final_wait or
                final_wait != useful + row["no_work"] + row["drained"] or
                row["steal_successes"] > row["steal_attempts"] or
                row["executions"] != tasks or
                row["claimed_tasks"] != tasks or
                row["ingress_notifications"] != tasks or
                row["peak_queued"] > 64 or
                row["ingress_calls"] != tasks or
                row["ingress_skipped"] != 0 or
                row["local_calls"] != row["local_notifications"] or
                row["local_skipped"] != 0 or
                row["claimed_batches"] <= 0):
            raise RuntimeError("parking/wake/task/notify conservation mismatch")
        row["failed_steals"] = (
            row["steal_attempts"] - row["steal_successes"])
        row["final_wait_exits"] = final_wait
        row["useful_first_search"] = useful
        row["useful_first_search_fraction"] = (
            useful / final_wait if final_wait else "")
        row["empty_first_search_fraction"] = (
            row["no_work"] / final_wait if final_wait else "")
        row["condition_waits_per_task"] = row["condition_waits"] / tasks
        row["failed_steals_per_task"] = row["failed_steals"] / tasks
        row["claimed_per_batch"] = (
            row["claimed_tasks"] / row["claimed_batches"])
        row["worker_voluntary_per_condition_wait_diagnostic"] = (
            row["worker_voluntary"] / row["condition_waits"]
            if row["condition_waits"] else "")
    else:
        for label in (
            "failed_steals", "final_wait_exits", "useful_first_search",
            "useful_first_search_fraction", "empty_first_search_fraction",
            "condition_waits_per_task", "failed_steals_per_task",
            "claimed_per_batch",
            "worker_voluntary_per_condition_wait_diagnostic",
        ):
            row[label] = ""
    return row, samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=30000)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--producers", nargs="+", type=int, default=[1, 4, 8])
    parser.add_argument("--budget", type=int, default=512,
                        choices=[8, 64, 512, 4096])
    parser.add_argument("--policies", nargs="+", choices=["gc", "recycle"],
                        default=["gc", "recycle"])
    parser.add_argument("--workloads", nargs="+",
                        choices=["minimal", "compute"],
                        default=["minimal", "compute"])
    parser.add_argument("--counter", choices=["shared", "striped"],
                        default="shared")
    parser.add_argument("--cooldown-ms", type=int, default=50)
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-parking-worker-correlation"))
    a = parser.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= a.rounds <= 20 or not 1 <= a.workers <= 64 or
            not 1 <= a.tasks <= 2_000_000 or
            not a.producers or not a.policies or not a.workloads or
            len(set(a.producers)) != len(a.producers) or
            len(set(a.policies)) != len(a.policies) or
            len(set(a.workloads)) != len(a.workloads) or
            any(not 1 <= n <= 64 for n in a.producers) or
            not 0 <= a.cooldown_ms <= 10000):
        parser.error("invalid bounded study parameters")
    root = Path(__file__).resolve().parents[2]
    binaries, hashes = {}, {}
    for name, (config, executable) in CONFIGS.items():
        command_output(["dub", "build", "--config=" + config,
                        "--build=release", "--compiler=" + a.compiler,
                        "--force"], root)
        target = root / executable
        if not target.is_file():
            raise RuntimeError("missing DUB benchmark " + executable)
        binaries[name] = target
        hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    rows, workers = [], []
    for rnd in range(a.rounds):
        for workload in a.workloads:
            for producers in a.producers:
                for policy in a.policies:
                    order = list(MODES)
                    if (rnd + producers + a.policies.index(policy)) % 2:
                        order.reverse()
                    for mode in order:
                        row, details = execute(
                            root, binaries, hashes, rnd, workload, producers,
                            policy, mode, a.workers, a.tasks, a.budget,
                            a.counter)
                        rows.append(row)
                        workers.extend(details)
                        print("R05 worker-parking", rnd, workload, producers,
                              policy, mode, "rate",
                              round(row["throughput_per_s"]),
                              "worker_voluntary", row["worker_voluntary"],
                              "waits", row["condition_waits"], flush=True)
                        if a.cooldown_ms:
                            time.sleep(a.cooldown_ms / 1000)
    expected = (a.rounds * len(a.workloads) * len(a.producers) *
                len(a.policies) * len(MODES))
    cases = {(r["round"], r["workload"], r["producers"],
              r["policy"], r["mode"]): r for r in rows}
    if len(rows) != expected or len(cases) != expected:
        raise RuntimeError("incomplete unique three-mode factorial")
    observed_workers = (expected // 3 * 2 * a.workers)
    if len(workers) != observed_workers:
        raise RuntimeError("incomplete worker resource slots")
    if len({(w["round"], w["workload"], w["producers"], w["policy"],
             w["mode"], w["worker_index"]) for w in workers}) != len(workers):
        raise RuntimeError("duplicate worker resource slot")
    checksums = {}
    for r in rows:
        checksums.setdefault(r["workload"], set()).add(r["checksum"])
        if r["binary_sha256"] != hashes[
                "off" if r["mode"] == "plain" else "worker"]:
            raise RuntimeError("build hash identity lost")
    if any(len(values) != 1 for values in checksums.values()):
        raise RuntimeError("workload checksum diverges across modes")

    write_csv(out / "raw.csv", rows)
    write_csv(out / "worker.csv", workers)
    pairs, summary = [], []
    for workload in a.workloads:
        for producers in a.producers:
            for policy in a.policies:
                group = []
                for rnd in range(a.rounds):
                    key = (rnd, workload, producers, policy)
                    plain = cases[(*key, "plain")]
                    only = cases[(*key, "worker")]
                    combined = cases[(*key, "combined")]
                    paired = dict(
                        round=rnd, workload=workload, producers=producers,
                        policy=policy, budget=a.budget,
                        worker_over_plain=(
                            only["throughput_per_s"] /
                            plain["throughput_per_s"]),
                        combined_over_worker=(
                            combined["throughput_per_s"] /
                            only["throughput_per_s"]),
                        plain_tasks_per_s=plain["throughput_per_s"],
                        worker_tasks_per_s=only["throughput_per_s"],
                        combined_tasks_per_s=combined["throughput_per_s"],
                        worker_voluntary_only=only["worker_voluntary"],
                        worker_voluntary_combined=combined["worker_voluntary"],
                        producer_voluntary_only=only["producer_voluntary"],
                        producer_voluntary_combined=combined["producer_voluntary"],
                        worker_cpu_us_only=only["worker_cpu_us"],
                        worker_cpu_us_combined=combined["worker_cpu_us"],
                        producer_cpu_us_only=only["producer_cpu_us"],
                        producer_cpu_us_combined=combined["producer_cpu_us"],
                        condition_waits_combined=combined["condition_waits"],
                        failed_steals_combined=combined["failed_steals"],
                        useful_fraction_combined=combined[
                            "useful_first_search_fraction"],
                        empty_fraction_combined=combined[
                            "empty_first_search_fraction"])
                    pairs.append(paired)
                    group.append(paired)
                series = [cases[(rnd, workload, producers, policy,
                                 "combined")] for rnd in range(a.rounds)]
                summary.append(dict(
                    workload=workload, producers=producers, policy=policy,
                    rounds=a.rounds,
                    median_condition_waits_per_task=statistics.median(
                        r["condition_waits_per_task"] for r in series),
                    median_failed_steals_per_task=statistics.median(
                        r["failed_steals_per_task"] for r in series),
                    median_empty_first_search_fraction=median_defined(
                        series, "empty_first_search_fraction"),
                    median_useful_first_search_fraction=median_defined(
                        series, "useful_first_search_fraction"),
                    median_worker_voluntary_per_30k=statistics.median(
                        r["worker_voluntary"] for r in series),
                    median_producer_voluntary_per_30k=statistics.median(
                        r["producer_voluntary"] for r in series),
                    median_worker_cpu_us_per_30k=statistics.median(
                        r["worker_cpu_us"] for r in series),
                    median_producer_cpu_us_per_30k=statistics.median(
                        r["producer_cpu_us"] for r in series),
                    median_combined_over_worker=statistics.median(
                        r["combined_over_worker"] for r in group),
                    median_worker_over_plain=statistics.median(
                        r["worker_over_plain"] for r in group)))
    write_csv(out / "pairs.csv", pairs)
    write_csv(out / "summary.csv", summary)

    # Pure post-processing: use only existing worker-owned counters from
    # completed/joined 'combined' cases. No new D task or mutex probes.
    # Ratios are calculated within each process, then medians of those
    # independent process ratios are taken (never quotient of medians).
    acquisition = []
    for r in rows:
        if r["mode"] != "combined":
            continue
        attempts = r["steal_attempts"]
        successes = r["steal_successes"]
        final_exits = r["final_wait_exits"]
        if (r["failed_steals"] != attempts - successes or
                r["claimed_tasks"] != a.tasks or
                r["executions"] != a.tasks or
                r["claimed_batches"] <= 0):
            raise RuntimeError("work acquisition conservation mismatch")
        record = dict(
            round=r["round"], workload=r["workload"],
            producers=r["producers"], policy=r["policy"],
            tasks=a.tasks,
            local_misses_per_task=r["local_misses"] / a.tasks,
            ingress_misses_per_task=r["ingress_misses"] / a.tasks,
            steal_attempts_per_task=attempts / a.tasks,
            failed_steals_per_task=r["failed_steals"] / a.tasks,
            steal_success_fraction=(
                successes / attempts if attempts else ""),
            failed_per_successful_steal=(
                r["failed_steals"] / successes if successes else ""),
            park_checks_per_task=r["park_checks"] / a.tasks,
            condition_waits_per_task=r["condition_waits"] / a.tasks,
            tasks_per_claimed_batch=a.tasks / r["claimed_batches"],
            first_search_empty_fraction=(
                r["no_work"] / final_exits if final_exits else ""),
        )
        acquisition.append(record)
    if len(acquisition) != expected // 3:
        raise RuntimeError("missing acquisition diagnostic cases")
    write_csv(out / "acquisition.csv", acquisition)
    acquired = []
    for workload in a.workloads:
        for producers in a.producers:
            for policy in a.policies:
                group = [r for r in acquisition
                         if r["workload"] == workload and
                         r["producers"] == producers and
                         r["policy"] == policy]
                if len(group) != a.rounds:
                    raise RuntimeError("incomplete acquisition group")
                item = dict(workload=workload, producers=producers,
                            policy=policy, runs=len(group))
                for metric in (
                    "local_misses_per_task", "ingress_misses_per_task",
                    "steal_attempts_per_task", "failed_steals_per_task",
                    "steal_success_fraction", "failed_per_successful_steal",
                    "park_checks_per_task", "condition_waits_per_task",
                    "tasks_per_claimed_batch",
                    "first_search_empty_fraction",
                ):
                    measured = [r[metric] for r in group
                                if r[metric] != ""]
                    item["median_" + metric] = (
                        statistics.median(measured) if measured else "")
                acquired.append(item)
    write_csv(out / "acquisition_summary.csv", acquired)

    with (out / "environment.txt").open("w") as f:
        f.write("benchmark=r05-full-victim-worker-parking-correlation\n")
        f.write("research_head=" + command_output(
            ["git", "rev-parse", "HEAD"], root).stdout.strip() + "\n")
        f.write("modes=plain,worker,combined\n")
        f.write("control_config=" + BUILD_CONFIG + "\n")
        f.write("worker_config=" + CONFIGS["worker"][0] + "\n")
        f.write("control_sha256=" + hashes["off"] + "\n")
        f.write("worker_sha256=" + hashes["worker"] + "\n")
        f.write("worker and combined execute IDENTICAL worker binary SHA\n")
        f.write("counter_mode=" + a.counter + "\n")
        f.write(f"workers={a.workers} tasks={a.tasks} rounds={a.rounds}"
                f" producers={a.producers} budget={a.budget}"
                f" policies={a.policies} workloads={a.workloads}\n")
        f.write("NotificationPolicy.always in every child\n")
        f.write("No new Task-path instrumentation; combined reuses"
                " preexisting parkingProfile runtime counters.\n")
        f.write("Combined worker CPU and switches can be perturbed by"
                " the parking counters, unlike the worker-only control.\n")
        f.write("acquisition.csv and acquisition_summary.csv are "
                "post-join derived measurements from combined-mode counters\n")
        f.write("Condition waits are NOT equivalent to voluntary"
                " context switches or notified worker handoffs.\n")
        for cmd in ([a.compiler, "--version"], ["dub", "--version"],
                    ["lscpu"], ["git", "status", "--short",
                                "--untracked-files=no"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            f.write("$ " + " ".join(cmd) + "\n")
            r = command_output(cmd, root, allow_failure=True)
            f.write((r.stdout if r.returncode == 0 else
                    "unavailable: " + r.stderr[-250:]) + "\n")
        f.write("platform=" + platform.platform() + "\n")
    print("PASS: three-mode same-source state/resource probe", out)


if __name__ == "__main__":
    main()
