#!/usr/bin/env python3
"""Research-only untraced R0.5 claim-size sweep (1/2/4/8).

Reuses the already qualified exact-once, typed-result, gate-timing and mixed
workload parsers from r05_batch_size_ab.py. Never infers a p99 guarantee from
eight siblings or claims that process CPU equals worker idle-CPU.
"""
import argparse
from pathlib import Path
import platform
import statistics
import subprocess

import r05_batch_size_ab as baseline


BINS = {
    batch: {
        "burst": (
            f"burst-head-of-line-batch{batch}",
            f"concurrency-burst-head-of-line-batch{batch}"),
        "mixed": (
            f"task-pipeline-mixed-batch{batch}",
            f"concurrency-task-pipeline-mixed-batch{batch}"),
    }
    for batch in (1, 2, 4)
}
BINS[8] = baseline.BINS[8]
SIZES = (8, 1, 2, 4)


def order_for(round_id, group):
    """Rotate all four positions across four rounds; no random seed."""
    shift = (round_id + group) % len(SIZES)
    return SIZES[shift:] + SIZES[:shift]


def grouped_median(rows, field):
    return statistics.median(row[field] for row in rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--burst-ms", type=int, default=100)
    p.add_argument("--blockers", nargs="+", type=int, default=[3, 4])
    p.add_argument("--policies", nargs="+", choices=("gc", "recycle"),
                   default=["gc", "recycle"])
    p.add_argument("--notify", nargs="+", choices=("always", "waiter"),
                   default=["always", "waiter"])
    p.add_argument("--tasks", type=int, default=6000)
    p.add_argument("--producers", nargs="+", type=int, default=[1, 4])
    p.add_argument("--budget", type=int, default=512)
    p.add_argument("--workload", choices=("minimal", "compute"),
                   default="minimal")
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-batch-size-sweep"))
    a = p.parse_args()
    if (platform.system() != "Linux" or platform.architecture()[0] != "64bit"
            or not 1 <= a.rounds <= 20 or
            not 10 <= a.burst_ms <= 2000 or
            not 1 <= a.tasks <= 100_000 or
            a.budget not in (8, 64, 512, 4096) or
            not a.blockers or
            any(n not in (3, 4) for n in a.blockers) or
            not a.producers or
            any(n not in (1, 4, 8) for n in a.producers)):
        p.error("invalid bounded batch sweep settings")
    for independent in (a.blockers, a.policies, a.notify, a.producers):
        if len(independent) != len(set(independent)):
            p.error("duplicate independent factor")

    root = Path(__file__).resolve().parents[2]
    for batch in SIZES:
        for config, filename in BINS[batch].values():
            subprocess.run(
                ["dub", "build", "--config=" + config,
                 "--build=release", "--compiler=" + a.compiler, "--force"],
                cwd=root, check=True)
            if not (root / filename).is_file():
                raise RuntimeError("missing DUB executable " + filename)

    a.output.mkdir(parents=True, exist_ok=True)
    burst, sibling, mixed, paired = [], [], [], []
    for rnd in range(a.rounds):
        for storage in a.policies:
            for notify in a.notify:
                for blockers in a.blockers:
                    group = blockers + (storage == "recycle") + (
                        notify == "waiter")
                    cases = {}
                    for batch in order_for(rnd, group):
                        exe = root / BINS[batch]["burst"][1]
                        case, rows = baseline.burst_case(
                            exe, root, batch, storage, notify, blockers,
                            a.burst_ms)
                        case["round"] = rnd
                        burst.append(case)
                        for row in rows:
                            row["round"] = rnd
                            sibling.append(row)
                        cases[batch] = case
                    old = cases[8]
                    for batch in (1, 2, 4):
                        new = cases[batch]
                        paired.append(dict(
                            kind="burst", round=rnd, storage=storage,
                            notify=notify, blockers=blockers, producers="",
                            workload="", batch=batch,
                            metric="siblings_started_before_gate",
                            batch8=old["siblings_started_before_gate"],
                            variant=new["siblings_started_before_gate"],
                            difference=new["siblings_started_before_gate"] -
                            old["siblings_started_before_gate"],
                            ratio=""))
                    print(f"burst {rnd=} {storage}/{notify} blockers={blockers} "
                          + " ".join(
                              f"b{n}={cases[n]['siblings_started_before_gate']}"
                              for n in SIZES), flush=True)
                for producers in a.producers:
                    group = producers + (storage == "recycle") + (
                        notify == "waiter")
                    cases = {}
                    for batch in order_for(rnd, group):
                        exe = root / BINS[batch]["mixed"][1]
                        case = baseline.mixed_case(
                            exe, root, batch, storage, notify, producers,
                            a.tasks, a.budget, a.workload)
                        case["round"] = rnd
                        mixed.append(case)
                        cases[batch] = case
                    old = cases[8]
                    for batch in (1, 2, 4):
                        new = cases[batch]
                        paired.append(dict(
                            kind="mixed", round=rnd, storage=storage,
                            notify=notify, blockers="", producers=producers,
                            workload=a.workload, batch=batch,
                            metric="throughput_per_s",
                            batch8=old["throughput_per_s"],
                            variant=new["throughput_per_s"],
                            difference=new["throughput_per_s"] -
                            old["throughput_per_s"],
                            ratio=new["throughput_per_s"] /
                            old["throughput_per_s"]))
                    print(f"mixed {rnd=} {storage}/{notify} "
                          f"producers={producers} "
                          + " ".join(
                              f"b{n}={cases[n]['throughput_per_s']:.0f}"
                              for n in SIZES), flush=True)

    baseline.write_csv(a.output / "burst_cases.csv", burst)
    baseline.write_csv(a.output / "burst_siblings.csv", sibling)
    baseline.write_csv(a.output / "mixed_cases.csv", mixed)
    baseline.write_csv(a.output / "paired.csv", paired)

    # Per-case and pooled, untraced latency distributions are separate.
    latency = []
    for storage in a.policies:
        for notify in a.notify:
            for blockers in a.blockers:
                for batch in SIZES:
                    group = [r for r in burst if r["batch"] == batch and
                             r["storage"] == storage and
                             r["notify"] == notify and
                             r["blockers"] == blockers]
                    samples = [r["start_ns"] for r in sibling
                               if r["batch"] == batch and
                               r["storage"] == storage and
                               r["notify"] == notify and
                               r["blockers"] == blockers]
                    if len(group) != a.rounds or len(samples) != 8 * a.rounds:
                        raise RuntimeError("missing burst latency evidence")
                    latency.append(dict(
                        storage=storage, notify=notify, blockers=blockers,
                        batch=batch, rounds=a.rounds, samples=len(samples),
                        start_p50_ns=baseline.percentile(samples, 50),
                        start_p95_ns=baseline.percentile(samples, 95),
                        start_p99_ns=baseline.percentile(samples, 99),
                        median_case_p95_ns=grouped_median(
                            group, "start_p95_ns"),
                        before_gate=sum(
                            x["siblings_started_before_gate"] for x in group),
                        after_gate=sum(
                            x["siblings_started_after_gate"] for x in group),
                        progress_after_final_blocker=sum(
                            x["progress_after_final_blocker"] for x in group),
                        median_child_cpu_user_us=grouped_median(
                            group, "child_cpu_user_us"),
                        median_child_cpu_system_us=grouped_median(
                            group, "child_cpu_system_us")))
    baseline.write_csv(a.output / "latency_summary.csv", latency)

    throughput = []
    for storage in a.policies:
        for notify in a.notify:
            for producers in a.producers:
                for batch in SIZES:
                    group = [r for r in mixed if r["batch"] == batch and
                             r["storage"] == storage and
                             r["notify"] == notify and
                             r["producers"] == producers]
                    if len(group) != a.rounds:
                        raise RuntimeError("missing mixed throughput evidence")
                    pairs = [r for r in paired if r["kind"] == "mixed" and
                             r["storage"] == storage and
                             r["notify"] == notify and
                             r["producers"] == producers and
                             r["batch"] == batch]
                    if batch == 8:
                        ratios = [1.0] * a.rounds
                    else:
                        if len(pairs) != a.rounds:
                            raise RuntimeError("missing throughput pairs")
                        ratios = [r["ratio"] for r in pairs]
                    throughput.append(dict(
                        storage=storage, notify=notify, producers=producers,
                        workload=a.workload, batch=batch, rounds=a.rounds,
                        median_tasks_per_s=grouped_median(
                            group, "throughput_per_s"),
                        paired_median_ratio_to_batch8=statistics.median(
                            ratios),
                        paired_faster_rounds=sum(x > 1 for x in ratios),
                        median_child_cpu_user_us=grouped_median(
                            group, "child_cpu_user_us"),
                        median_child_cpu_system_us=grouped_median(
                            group, "child_cpu_system_us")))
    baseline.write_csv(a.output / "throughput_summary.csv", throughput)

    with (a.output / "environment.txt").open("w") as fd:
        fd.write(f"platform={platform.platform()}\n"
                 f"machine={platform.machine()}\n"
                 f"compiler={a.compiler}\n"
                 f"sizes={SIZES} rounds={a.rounds} workers=4 "
                 f"burst_ms={a.burst_ms}\n"
                 f"blockers={a.blockers} policies={a.policies} "
                 f"notify={a.notify}\n"
                 f"tasks={a.tasks} producers={a.producers} "
                 f"budget={a.budget} workload={a.workload}\n"
                 "Each size runs the same uninstrumented source and compiler.\n"
                 "Gate timestamp is real, not nominal sleep; p99 of eight "
                 "siblings alone is only a maximum.\n"
                 "CPU fields describe whole-child resources, not worker idle.\n")
        for cmd in (["git", "rev-parse", "HEAD"], [a.compiler, "--version"],
                    ["lscpu"]):
            fd.write("$ " + " ".join(cmd) + "\n")
            try:
                fd.write(subprocess.run(cmd, cwd=root, capture_output=True,
                    text=True, check=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")
    print("R0.5 batch sweep: research only. Batch8 remains default.")
    print("evidence: " + str(a.output))


if __name__ == "__main__":
    main()
