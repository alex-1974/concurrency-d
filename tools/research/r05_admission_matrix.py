#!/usr/bin/env python3
"""R0.5 admission contention and task-counter isolation, Linux-only research.

The admission probe is opt-in and per-producer. Its clock calls and
histogram writes perturb the observed path; compare GC/recycling only
within like-for-like counter and probe configurations. Each case runs in
its own child process so RSS and GC measurements remain process-scoped.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


METRICS = (
    "metric", "scenario", "policy", "workers", "producers", "budget",
    "tasks", "elapsed_ms", "throughput_per_s", "fresh_nodes",
    "reused_nodes", "producer_gc_bytes", "used_close_delta",
    "used_after_collect_delta", "observed_handles", "completed",
)
ADMISSION = (
    "metric", "policy", "counter_mode", "producers", "workers",
    "budget", "tasks", "attempts", "accepted", "retention_full",
    "ingress_full", "yields", "wait_ns", "hold_ns", "max_wait_ns",
    "max_hold_ns", "wait_p50_upper_ns", "wait_p95_upper_ns",
    "wait_p99_upper_ns", "hold_p50_upper_ns", "hold_p95_upper_ns",
    "hold_p99_upper_ns",
)


def build(root, compiler):
    subprocess.run(
        ["dub", "build", "--config=task-pipeline-mixed-benchmark",
         "--build=release", "--compiler=" + compiler, "--force"],
        cwd=root, check=True,
    )
    target = root / "concurrency-task-pipeline-mixed"
    if not target.is_file():
        raise RuntimeError("DUB target absent: " + str(target))
    return target


def run_case(binary, root, workers, producers, tasks, budget,
             policy, counter_mode, round_number):
    args = [str(binary), str(workers), str(producers), str(tasks),
            str(budget), policy, counter_mode, "on"]

    with tempfile.TemporaryFile(mode="w+t") as fd:
        child = subprocess.Popen(
            args, cwd=root, stdout=fd, stderr=subprocess.STDOUT,
        )
        _, status, usage = os.wait4(child.pid, 0)
        code = os.waitstatus_to_exitcode(status)
        fd.seek(0)
        content = fd.read()  # TemporaryFile(mode="w+t") already returns str.

    if code != 0:
        raise RuntimeError(
            f"case {producers}/{budget}/{policy}/{counter_mode} "
            f"round={round_number} exited {code}:\n{content[-6000:]}"
        )

    results = [s for s in content.splitlines()
               if s.startswith("multi,mixed,")]
    profiles = [s for s in content.splitlines()
                if s.startswith("admission,")]
    if len(results) != 1 or len(profiles) != 1:
        raise RuntimeError("expected exactly one result and admission row:\n"
                           + content)

    perf = next(csv.reader(results))
    admission = next(csv.reader(profiles))
    if len(perf) != len(METRICS) or len(admission) != len(ADMISSION):
        raise RuntimeError(
            f"invalid CSV schema: perf={len(perf)}, profile="
            f"{len(admission)} expected {len(METRICS)}/{len(ADMISSION)}"
        )

    row = dict(zip(METRICS, perf))
    row.update({key: value for key, value in zip(ADMISSION, admission)
                if key not in row or key == "counter_mode"})
    if (row["policy"] != policy or
        row["counter_mode"] != counter_mode or
        int(row["completed"]) != tasks or
        int(row["accepted"]) != tasks or
        int(row["tasks"]) != tasks):
        raise RuntimeError("incorrect cross-thread completion accounting")

    attempts = int(row["attempts"])
    retention = int(row["retention_full"])
    ingress = int(row["ingress_full"])
    retries = int(row["yields"])
    if attempts != tasks + retention + ingress or retries != retention + ingress:
        raise RuntimeError("missing or duplicated admission samples")

    row["round"] = str(round_number)
    row["peak_rss_kib"] = str(usage.ru_maxrss)
    row.pop("metric", None)
    row.pop("scenario", None)
    return row


def median(values):
    return statistics.median(values)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--compiler", default="ldc2")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--tasks", type=int, default=12000)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--producers", type=int, nargs="+", default=[1, 4, 8])
    ap.add_argument("--budgets", type=int, nargs="+", default=[8, 512])
    ap.add_argument("--counter-modes", nargs="+", default=["shared", "striped"],
                    choices=["shared", "striped"])
    ap.add_argument("--output", type=Path,
                    default=Path("evidence/r05-admission"))
    args = ap.parse_args()

    if platform.system() != "Linux":
        ap.error("this instrument requires Linux wait4")
    if (args.workers < 1 or args.workers > 64 or
        args.tasks < 1 or args.tasks > 2_000_000 or
        args.rounds < 1 or args.rounds > 20 or
        not args.producers or not args.budgets or
        any(p < 1 or p > 64 for p in args.producers) or
        any(b not in [8, 64, 512, 4096] for b in args.budgets)):
        ap.error("invalid worker/producer/task/budget/round count")

    root = Path(__file__).resolve().parents[2]
    binary = build(root, args.compiler)
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for rnd in range(args.rounds):
        for p in args.producers:
            for budget in args.budgets:
                for counter_mode in args.counter_modes:
                    policies = ("gc", "recycle") if rnd % 2 == 0 else (
                        "recycle", "gc")
                    for policy in policies:
                        row = run_case(binary, root, args.workers, p,
                                       args.tasks, budget, policy,
                                       counter_mode, rnd)
                        rows.append(row)
                        print(
                            f"R05 admission p={p} budget={budget} "
                            f"counter={counter_mode} policy={policy} "
                            f"round={rnd} throughput={row['throughput_per_s']} "
                            f"wait_p95_upper_ns={row['wait_p95_upper_ns']} "
                            f"hold_p95_upper_ns={row['hold_p95_upper_ns']} "
                            f"retries={row['yields']}",
                            flush=True,
                        )

    with (args.output / "raw.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    keys = {}
    for row in rows:
        key = (int(row["producers"]), int(row["budget"]),
               row["counter_mode"], int(row["round"]))
        keys.setdefault(key, {})[row["policy"]] = row

    summary = []
    for p in args.producers:
        for b in args.budgets:
            for mode in args.counter_modes:
                cases = [keys[(p, b, mode, rnd)]
                         for rnd in range(args.rounds)]
                if any(set(case) != {"gc", "recycle"} for case in cases):
                    raise RuntimeError("incomplete paired performance case")
                ratios = [
                    float(case["recycle"]["throughput_per_s"]) /
                    float(case["gc"]["throughput_per_s"])
                    for case in cases
                ]
                for policy in ("gc", "recycle"):
                    candidates = [x[policy] for x in cases]
                    def med_num(field):
                        return median([float(c[field]) for c in candidates])
                    summary.append({
                        "producers": p, "budget": b,
                        "counter_mode": mode, "policy": policy,
                        "rounds": args.rounds,
                        "median_throughput": round(med_num("throughput_per_s"), 1),
                        "median_retries_per_task": round(
                            med_num("yields") / args.tasks, 4),
                        "median_wait_ns_per_attempt": round(med_num("wait_ns") /
                                                            med_num("attempts"), 1),
                        "median_hold_ns_per_attempt": round(med_num("hold_ns") /
                                                            med_num("attempts"), 1),
                        "median_wait_p95_upper_ns": int(
                            med_num("wait_p95_upper_ns")),
                        "median_hold_p95_upper_ns": int(
                            med_num("hold_p95_upper_ns")),
                        "paired_recycle_over_gc": round(median(ratios), 4),
                    })

    with (args.output / "summary.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)

    with (args.output / "environment.txt").open("w") as out:
        out.write(f"compiler={args.compiler}\nplatform={platform.platform()}\n"
                  f"machine={platform.machine()}\n"
                  f"workers={args.workers} tasks={args.tasks} rounds={args.rounds}\n"
                  f"producers={args.producers} budgets={args.budgets}\n"
                  f"counter_modes={args.counter_modes}\n")
        for command in (["git", "rev-parse", "HEAD"],
                        ["ldc2", "--version"], ["lscpu"]):
            try:
                out.write("$ " + " ".join(command) + "\n")
                out.write(subprocess.run(command, cwd=root, text=True,
                          capture_output=True, check=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                out.write("command unavailable\n")

    print("R05 ADMISSION SUMMARY (timed probe overhead included)")
    for row in summary:
        if row["policy"] == "recycle":
            print(f"producers={row['producers']} budget={row['budget']} "
                  f"counter={row['counter_mode']} recycle/gc="
                  f"{row['paired_recycle_over_gc']:.4f}x")
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
