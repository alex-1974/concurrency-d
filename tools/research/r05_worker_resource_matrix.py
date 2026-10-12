#!/usr/bin/env python3
"""Paired R0.5 worker-thread boundary getrusage diagnostics.

An unchanged full-victim release binary is the OFF control. A distinct
release binary adds only worker startup/shutdown RUSAGE_THREAD samples.
Both run uninstrumented Task submit, worker parking profiler OFF, and
NotificationPolicy.always. Profiling versions are not treated as equal
codegen for speedup claims; ON/OFF is an observer-effect diagnostic.
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
    BUILD_CONFIG, BINARY, FIELDS, RESOURCE,
    command_output, parse_line, write_csv,
)

CONFIGS = {
    "off": (BUILD_CONFIG, BINARY),
    "worker": (
        "task-pipeline-mixed-full-victim-worker-resource",
        "concurrency-task-pipeline-mixed-full-victim-worker-resource",
    ),
}
WORKER = (
    "metric", "policy", "counter_mode", "workers", "producers", "budget",
    "tasks", "worker_index", "cpu_user_us", "cpu_system_us",
    "voluntary_switches", "involuntary_switches",
    "minor_faults", "major_faults", "sampled",
)
WORKER_NUMERIC = (
    "cpu_user_us", "cpu_system_us", "voluntary_switches",
    "involuntary_switches", "minor_faults", "major_faults",
)


def run_child(root, binary, mode, rnd, workload, producers, policy,
              workers, tasks, budget, counter):
    consumer = [
        str(binary), str(workers), str(producers), str(tasks),
        str(budget), policy, counter, "off", workload, "off", "always",
    ]
    start = time.monotonic_ns()
    with tempfile.TemporaryFile(mode="w+t") as log:
        proc = subprocess.Popen(consumer, cwd=root, text=True, stdout=log,
                                stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(proc.pid, 0)
        elapsed_ns = time.monotonic_ns() - start
        log.seek(0)
        output = log.read()
    if os.waitstatus_to_exitcode(status):
        raise RuntimeError("failed " + repr(consumer) + "\n" +
                           output[-6000:])
    perf = parse_line(output, "multi,mixed,", FIELDS)
    producer = parse_line(output, "resource,", RESOURCE)
    workload_row = parse_line(
        output, "workload,",
        ("metric", "workload", "compute_rounds", "checksum"))
    worker_lines = [line for line in output.splitlines()
                    if line.startswith("worker-resource,")]
    if len(worker_lines) != (workers if mode == "worker" else 0):
        raise RuntimeError("wrong worker row count")

    if (perf["scenario"] != "mixed" or perf["policy"] != policy or
            int(perf["workers"]) != workers or
            int(perf["producers"]) != producers or
            int(perf["budget"]) != budget or
            int(perf["tasks"]) != tasks or
            int(perf["completed"]) != tasks or
            int(perf["fresh_nodes"]) + int(perf["reused_nodes"]) != tasks or
            int(perf["observed_handles"]) < 1 or
            float(perf["throughput_per_s"]) <= 0 or
            workload_row["workload"] != workload or
            int(workload_row["compute_rounds"]) !=
            (1024 if workload == "compute" else 0) or
            producer["policy"] != policy or
            producer["counter_mode"] != counter or
            int(producer["workers"]) != workers or
            int(producer["producers"]) != producers or
            int(producer["tasks"]) != tasks):
        raise RuntimeError("benchmark completion/producer/workload mismatch")

    row = dict(
        round=rnd, mode=mode, workload=workload,
        producers=producers, policy=policy, workers=workers, tasks=tasks,
        budget=budget, counter=counter,
        throughput_per_s=float(perf["throughput_per_s"]),
        observed_handles=int(perf["observed_handles"]),
        completed=int(perf["completed"]),
        checksum=workload_row["checksum"],
        fresh_nodes=int(perf["fresh_nodes"]),
        reused_nodes=int(perf["reused_nodes"]),
        producer_gc_bytes=int(perf["producer_gc_bytes"]),
        timed_elapsed_ms=float(perf["elapsed_ms"]),
        external_wall_ms=elapsed_ns / 1_000_000,
        child_user_us=usage.ru_utime * 1_000_000,
        child_system_us=usage.ru_stime * 1_000_000,
        child_voluntary_switches=usage.ru_nvcsw,
        child_involuntary_switches=usage.ru_nivcsw,
        child_minor_faults=usage.ru_minflt,
        child_major_faults=usage.ru_majflt,
        peak_rss_kib=usage.ru_maxrss,
        producer_user_us=int(producer["producer_user_us"]),
        producer_system_us=int(producer["producer_system_us"]),
        producer_voluntary_switches=int(producer["producer_voluntary"]),
        producer_involuntary_switches=int(producer["producer_involuntary"]),
    )
    row["producer_cpu_us"] = (
        row["producer_user_us"] + row["producer_system_us"])
    row["child_cpu_us"] = row["child_user_us"] + row["child_system_us"]
    row["cpu_other_than_producer_us"] = (
        row["child_cpu_us"] - row["producer_cpu_us"])
    if row["cpu_other_than_producer_us"] < -500:
        raise RuntimeError("producer CPU exceeds whole-process CPU")

    samples = []
    for line in worker_lines:
        fields = next(csv.reader([line]))
        if len(fields) != len(WORKER):
            raise RuntimeError("unexpected worker schema width")
        data = dict(zip(WORKER, fields))
        if (data["policy"] != policy or
                data["counter_mode"] != counter or
                int(data["workers"]) != workers or
                int(data["producers"]) != producers or
                int(data["budget"]) != budget or
                int(data["tasks"]) != tasks or
                data["sampled"] != "1"):
            raise RuntimeError("incorrect worker metadata/sampling")
        worker = dict(round=rnd, mode=mode, workload=workload,
                      producers=producers, policy=policy, counter=counter,
                      budget=budget, worker_index=int(data["worker_index"]))
        worker.update({key: int(data[key]) for key in WORKER_NUMERIC})
        worker["worker_cpu_us"] = (
            worker["cpu_user_us"] + worker["cpu_system_us"])
        samples.append(worker)
    if len({w["worker_index"] for w in samples}) != len(samples) or any(
            w["worker_index"] not in range(workers) for w in samples):
        raise RuntimeError("missing or duplicate worker index")

    for metric in WORKER_NUMERIC:
        row["worker_" + metric] = sum(w[metric] for w in samples) if (
            mode == "worker") else ""
    row["worker_cpu_us"] = (sum(w["worker_cpu_us"] for w in samples)
                            if mode == "worker" else "")
    row["worker_count"] = len(samples) if mode == "worker" else ""
    row["worker_cpu_us_per_task"] = (
        row["worker_cpu_us"] / tasks if mode == "worker" else "")
    row["worker_voluntary_per_task"] = (
        row["worker_voluntary_switches"] / tasks if mode == "worker" else "")
    row["producer_cpu_us_per_task"] = row["producer_cpu_us"] / tasks
    row["child_cpu_us_per_task"] = row["child_cpu_us"] / tasks
    row["child_voluntary_per_task"] = (
        row["child_voluntary_switches"] / tasks)
    row["nonproducer_nonworker_cpu_us"] = (
        row["child_cpu_us"] - row["producer_cpu_us"] -
        row["worker_cpu_us"] if mode == "worker" else "")
    row["nonproducer_nonworker_voluntary"] = (
        row["child_voluntary_switches"] -
        row["producer_voluntary_switches"] -
        row["worker_voluntary_switches"] if mode == "worker" else "")
    if mode == "worker":
        # Microsecond rounding and start/stop sample boundaries can make
        # a small signed residual; it is not per-main-thread exact.
        row["min_worker_cpu_us"] = min(w["worker_cpu_us"] for w in samples)
        row["max_worker_cpu_us"] = max(w["worker_cpu_us"] for w in samples)
        row["max_over_min_worker_cpu"] = (
            row["max_worker_cpu_us"] / row["min_worker_cpu_us"]
            if row["min_worker_cpu_us"] else "")
    else:
        row["min_worker_cpu_us"] = ""
        row["max_worker_cpu_us"] = ""
        row["max_over_min_worker_cpu"] = ""
    return row, samples


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--tasks", type=int, default=30000)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--producers", nargs="+", type=int, default=[1, 4, 8])
    p.add_argument("--budget", type=int, default=512,
                   choices=[8, 64, 512, 4096])
    p.add_argument("--policies", nargs="+", choices=["gc", "recycle"],
                   default=["gc", "recycle"])
    p.add_argument("--workloads", nargs="+", choices=["minimal", "compute"],
                   default=["minimal", "compute"])
    p.add_argument("--counter", choices=["shared", "striped"],
                   default="shared")
    p.add_argument("--cooldown-ms", type=int, default=50)
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-worker-resources"))
    args = p.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= args.rounds <= 20 or
            not 1 <= args.workers <= 64 or
            not 1 <= args.tasks <= 2_000_000 or
            not args.producers or not args.policies or not args.workloads or
            len(set(args.producers)) != len(args.producers) or
            len(set(args.policies)) != len(args.policies) or
            len(set(args.workloads)) != len(args.workloads) or
            any(not 1 <= n <= 64 for n in args.producers) or
            not 0 <= args.cooldown_ms <= 10000):
        p.error("invalid research matrix parameters")

    root = Path(__file__).resolve().parents[2]
    binaries = {}
    digests = {}
    for mode, (config, name) in CONFIGS.items():
        command_output(["dub", "build", "--config=" + config,
                        "--build=release", "--compiler=" + args.compiler,
                        "--force"], root)
        binary = root / name
        if not binary.is_file():
            raise RuntimeError("missing " + str(binary))
        binaries[mode] = binary
        digests[mode] = hashlib.sha256(binary.read_bytes()).hexdigest()

    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    rows, worker_rows = [], []
    for rnd in range(args.rounds):
        for workload in args.workloads:
            for producers in args.producers:
                for policy in args.policies:
                    modes = ("off", "worker") if (
                        (rnd + producers + args.policies.index(policy)) % 2
                        == 0) else ("worker", "off")
                    for mode in modes:
                        row, samples = run_child(
                            root, binaries[mode], mode, rnd, workload,
                            producers, policy, args.workers, args.tasks,
                            args.budget, args.counter)
                        row["binary_sha256"] = digests[mode]
                        rows.append(row)
                        worker_rows.extend(samples)
                        print("R05 worker", rnd, workload, producers, policy,
                              mode, "rate", round(row["throughput_per_s"]),
                              "worker-switches",
                              row["worker_voluntary_switches"], flush=True)
                        if args.cooldown_ms:
                            time.sleep(args.cooldown_ms / 1000)
    expect = (args.rounds * len(args.workloads) * len(args.producers) *
              len(args.policies) * len(CONFIGS))
    if len(rows) != expect or len(worker_rows) != expect // 2 * args.workers:
        raise RuntimeError("missing source cases or worker rows")
    cases = {(r["round"], r["workload"], r["producers"],
              r["policy"], r["mode"]): r for r in rows}
    if len(cases) != expect:
        raise RuntimeError("duplicate source scenarios")

    checksums = {}
    for r in rows:
        checksums.setdefault(r["workload"], set()).add(r["checksum"])
        if r["binary_sha256"] != digests[r["mode"]]:
            raise RuntimeError("binary provenance mismatch")
    if any(len(values) != 1 for values in checksums.values()):
        raise RuntimeError("workload computation mismatch across modes")

    # Existing qualified writer uses the first row's column set.
    # Both modes above return an identical dictionary schema (empty
    # worker counters only in OFF rows).
    write_csv(out / "raw.csv", rows)
    write_csv(out / "worker.csv", worker_rows)
    pairs, summary, scaling = [], [], []
    for workload in args.workloads:
        for producers in args.producers:
            for policy in args.policies:
                group = []
                for rnd in range(args.rounds):
                    off = cases[(rnd, workload, producers, policy, "off")]
                    on = cases[(rnd, workload, producers, policy, "worker")]
                    pair = dict(
                        round=rnd, workload=workload, producers=producers,
                        policy=policy, budget=args.budget,
                        worker_profile_over_off=(
                            on["throughput_per_s"] /
                            off["throughput_per_s"]),
                        off_tasks_per_s=off["throughput_per_s"],
                        profiled_tasks_per_s=on["throughput_per_s"],
                        off_child_voluntary=off["child_voluntary_switches"],
                        profiled_child_voluntary=on[
                            "child_voluntary_switches"],
                        off_child_cpu_us=off["child_cpu_us"],
                        profiled_child_cpu_us=on["child_cpu_us"],
                        profiled_worker_cpu_us=on["worker_cpu_us"],
                        profiled_worker_voluntary=on[
                            "worker_voluntary_switches"],
                        profiled_producer_cpu_us=on["producer_cpu_us"],
                        profiled_producer_voluntary=on[
                            "producer_voluntary_switches"])
                    group.append(pair)
                    pairs.append(pair)
                summary.append(dict(
                    workload=workload, producers=producers,
                    policy=policy, rounds=len(group),
                    median_profiled_over_off=statistics.median(
                        r["worker_profile_over_off"] for r in group),
                    median_profiled_worker_cpu_us=statistics.median(
                        r["profiled_worker_cpu_us"] for r in group),
                    median_profiled_worker_voluntary=statistics.median(
                        r["profiled_worker_voluntary"] for r in group),
                    median_profiled_producer_cpu_us=statistics.median(
                        r["profiled_producer_cpu_us"] for r in group),
                    median_profiled_producer_voluntary=statistics.median(
                        r["profiled_producer_voluntary"] for r in group)))
                if producers != 1 and 1 in args.producers:
                    for mode in CONFIGS:
                        vals = []
                        for rnd in range(args.rounds):
                            one = cases[(rnd, workload, 1, policy, mode)]
                            target = cases[(rnd, workload, producers,
                                            policy, mode)]
                            val = (target["throughput_per_s"] /
                                   one["throughput_per_s"])
                            vals.append(val)
                            scaling.append(dict(
                                round=rnd, workload=workload,
                                policy=policy, mode=mode,
                                producers=producers, ratio_vs_one=val))
    write_csv(out / "pairs.csv", pairs)
    write_csv(out / "summary.csv", summary)
    if scaling:
        write_csv(out / "producer_scaling.csv", scaling)
    with (out / "environment.txt").open("w") as file:
        file.write("benchmark=r05-worker-thread-boundary-resource-ab\n")
        file.write("research_head=" + command_output(
            ["git", "rev-parse", "HEAD"], root).stdout.strip() + "\n")
        file.write("off_config=" + CONFIGS["off"][0] + "\n")
        file.write("worker_config=" + CONFIGS["worker"][0] + "\n")
        for mode in CONFIGS:
            file.write(mode + "_binary_sha256=" + digests[mode] + "\n")
        file.write("benchmark_parameters=" + repr(vars(args)) + "\n")
        file.write("submit_instrumentation=off; parking=off; notify=always\n")
        file.write("worker profiling = getrusage(RUSAGE_THREAD) only at "
                   "workerLoop thread start and after return\n")
        file.write("off/worker use different versioned executables; "
                   "do not interpret paired throughput as optimization\n")
        file.write("producer stats are sampled at producer thread boundaries; "
                   "worker data exclude thread startup before first snapshot\n")
        file.write("whole child - producer - worker is a signed residual, "
                   "not exact main-thread accounting\n")
        file.write("counters cannot identify futex cause/wake-to-run time\n")
        for command in ([args.compiler, "--version"], ["dub", "--version"],
                        ["lscpu"], ["git", "status", "--short",
                                    "--untracked-files=no"],
                        ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            file.write("$ " + " ".join(command) + "\n")
            result = command_output(list(command), root, allow_failure=True)
            file.write((result.stdout if result.returncode == 0
                        else "unavailable: " + result.stderr[-300:]) + "\n")
        file.write("platform=" + platform.platform() + "\n")
    print("PASS: exact thread resource counters and source work accounting",
          out)


if __name__ == "__main__":
    main()
