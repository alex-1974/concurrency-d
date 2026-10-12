#!/usr/bin/env python3
"""Compare shared vs producer-striped execution counters in unchanged R0.5.

One uninstrumented, full-victim release binary per compiler; the sole
treatment is a *runtime benchmark counter-mode argument*. Every process
executes the same task IDs and independently verifies all completions and
typed results. The paired estimates are exploratory, not a scheduler gain.
"""
import argparse
import csv
import hashlib
from pathlib import Path
import platform
import statistics
import time

from r05_native_cpu_profile import (
    BUILD_CONFIG, build, command_output, run_child, write_csv,
)

COUNTERS = ("shared", "striped")
MEASURES = (
    "throughput_per_s", "child_user_us", "child_system_us",
    "child_voluntary_switches", "child_involuntary_switches",
    "producer_user_us", "producer_system_us",
    "producer_voluntary_switches", "producer_involuntary_switches",
    "producer_gc_bytes",
)


def ratio(left, right, metric):
    """Return the directional left/right result without hiding zero counts."""
    numerator, denominator = float(left[metric]), float(right[metric])
    return numerator / denominator if denominator else ""


def save_environment(out, root, args, digest):
    lines = [
        "benchmark=r05-full-victim-counter-contention-ab",
        "research_head=" + command_output(
            ["git", "rev-parse", "HEAD"], root).stdout.strip(),
        "binary_sha256=" + digest,
        "build_config=" + BUILD_CONFIG,
        "compiled_versions=R05FullVictimSweep only",
        "instrumentation=off; parking=off; notify=always",
        "counter_modes=shared striped (same executable)",
        f"workers={args.workers} tasks={args.tasks} rounds={args.rounds}",
        f"producers={args.producers} budgets={args.budgets}",
        f"policies={args.policies} workloads={args.workloads}",
        f"cooldown_ms={args.cooldown_ms}",
        "The stripes are indexed by originating producer, NOT executing worker.",
        "Each mode still performs one atomic increment per executed task.",
        "Other admitted/observed counters and void-task checksum stay shared.",
        "The one-producer modes differ in counter storage location as well.",
        "Counter-pair throughput is striped/shared; paired context/CPU ratios",
        "are diagnostics, not directly attributable to a particular lock.",
        "No hot-path timing, perf wrapper, core pinning or governor change.",
        "Process resource figures are per fresh wait4 child, with all threads.",
        "Within-round comparisons alternate order; do not pool across campaigns.",
    ]
    for command in (
        [args.compiler, "--version"], ["dub", "--version"],
        ["lscpu"], ["git", "status", "--short", "--untracked-files=no"],
        ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"],
        ["cat", "/proc/sys/kernel/perf_event_paranoid"],
    ):
        lines.append("$ " + " ".join(command))
        result = command_output(command, root, allow_failure=True)
        lines.append((result.stdout.strip() if result.returncode == 0
                      else "unavailable: " + result.stderr[-300:].strip()))
    lines.append("platform=" + platform.platform())
    (out / "environment.txt").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--tasks", type=int, default=30000)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--producers", nargs="+", type=int, default=[1, 4, 8])
    parser.add_argument("--budgets", nargs="+", type=int, default=[512])
    parser.add_argument("--policies", nargs="+", choices=["gc", "recycle"],
                        default=["gc", "recycle"])
    parser.add_argument("--workloads", nargs="+",
                        choices=["minimal", "compute"],
                        default=["minimal", "compute"])
    parser.add_argument("--cooldown-ms", type=int, default=100)
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-counter-contention"))
    args = parser.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= args.workers <= 64 or
            not 1 <= args.tasks <= 2_000_000 or
            not 1 <= args.rounds <= 30 or
            not args.producers or not args.budgets or
            not args.policies or not args.workloads or
            len(set(args.producers)) != len(args.producers) or
            len(set(args.budgets)) != len(args.budgets) or
            len(set(args.policies)) != len(args.policies) or
            len(set(args.workloads)) != len(args.workloads) or
            any(n < 1 or n > 64 for n in args.producers) or
            any(n not in (8, 64, 512, 4096) for n in args.budgets) or
            1 not in args.producers or
            not 0 <= args.cooldown_ms <= 10000):
        parser.error("invalid bounded matrix parameters (include 1 producer)")

    root = Path(__file__).resolve().parents[2]
    binary = build(root, args.compiler)
    binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)

    rows = []
    for rnd in range(args.rounds):
        for workload in args.workloads:
            for producers in args.producers:
                for budget in args.budgets:
                    # Policies alternate between rounds. Within each policy
                    # the two counter modes are consecutive and alternate
                    # their execution order between matching rounds.
                    policies = list(args.policies)
                    if (rnd + producers) % 2:
                        policies.reverse()
                    for policy in policies:
                        modes = list(COUNTERS)
                        if (rnd + producers + args.policies.index(policy)) % 2:
                            modes.reverse()
                        for counter in modes:
                            row = run_child(
                                root, binary, rnd, producers, budget, policy,
                                workload, args.workers, args.tasks, counter)
                            if row["profile_mode"] != "plain":
                                raise RuntimeError("profiler unexpectedly active")
                            row["binary_sha256"] = binary_sha
                            rows.append(row)
                            print(
                                f"R05 counter round={rnd} workload={workload}"
                                f" producers={producers} policy={policy}"
                                f" counter={counter} rate="
                                f"{row['throughput_per_s']:.0f}"
                                f" voluntary={row['child_voluntary_switches']}",
                                flush=True,
                            )
                            if args.cooldown_ms:
                                time.sleep(args.cooldown_ms / 1000)

    cases = {
        (r["round"], r["workload"], r["producers"], r["budget"],
         r["policy"], r["counter"]): r for r in rows
    }
    expected = (args.rounds * len(args.workloads) * len(args.producers)
                * len(args.budgets) * len(args.policies) * len(COUNTERS))
    if len(cases) != expected or len(rows) != expected:
        raise RuntimeError("missing or duplicate counter comparison case")

    # The benchmark checks these itself; also verify consistency among
    # independent child processes and between counter layouts.
    checksums = {}
    for row in rows:
        key = (row["workload"], row["tasks"])
        checksums.setdefault(key, set()).add(row["checksum"])
        if (row["completed"] != args.tasks or
                row["fresh_nodes"] + row["reused_nodes"] != args.tasks or
                row["counter"] not in COUNTERS or
                row["binary_sha256"] != binary_sha or
                row["observed_handles"] <= 0):
            raise RuntimeError("completion or same-binary invariant failed")
    if any(len(values) != 1 for values in checksums.values()):
        raise RuntimeError("counter modes disagree on deterministic checksum")

    write_csv(out / "raw.csv", rows)
    paired = []
    summary = []
    for workload in args.workloads:
        for producers in args.producers:
            for budget in args.budgets:
                for policy in args.policies:
                    group = []
                    for rnd in range(args.rounds):
                        key = (rnd, workload, producers, budget, policy)
                        shared = cases[(*key, "shared")]
                        striped = cases[(*key, "striped")]
                        row = dict(round=rnd, workload=workload,
                                   producers=producers, budget=budget,
                                   policy=policy,
                                   striped_over_shared=ratio(
                                       striped, shared, "throughput_per_s"),
                                   shared_tasks_per_s=shared["throughput_per_s"],
                                   striped_tasks_per_s=striped["throughput_per_s"])
                        for metric in MEASURES[1:]:
                            row["shared_" + metric] = shared[metric]
                            row["striped_" + metric] = striped[metric]
                            row["striped_over_shared_" + metric] = ratio(
                                striped, shared, metric)
                        paired.append(row)
                        group.append(row)
                    ratios = [row["striped_over_shared"] for row in group]
                    summary.append(dict(
                        workload=workload, producers=producers,
                        budget=budget, policy=policy, rounds=len(group),
                        median_striped_over_shared=statistics.median(ratios),
                        min_striped_over_shared=min(ratios),
                        max_striped_over_shared=max(ratios),
                        striped_wins=sum(x > 1 for x in ratios),
                        median_shared_tasks_per_s=statistics.median(
                            row["shared_tasks_per_s"] for row in group),
                        median_striped_tasks_per_s=statistics.median(
                            row["striped_tasks_per_s"] for row in group),
                        median_shared_voluntary_switches=statistics.median(
                            row["shared_child_voluntary_switches"] for row in group),
                        median_striped_voluntary_switches=statistics.median(
                            row["striped_child_voluntary_switches"] for row in group)))
    write_csv(out / "pairs.csv", paired)
    write_csv(out / "summary.csv", summary)

    # Cross-process 4-vs-1 and 8-vs-1 diagnostic. These comparisons are
    # matched only by round/counter/policy/workload, not concurrent trials.
    scaling = []
    scaling_summary = []
    for workload in args.workloads:
        for budget in args.budgets:
            for policy in args.policies:
                for counter in COUNTERS:
                    for producers in args.producers:
                        if producers == 1:
                            continue
                        subset = []
                        for rnd in range(args.rounds):
                            key = (rnd, workload, budget, policy, counter)
                            single = cases[(rnd, workload, 1, budget, policy,
                                            counter)]
                            target = cases[(rnd, workload, producers, budget,
                                            policy, counter)]
                            row = dict(
                                round=rnd, workload=workload, budget=budget,
                                policy=policy, counter=counter,
                                target_producers=producers,
                                target_over_one_throughput=ratio(
                                    target, single, "throughput_per_s"),
                                one_tasks_per_s=single["throughput_per_s"],
                                target_tasks_per_s=target["throughput_per_s"],
                                one_child_voluntary_switches=single[
                                    "child_voluntary_switches"],
                                target_child_voluntary_switches=target[
                                    "child_voluntary_switches"])
                            scaling.append(row)
                            subset.append(row["target_over_one_throughput"])
                        scaling_summary.append(dict(
                            workload=workload, budget=budget, policy=policy,
                            counter=counter, target_producers=producers,
                            rounds=len(subset),
                            median_target_over_one_throughput=statistics.median(
                                subset),
                            target_wins=sum(v > 1 for v in subset)))
    if scaling:
        write_csv(out / "producer_scaling.csv", scaling)
        write_csv(out / "producer_scaling_summary.csv", scaling_summary)
    save_environment(out, root, args, binary_sha)
    print("PASS: same uninstrumented binary; counter paired and "
          "scaling diagnostics written to", out)


if __name__ == "__main__":
    main()
