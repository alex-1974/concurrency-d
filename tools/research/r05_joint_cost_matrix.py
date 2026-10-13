#!/usr/bin/env python3
"""Same-source cost indicators: producer admission versus worker acquisition.

No novel D hot-path probe or scheduler change. Four fresh child modes:
plain (unmodified full-victim release), worker (existing worker-boundary
getrusage + runtime parking counts), joint_off (combined version, admission
runtime OFF), joint_on (EXACT same executable as joint_off, admission ON).
All use always notifications, identical Tasks/TaskRef ownership, and no
inner R05InboxSubmitProbe (which instruments independent of outer flag).

Timing brackets are probe-perturbed elapsed ns and may overlap cross-thread.
Never sum admission wall wait ns and thread CPU as end-to-end cost shares.
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

from r05_native_cpu_profile import FIELDS, RESOURCE, command_output, parse_line, write_csv
from r05_worker_resource_matrix import WORKER, WORKER_NUMERIC
from r05_worker_parking_matrix import PARK, WAKE, read_metric
from r05_worker_parking_correlation import NOTIFY
from r05_admission_matrix import ADMISSION
from r05_admission_stage_matrix import STAGE

BUILDS = {
    "plain": ("task-pipeline-mixed-full-victim-sweep",
              "concurrency-task-pipeline-mixed-full-victim-sweep"),
    "worker": ("task-pipeline-mixed-full-victim-worker-resource",
               "concurrency-task-pipeline-mixed-full-victim-worker-resource"),
    "joint": ("task-pipeline-mixed-full-victim-joint-cost",
              "concurrency-task-pipeline-mixed-full-victim-joint-cost"),
}
MODES = ("plain", "worker", "joint_off", "joint_on")
STAGE_METRICS = ("gate", "cell", "node", "publish", "root_append", "inbox_submit")


def execute(root, binary, digest, rnd, mode, workload, producers, policy,
            workers, tasks, budget, counter):
    profile = mode == "joint_on"
    has_workers = mode != "plain"
    has_parking = has_workers
    args = [
        str(binary), str(workers), str(producers), str(tasks), str(budget),
        policy, counter, "on" if profile else "off", workload,
        "on" if has_parking else "off", "always",
    ]
    start = time.monotonic_ns()
    with tempfile.TemporaryFile(mode="w+t") as stream:
        child = subprocess.Popen(args, cwd=root, stdout=stream,
                                 stderr=subprocess.STDOUT, text=True)
        _, status, usage = os.wait4(child.pid, 0)
        wall_ns = time.monotonic_ns() - start
        stream.seek(0)
        output = stream.read()
    if os.waitstatus_to_exitcode(status):
        raise RuntimeError("child failed " + repr(args) + "\n" + output[-7000:])

    perf = parse_line(output, "multi,mixed,", FIELDS)
    resource = parse_line(output, "resource,", RESOURCE)
    checksum = parse_line(
        output, "workload,", ("metric", "workload", "compute_rounds", "checksum"))
    park = read_metric(output, "parking,", PARK, required=has_parking)
    wake = read_metric(output, "wakeup,", WAKE, required=has_parking)
    notify = read_metric(output, "notification,", NOTIFY, required=has_parking)
    adm = read_metric(output, "admission,", ADMISSION, required=profile)
    stage = read_metric(output, "stage,", STAGE, required=profile)

    if (perf["scenario"] != "mixed" or perf["policy"] != policy or
            int(perf["workers"]) != workers or
            int(perf["producers"]) != producers or
            int(perf["budget"]) != budget or
            int(perf["tasks"]) != tasks or
            int(perf["completed"]) != tasks or
            int(perf["fresh_nodes"]) + int(perf["reused_nodes"]) != tasks or
            int(perf["observed_handles"]) <= 0 or
            float(perf["throughput_per_s"]) <= 0 or
            checksum["workload"] != workload or
            int(checksum["compute_rounds"]) !=
            (1024 if workload == "compute" else 0) or
            resource["counter_mode"] != counter or
            resource["policy"] != policy or
            int(resource["workers"]) != workers or
            int(resource["producers"]) != producers or
            int(resource["tasks"]) != tasks):
        raise RuntimeError("consumer completion or workload metadata mismatch")
    if wall_ns / 1_000_000 + 0.01 < float(perf["elapsed_ms"]):
        raise RuntimeError("external wall shorter than measured execution")

    worker_rows = []
    lines = [line for line in output.splitlines()
             if line.startswith("worker-resource,")]
    if len(lines) != (workers if has_workers else 0):
        raise RuntimeError("missing/unexpected worker resource rows")
    for line in lines:
        values = next(csv.reader([line]))
        if len(values) != len(WORKER):
            raise RuntimeError("worker resource schema mismatch")
        w = dict(zip(WORKER, values))
        if (w["policy"] != policy or w["counter_mode"] != counter or
                int(w["workers"]) != workers or
                int(w["producers"]) != producers or
                int(w["budget"]) != budget or
                int(w["tasks"]) != tasks or w["sampled"] != "1"):
            raise RuntimeError("worker resource source identity mismatch")
        row = dict(round=rnd, mode=mode, workload=workload,
                   producers=producers, policy=policy,
                   worker_index=int(w["worker_index"]))
        row.update({key: int(w[key]) for key in WORKER_NUMERIC})
        row["worker_cpu_us"] = row["cpu_user_us"] + row["cpu_system_us"]
        worker_rows.append(row)
    if len({w["worker_index"] for w in worker_rows}) != len(worker_rows):
        raise RuntimeError("duplicate worker resource slots")

    row = dict(
        round=rnd, mode=mode, workload=workload, producers=producers,
        policy=policy, workers=workers, budget=budget, counter=counter,
        tasks=tasks, checksum=checksum["checksum"], completed=int(perf["completed"]),
        observed_handles=int(perf["observed_handles"]),
        fresh_nodes=int(perf["fresh_nodes"]), reused_nodes=int(perf["reused_nodes"]),
        binary_sha256=digest,
        throughput_per_s=float(perf["throughput_per_s"]),
        external_wall_ms=wall_ns / 1_000_000,
        elapsed_ms=float(perf["elapsed_ms"]),
        child_cpu_us=(usage.ru_utime + usage.ru_stime) * 1_000_000,
        child_voluntary=usage.ru_nvcsw,
        child_involuntary=usage.ru_nivcsw,
        producer_cpu_us=(int(resource["producer_user_us"]) +
                         int(resource["producer_system_us"])),
        producer_voluntary=int(resource["producer_voluntary"]),
        worker_cpu_us=(sum(w["worker_cpu_us"] for w in worker_rows)
                       if has_workers else ""),
        worker_voluntary=(sum(w["voluntary_switches"] for w in worker_rows)
                          if has_workers else ""),
        worker_count=len(worker_rows) if has_workers else "",
        peak_rss_kib=usage.ru_maxrss,
    )
    counts = {}
    if has_parking:
        for field in ("policy", "workload"):
            if (park[field] != (policy if field == "policy" else workload) or
                    wake[field] != park[field] or notify[field] != park[field]):
                raise RuntimeError("parking/wake policy or workload mismatch")
        for field, want in (("producers", producers), ("workers", workers),
                            ("budget", budget), ("tasks", tasks)):
            if (int(park[field]) != want or int(wake[field]) != want or
                    int(notify[field]) != want):
                raise RuntimeError("parking/wake scenario identity mismatch")
        for field in PARK[7:]:
            counts[field] = int(park[field])
        for field in WAKE[7:]:
            counts[field] = int(wake[field])
        for field in NOTIFY[8:]:
            counts[field] = int(notify[field])
        exits = sum(counts[k] for k in ("exit_inbox", "exit_generation", "exit_drained"))
        first = sum(counts[k] for k in (
            "useful_local", "useful_inbox", "useful_steal", "no_work", "drained"))
        if (counts["condition_waits"] != counts["wait_returns"] or
                counts["wait_returns"] != counts["still_blocked"] + exits or
                exits != first or
                counts["steal_successes"] > counts["steal_attempts"] or
                counts["claimed_tasks"] != tasks or
                counts["executions"] != tasks or
                counts["ingress_notifications"] != tasks or
                counts["ingress_calls"] != tasks or
                counts["ingress_skipped"] != 0 or
                counts["local_calls"] != counts["local_notifications"] or
                counts["local_skipped"] != 0 or
                notify["notify_policy"] != "always"):
            raise RuntimeError("wake/steal/notification conservation mismatch")
        row.update(dict(
            condition_waits_per_task=counts["condition_waits"] / tasks,
            failed_steals_per_task=(
                counts["steal_attempts"] - counts["steal_successes"]) / tasks,
            local_misses_per_task=counts["local_misses"] / tasks,
            ingress_misses_per_task=counts["ingress_misses"] / tasks,
            steals_success_fraction=(counts["steal_successes"] /
                                     counts["steal_attempts"]
                                     if counts["steal_attempts"] else ""),
            claimed_tasks_per_batch=(tasks / counts["claimed_batches"]
                                     if counts["claimed_batches"] else ""),
            empty_after_wait_fraction=counts["no_work"] / exits if exits else "",
        ))
    else:
        for k in ("condition_waits_per_task", "failed_steals_per_task",
                  "local_misses_per_task", "ingress_misses_per_task",
                  "steals_success_fraction", "claimed_tasks_per_batch",
                  "empty_after_wait_fraction"):
            row[k] = ""

    row["admission_wait_ns_per_attempt"] = ""
    row["admission_hold_ns_per_attempt"] = ""
    row["admission_wait_ns_per_accepted"] = ""
    row["admission_hold_ns_per_accepted"] = ""
    for kind in STAGE_METRICS:
        row[kind + "_ns_per_accepted"] = ""
    stage_row = None
    if profile:
        for source in (adm, stage):
            if (source["policy"] != policy or
                source["counter_mode"] != counter or
                int(source["tasks"]) != tasks or
                int(source["producers"]) != producers or
                int(source["workers"]) != workers or
                int(source["budget"]) != budget):
                raise RuntimeError("admission/stage scenario identity mismatch")
        attempts = int(adm["attempts"])
        accepted = int(adm["accepted"])
        if (attempts != tasks + int(adm["retention_full"]) +
                int(adm["ingress_full"]) or
                int(adm["yields"]) != attempts - tasks or
                accepted != tasks or int(stage["gate_count"]) != attempts):
            raise RuntimeError("admission attempt conservation mismatch")
        for name in ("cell", "node", "publish", "root_append", "inbox_submit"):
            if int(stage[name + "_count"]) != tasks:
                raise RuntimeError("missing or duplicated admission stage")
        if (int(stage["root_append_ns"]) > int(stage["publish_ns"]) or
                int(stage["inbox_submit_ns"]) > int(stage["publish_ns"])):
            raise RuntimeError("nested publication time invariant violated")
        row["admission_wait_ns_per_attempt"] = int(adm["wait_ns"]) / attempts
        row["admission_hold_ns_per_attempt"] = int(adm["hold_ns"]) / attempts
        row["admission_wait_ns_per_accepted"] = int(adm["wait_ns"]) / tasks
        row["admission_hold_ns_per_accepted"] = int(adm["hold_ns"]) / tasks
        for name in STAGE_METRICS:
            row[name + "_ns_per_accepted"] = int(stage[name + "_ns"]) / tasks
        stage_row = dict(round=rnd, workload=workload,
                         producers=producers, policy=policy,
                         admission_attempts=attempts,
                         accepted=accepted,
                         retention_full=int(adm["retention_full"]),
                         ingress_full=int(adm["ingress_full"]),
                         admission_wait_ns=int(adm["wait_ns"]),
                         admission_hold_ns=int(adm["hold_ns"]))
        for name in STAGE_METRICS:
            stage_row[name + "_count"] = int(stage[name + "_count"])
            stage_row[name + "_ns"] = int(stage[name + "_ns"])
    return row, worker_rows, stage_row


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
                   default=["gc"])
    p.add_argument("--workloads", nargs="+", choices=["minimal", "compute"],
                   default=["minimal", "compute"])
    p.add_argument("--counter", choices=["shared", "striped"], default="shared")
    p.add_argument("--cooldown-ms", type=int, default=50)
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-joint-cost"))
    a = p.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= a.workers <= 64 or
            not 1 <= a.tasks <= 2_000_000 or
            not 1 <= a.rounds <= 20 or
            not a.producers or not a.policies or not a.workloads or
            any(not 1 <= n <= 64 for n in a.producers) or
            len(set(a.producers)) != len(a.producers) or
            len(set(a.policies)) != len(a.policies) or
            len(set(a.workloads)) != len(a.workloads) or
            not 0 <= a.cooldown_ms <= 10000):
        p.error("invalid bounded matrix")
    root = Path(__file__).resolve().parents[2]
    bins, digests = {}, {}
    for k, (conf, executable) in BUILDS.items():
        command_output(["dub", "build", "--config=" + conf,
                        "--build=release", "--compiler=" + a.compiler,
                        "--force"], root)
        binary = root / executable
        if not binary.is_file():
            raise RuntimeError("missing " + executable)
        bins[k] = binary
        digests[k] = hashlib.sha256(binary.read_bytes()).hexdigest()

    dest = a.output.resolve()
    dest.mkdir(parents=True, exist_ok=True)
    all_rows, workers, stages = [], [], []
    for rnd in range(a.rounds):
        for workload in a.workloads:
            for producers in a.producers:
                for policy in a.policies:
                    modes = list(MODES)
                    shift = (rnd + producers + a.policies.index(policy)) % len(modes)
                    modes = modes[shift:] + modes[:shift]
                    for mode in modes:
                        bin_key = "joint" if mode.startswith("joint") else mode
                        row, worker_rows, stage = execute(
                            root, bins[bin_key], digests[bin_key],
                            rnd, mode, workload, producers, policy,
                            a.workers, a.tasks, a.budget, a.counter)
                        all_rows.append(row)
                        workers.extend(worker_rows)
                        if stage is not None:
                            stages.append(stage)
                        print("R05 joint-cost", rnd, workload, producers,
                              policy, mode,
                              "throughput", round(row["throughput_per_s"]),
                              "worker-switches", row["worker_voluntary"],
                              flush=True)
                        if a.cooldown_ms:
                            time.sleep(a.cooldown_ms / 1000)
    base = a.rounds * len(a.workloads) * len(a.producers) * len(a.policies)
    if len(all_rows) != base * len(MODES) or len(stages) != base:
        raise RuntimeError("incomplete joint-cost case matrix")
    if len(workers) != base * 3 * a.workers:
        raise RuntimeError("incomplete worker resource rows")
    cases = {(r["round"], r["workload"], r["producers"],
              r["policy"], r["mode"]): r for r in all_rows}
    if len(cases) != len(all_rows):
        raise RuntimeError("duplicate joint case")
    checksums = {}
    for r in all_rows:
        checksums.setdefault(r["workload"], set()).add(r["checksum"])
        k = "joint" if r["mode"].startswith("joint") else r["mode"]
        if r["binary_sha256"] != digests[k]:
            raise RuntimeError("joint binary provenance mismatch")
    if any(len(x) != 1 for x in checksums.values()):
        raise RuntimeError("checksum mismatch")

    write_csv(dest / "raw.csv", all_rows)
    write_csv(dest / "worker.csv", workers)
    write_csv(dest / "stages.csv", stages)
    pairs, summary = [], []
    for workload in a.workloads:
        for producers in a.producers:
            for policy in a.policies:
                group = []
                for rnd in range(a.rounds):
                    matched = {mode: cases[(rnd, workload, producers, policy, mode)]
                               for mode in MODES}
                    pair = dict(
                        round=rnd, workload=workload, producers=producers,
                        policy=policy, worker_over_plain=(
                            matched["worker"]["throughput_per_s"] /
                            matched["plain"]["throughput_per_s"]),
                        joint_off_over_worker=(
                            matched["joint_off"]["throughput_per_s"] /
                            matched["worker"]["throughput_per_s"]),
                        joint_on_over_joint_off=(
                            matched["joint_on"]["throughput_per_s"] /
                            matched["joint_off"]["throughput_per_s"]),
                    )
                    pairs.append(pair)
                    group.append(matched["joint_on"])
                item = dict(
                    workload=workload, producers=producers, policy=policy,
                    rounds=a.rounds)
                for metric in (
                    "throughput_per_s", "child_cpu_us", "producer_cpu_us",
                    "worker_cpu_us", "child_voluntary", "producer_voluntary",
                    "worker_voluntary", "admission_wait_ns_per_attempt",
                    "admission_hold_ns_per_attempt",
                    "admission_wait_ns_per_accepted",
                    "admission_hold_ns_per_accepted",
                    "inbox_submit_ns_per_accepted",
                    "condition_waits_per_task", "failed_steals_per_task",
                    "steals_success_fraction", "claimed_tasks_per_batch",
                    "empty_after_wait_fraction",
                ):
                    values = [row[metric] for row in group
                              if row[metric] != ""]
                    item["median_" + metric] = (
                        statistics.median(values) if values else "")
                summary.append(item)
    write_csv(dest / "pairs.csv", pairs)
    write_csv(dest / "summary.csv", summary)
    with (dest / "environment.txt").open("w") as handle:
        handle.write("benchmark=r05-same-source-joint-admission-worker-parking\n")
        handle.write("head=" + command_output(
            ["git", "rev-parse", "HEAD"], root).stdout.strip() + "\n")
        handle.write("versions=R05FullVictimSweep + runtime-on admission;"
                     " R05WorkerThreadResources; NO R05InboxSubmitProbe\n")
        handle.write("modes=plain,worker,joint_off,joint_on\n")
        handle.write("notify=always, counter=" + a.counter + "\n")
        handle.write("all modes share workload and semantics; only"
                     " instrumentation differs\n")
        handle.write("joint_on and joint_off have IDENTICAL binary SHA\n")
        handle.write("admission wall-clock waits may overlap other threads;"
                     " no additive CPU cost decomposition is valid\n")
        handle.write("worker wait/steal counts have no measured ns per event\n")
        handle.write("arguments=" + repr(vars(a)) + "\n")
        for name in BUILDS:
            handle.write(name + "_sha256=" + digests[name] + "\n")
        for command in ([a.compiler, "--version"], ["dub", "--version"],
                        ["lscpu"], ["git", "status", "--short",
                                    "--untracked-files=no"],
                        ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            handle.write("$ " + " ".join(command) + "\n")
            v = command_output(command, root, allow_failure=True)
            handle.write((v.stdout if v.returncode == 0 else
                          "unavailable: " + v.stderr[-250:]) + "\n")
        handle.write("platform=" + platform.platform() + "\n")
    print("PASS: same-source profiler modes, task accounting and paired ratios",
          dest)


if __name__ == "__main__":
    main()
