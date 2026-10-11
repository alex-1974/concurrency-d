#!/usr/bin/env python3
"""R0.5 three-way old/full/rotating victim-sweep, untraced by default.

No change to production scheduling. Compares actual burst callable starts,
internally timed typed/GC-visible mixed task pipelines, and process-idle CPU
plus idle-to-result latency. Runs fresh child processes in rotated order.
"""
import argparse
import csv
from pathlib import Path
import platform
import statistics
import subprocess

import r05_batch_size_ab as base
import r05_notification_idle_latency as idle

MODES = ("old", "full", "rotating")
MODES_CONFIG = {
    "old": {
        "burst": ("burst-head-of-line-benchmark",
                  "concurrency-burst-head-of-line"),
        "mixed": ("task-pipeline-mixed-benchmark",
                  "concurrency-task-pipeline-mixed"),
        "idle": ("notification-latency-benchmark",
                 "concurrency-notification-latency"),
    },
    "full": {
        "burst": ("burst-head-of-line-full-victim-sweep",
                  "concurrency-burst-head-of-line-full-victim-sweep"),
        "mixed": ("task-pipeline-mixed-full-victim-sweep",
                  "concurrency-task-pipeline-mixed-full-victim-sweep"),
        "idle": ("notification-latency-full-victim-sweep",
                 "concurrency-notification-latency-full-victim-sweep"),
    },
    "rotating": {
        "burst": ("burst-head-of-line-rotating-victim-sweep",
                  "concurrency-burst-head-of-line-rotating-victim-sweep"),
        "mixed": ("task-pipeline-mixed-rotating-victim-sweep",
                  "concurrency-task-pipeline-mixed-rotating-victim-sweep"),
        "idle": ("notification-latency-rotating-victim-sweep",
                 "concurrency-notification-latency-rotating-victim-sweep"),
    },
}
CONTRASTS = (("full", "old"), ("rotating", "full"),
             ("rotating", "old"))


def test_scan_model():
    """Exhaustively model candidate coverage and fair foreign first victims.

    This tests the per-worker cursor arithmetic for fixed empty queues; it
    does not claim concurrent scheduling fairness or prove D codegen.
    """
    missing_control = 0
    for count in (1, 2, 3, 4, 5, 8, 16, 32):
        for self_id in range(count):
            foreign = set(range(count)) - {self_id}
            for start in range(count):
                old = [(start + i) % count for i in range(count - 1)
                       if (start + i) % count != self_id]
                full = [(start + i) % count for i in range(count)
                        if (start + i) % count != self_id]
                if set(old) != foreign:
                    missing_control += 1
                if len(full) != len(foreign) or set(full) != foreign:
                    raise RuntimeError("complete sweep omitted a foreign victim")
            if count == 1:
                continue
            cursor = (self_id + 1) % count
            first_foreign = []
            for _ in range(count - 1):
                if cursor == self_id:
                    cursor = (cursor + 1) % count
                first_foreign.append(cursor)
                full_scan = [
                    (cursor + i) % count for i in range(count)
                    if (cursor + i) % count != self_id]
                if set(full_scan) != foreign or len(full_scan) != count - 1:
                    raise RuntimeError("rotating sweep incomplete")
                # Exact runtime behaviour on an unsuccessful N-slot search:
                # candidate cursor returns to same start, then advances,
                # skipping self to avoid double-weighting the same victim.
                cursor = (cursor + count + 1) % count
                if cursor == self_id:
                    cursor = (cursor + 1) % count
            if len(set(first_foreign)) != count - 1 or set(
                    first_foreign) != foreign:
                raise RuntimeError("rotating first-victim distribution unfair")
    if missing_control == 0:
        raise RuntimeError("original incomplete coverage not reproduced")


def build(root, compiler):
    for mode in MODES:
        for config, binary in MODES_CONFIG[mode].values():
            subprocess.run(["dub", "build", "--config=" + config,
                            "--build=release", "--compiler=" + compiler,
                            "--force"], cwd=root, check=True)
            if not (root / binary).is_file():
                raise RuntimeError("missing DUB executable " + binary)


def run_order(round_id, salt):
    shift = (round_id + salt) % len(MODES)
    return MODES[shift:] + MODES[:shift]


def run_mixed(binary, root, mode, workers, producers, tasks, budget,
              storage, notify, workload):
    rows, resources = base.run_child([
        str(binary), str(workers), str(producers), str(tasks), str(budget),
        storage, "striped", "off", workload, "off", notify], root)
    row = base.one(rows, "multi", base.MULTI)
    if (row["scenario"] != "mixed" or row["policy"] != storage or
            int(row["workers"]) != workers or
            int(row["producers"]) != producers or
            int(row["budget"]) != budget or
            int(row["tasks"]) != tasks or
            int(row["completed"]) != tasks or
            float(row["throughput_per_s"]) <= 0):
        raise RuntimeError("mixed workload/accounting mismatch")
    result = dict(mode=mode, workers=workers, producers=producers,
                  tasks=tasks, budget=budget, storage=storage, notify=notify,
                  workload=workload, elapsed_ms=float(row["elapsed_ms"]),
                  throughput_per_s=float(row["throughput_per_s"]),
                  fresh_nodes=int(row["fresh_nodes"]),
                  reused_nodes=int(row["reused_nodes"]),
                  producer_gc_bytes=int(row["producer_gc_bytes"]))
    result.update(resources)
    return result


def run_idle(binary, root, mode, workers, notify, idle_ms, samples, gap_ms):
    rows, resources = base.run_child(
        [str(binary), str(workers), notify, str(idle_ms),
         str(samples), str(gap_ms)], root)
    row = base.one(rows, "latency", idle.HEADERS)
    if (row["notification_policy"] != notify or
            int(row["workers"]) != workers or
            int(row["idle_ms"]) != idle_ms or
            int(row["samples"]) != samples or
            int(row["gap_ms"]) != gap_ms or
            int(row["completed"]) != samples):
        raise RuntimeError("idle-to-result semantics mismatch")
    cpu_us = int(row["idle_cpu_us"])
    wall_ns = int(row["idle_wall_ns"])
    if (cpu_us < 0 or wall_ns < 1 or
            not 0 <= int(row["p50_ns"]) <= int(row["p95_ns"]) <=
            int(row["p99_ns"]) <= int(row["max_ns"])):
        raise RuntimeError("invalid idle CPU or latency distribution")
    result = dict(mode=mode, workers=workers, notify=notify,
                  idle_ms=idle_ms, samples=samples, gap_ms=gap_ms,
                  idle_cpu_us=cpu_us, idle_wall_ns=wall_ns,
                  idle_cpu_core_fraction=(cpu_us * 1000.0 / wall_ns),
                  p50_ns=int(row["p50_ns"]),
                  p95_ns=int(row["p95_ns"]),
                  p99_ns=int(row["p99_ns"]),
                  max_ns=int(row["max_ns"]),
                  completed=samples)
    result.update(resources)
    return result


def paired_rows(kind, data, key, measures):
    result = []
    for lhs, rhs in CONTRASTS:
        hi, lo = data[lhs], data[rhs]
        for metric in measures:
            previous = float(lo[metric])
            current = float(hi[metric])
            result.append(dict(kind=kind, **key,
                               compare=lhs + "_over_" + rhs,
                               metric=metric, lhs=current, rhs=previous,
                               delta=current - previous,
                               ratio=current / previous
                               if previous != 0 else ""))
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--tasks", type=int, default=100_000)
    p.add_argument("--workers", nargs="+", type=int, default=[1, 4, 8])
    p.add_argument("--producers", nargs="+", type=int, default=[1, 4])
    p.add_argument("--workloads", nargs="+", choices=("minimal", "compute"),
                   default=["minimal", "compute"])
    p.add_argument("--policies", nargs="+", choices=("gc", "recycle"),
                   default=["gc", "recycle"])
    p.add_argument("--notify", nargs="+", choices=("always", "waiter"),
                   default=["always", "waiter"])
    p.add_argument("--budget", type=int, default=512)
    p.add_argument("--burst-ms", type=int, default=100)
    p.add_argument("--blockers", nargs="+", type=int, default=[3, 4])
    p.add_argument("--idle-ms", type=int, default=300)
    p.add_argument("--wake-samples", type=int, default=64)
    p.add_argument("--gap-ms", type=int, default=1)
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-rotating-victim-matrix"))
    args = p.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= args.rounds <= 20 or
            not 384 <= args.tasks <= 500_000 or
            not args.workers or any(w not in (1, 2, 4, 8, 16)
                                    for w in args.workers) or
            not args.producers or any(x not in (1, 4, 8)
                                      for x in args.producers) or
            not args.blockers or any(x not in (3, 4)
                                     for x in args.blockers) or
            args.budget not in (8, 64, 512, 4096) or
            not 10 <= args.burst_ms <= 2000 or
            not 100 <= args.idle_ms <= 2000 or
            not 8 <= args.wake_samples <= 1000 or
            not 1 <= args.gap_ms <= 10):
        p.error("invalid bounded R0.5 rotation matrix")
    for factor in (args.workers, args.producers, args.blockers,
                   args.policies, args.notify, args.workloads):
        if len(factor) != len(set(factor)):
            p.error("duplicate factor")

    test_scan_model()
    root = Path(__file__).resolve().parents[2]
    build(root, args.compiler)
    args.output.mkdir(parents=True, exist_ok=True)
    bursts, siblings, mixed, idle_rows, pairs = [], [], [], [], []
    for rnd in range(args.rounds):
        for storage in args.policies:
            for notify in args.notify:
                for blockers in args.blockers:
                    runs = {}
                    for mode in run_order(rnd, blockers +
                                          (storage == "recycle") +
                                          (notify == "waiter")):
                        binary = root / MODES_CONFIG[mode]["burst"][1]
                        row, tasks = base.burst_case(
                            binary, root, 8, storage, notify,
                            blockers, args.burst_ms)
                        row.update(mode=mode, round=rnd)
                        bursts.append(row)
                        runs[mode] = row
                        for task in tasks:
                            task.update(mode=mode, round=rnd)
                            siblings.append(task)
                    key = dict(round=rnd, workers=4, producers="",
                               blockers=blockers, storage=storage,
                               notify=notify, workload="")
                    pairs += paired_rows("burst", runs, key,
                        ("siblings_started_before_gate",
                         "progress_after_final_blocker",
                         "start_p95_ns", "start_p99_ns"))
                    print(f"burst round={rnd} {storage}/{notify} "
                          f"blockers={blockers} " + " ".join(
                              f"{mode}={runs[mode]['siblings_started_before_gate']}"
                              for mode in MODES), flush=True)
                for workers in args.workers:
                    for producers in args.producers:
                        for workload in args.workloads:
                            runs = {}
                            for mode in run_order(
                                    rnd, workers + producers +
                                    (storage == "recycle") +
                                    (notify == "waiter") +
                                    (workload == "compute")):
                                binary = root / MODES_CONFIG[mode]["mixed"][1]
                                row = run_mixed(binary, root, mode, workers,
                                                producers, args.tasks,
                                                args.budget, storage, notify,
                                                workload)
                                row["round"] = rnd
                                mixed.append(row)
                                runs[mode] = row
                            key = dict(round=rnd, workers=workers,
                                       producers=producers, blockers="",
                                       storage=storage, notify=notify,
                                       workload=workload)
                            pairs += paired_rows("mixed", runs, key,
                                ("throughput_per_s", "elapsed_ms",
                                 "child_cpu_user_us",
                                 "child_cpu_system_us",
                                 "child_voluntary_switches",
                                 "child_involuntary_switches"))
                            print(f"mixed round={rnd} {storage}/{notify} "
                                  f"w={workers} p={producers} {workload} " +
                                  " ".join(
                                      f"{mode}={runs[mode]['throughput_per_s']:.0f}"
                                      for mode in MODES), flush=True)
        for workers in args.workers:
            for notify in args.notify:
                runs = {}
                for mode in run_order(rnd, workers + (notify == "waiter")):
                    binary = root / MODES_CONFIG[mode]["idle"][1]
                    row = run_idle(binary, root, mode, workers, notify,
                                   args.idle_ms, args.wake_samples, args.gap_ms)
                    row["round"] = rnd
                    idle_rows.append(row)
                    runs[mode] = row
                key = dict(round=rnd, workers=workers, producers="",
                           blockers="", storage="", notify=notify,
                           workload="")
                pairs += paired_rows("idle", runs, key,
                    ("idle_cpu_us", "idle_cpu_core_fraction",
                     "p95_ns", "p99_ns"))
                print(f"idle round={rnd} workers={workers} notify={notify} "
                      + " ".join(
                          f"{mode}={runs[mode]['idle_cpu_us']}us"
                          for mode in MODES), flush=True)

    base.write_csv(args.output / "burst_cases.csv", bursts)
    base.write_csv(args.output / "burst_siblings.csv", siblings)
    base.write_csv(args.output / "mixed_cases.csv", mixed)
    base.write_csv(args.output / "idle_cases.csv", idle_rows)
    base.write_csv(args.output / "pairs.csv", pairs)
    groups = {}
    for row in pairs:
        group_key = (row["kind"], row["workers"], row["producers"],
                     row["blockers"], row["storage"], row["notify"],
                     row["workload"], row["compare"], row["metric"])
        groups.setdefault(group_key, []).append(row)
    summary = []
    for group_key, group in sorted(groups.items(), key=lambda x: str(x[0])):
        if len(group) != args.rounds or len({
                row["round"] for row in group}) != args.rounds:
            raise RuntimeError("incomplete paired observations: " +
                               str(group_key))
        kind, workers, producers, blockers, storage, notify, workload, compare, metric = group_key
        ratios = [r["ratio"] for r in group if r["ratio"] != ""]
        summary.append(dict(
            kind=kind, workers=workers, producers=producers,
            blockers=blockers, storage=storage, notify=notify,
            workload=workload, compare=compare, metric=metric,
            rounds=len(group), median_lhs=statistics.median(
                row["lhs"] for row in group),
            median_rhs=statistics.median(row["rhs"] for row in group),
            median_paired_delta=statistics.median(
                row["delta"] for row in group),
            median_paired_ratio=statistics.median(ratios)
            if len(ratios) == args.rounds else "",
            lhs_higher_rounds=sum(row["delta"] > 0 for row in group)))
    base.write_csv(args.output / "summary.csv", summary)
    with (args.output / "environment.txt").open("w") as fp:
        fp.write("research-only; old/full/rotating untraced and batch8\n"
                 f"platform={platform.platform()} compiler={args.compiler}\n"
                 f"rounds={args.rounds} workers={args.workers} "
                 f"producers={args.producers} tasks={args.tasks}\n"
                 f"policies={args.policies} notify={args.notify} "
                 f"workloads={args.workloads} budget={args.budget}\n"
                 f"burst_ms={args.burst_ms} blockers={args.blockers}\n"
                 f"idle_ms={args.idle_ms} wake_samples={args.wake_samples} "
                 f"gap_ms={args.gap_ms}\n"
                 "Burst starts are from burst begin, not submit. "
                 "Idle CPU is process CPU during a post-construction quiet "
                 "period, not per-worker CPU.\n"
                 "Child startup excluded from mixed internal elapsed. "
                 "No throughput threshold is a CI gate.\n")
        for cmd in (["git", "rev-parse", "HEAD"],
                    [args.compiler, "--version"], ["lscpu"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            fp.write("$ " + " ".join(cmd) + "\n")
            try:
                fp.write(subprocess.run(cmd, cwd=root, check=True,
                       capture_output=True, text=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fp.write("unavailable\n")
    print("R0.5 rotating victim A/B: correctness plus research-only evidence")
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
