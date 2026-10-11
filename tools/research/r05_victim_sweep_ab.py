#!/usr/bin/env python3
"""R0.5: isolate N-slot victim search vs original N-1 slot search.

Both throughput variants are untraced and keep inbox batch8. A separate,
worker-local search trace provides mechanism evidence with an untraced
control; do not use traced child wall-time as scheduler performance.
"""
import argparse
from pathlib import Path
import platform
import statistics
import subprocess

import r05_batch_size_ab as base
import r05_worker_search_matrix as search


BINS = {
    "old": {
        "burst": ("burst-head-of-line-benchmark",
                  "concurrency-burst-head-of-line"),
        "mixed": ("task-pipeline-mixed-benchmark",
                  "concurrency-task-pipeline-mixed"),
        "trace": ("burst-head-of-line-search-batch8",
                  "concurrency-burst-head-of-line-search-batch8"),
    },
    "full": {
        "burst": ("burst-head-of-line-full-victim-sweep",
                  "concurrency-burst-head-of-line-full-victim-sweep"),
        "mixed": ("task-pipeline-mixed-full-victim-sweep",
                  "concurrency-task-pipeline-mixed-full-victim-sweep"),
        "trace": ("burst-head-of-line-search-full-victim-sweep",
                  "concurrency-burst-head-of-line-search-full-victim-sweep"),
    },
}
MODES = ("old", "full")


def self_check_victim_scan():
    """Demonstrate the exact N-1-index/self-skip omission before running D."""
    n = 4
    omissions = 0
    for self in range(n):
        for start in range(n):
            def visits(count):
                return [(start + step) % n for step in range(count)
                        if (start + step) % n != self]
            old = visits(n - 1)
            full = visits(n)
            expected = set(range(n)) - {self}
            if set(old) != expected:
                omissions += 1
            if len(full) != n - 1 or set(full) != expected:
                raise RuntimeError("complete scan omits or duplicates a victim")
    if omissions == 0:
        raise RuntimeError("old-scan omission control did not reproduce")


def build(root, compiler):
    for variant in MODES:
        for config, binary in BINS[variant].values():
            subprocess.run(["dub", "build", "--config=" + config,
                            "--build=release", "--compiler=" + compiler,
                            "--force"], cwd=root, check=True)
            if not (root / binary).is_file():
                raise RuntimeError("DUB failed to create " + binary)


def case_order(round_id, blockers, storage, notify):
    parity = round_id + blockers + int(storage == "recycle") + int(
        notify == "waiter")
    return MODES if parity % 2 else tuple(reversed(MODES))


def run_search(binary, root, storage, notify, blockers, ms, variant,
               round_id):
    rows, resources = base.run_child(
        [str(binary), notify, storage, "4", str(blockers), "8", str(ms)], root)
    status = search.parse_case(rows, blockers, 8)
    events = search.parse_search(rows, status["gate_release_ns"])
    final_start = status["final_blocker_start_ns"]
    gate = status["gate_release_ns"]
    spare_workers = set(status["free_workers"])
    if not status["all_blockers_before_gate"]:
        spare_workers = set()
    misses = hits = park_checks = spanning = 0
    event_rows = []
    for event in events:
        event.update(variant=variant, round=round_id, storage=storage,
                     notify=notify, blockers=blockers,
                     spare_worker=int(event["worker"] in spare_workers),
                     after_last_blocker_before_gate=int(
                         final_start <= event["offset_ns"] < gate))
        event_rows.append(event)
        if event["worker"] not in spare_workers:
            continue
        if final_start <= event["offset_ns"] < gate:
            misses += int(event["kind"] == "stealMiss")
            hits += int(event["kind"] == "stealHit")
            park_checks += int(event["kind"] == "parkCheck")
        if event["kind"] == "parkReturn":
            spanning += event["park_spanned_gate"]
    return dict(variant=variant, round=round_id, storage=storage,
                notify=notify, blockers=blockers,
                pre_gate=status["sibling_pre_gate"],
                all_blockers_before_gate=status["all_blockers_before_gate"],
                free_workers=len(spare_workers),
                spare_misses=misses, spare_hits=hits,
                spare_park_checks=park_checks,
                spare_waits_spanning_gate=spanning,
                events=len(events),
                child_wall_ns=resources["child_wall_ns"]), event_rows


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
    p.add_argument("--workloads", nargs="+", choices=("minimal", "compute"),
                   default=["minimal", "compute"])
    p.add_argument("--budget", type=int, default=512)
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-victim-sweep-ab"))
    args = p.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= args.rounds <= 20 or
            not 10 <= args.burst_ms <= 2000 or
            not 1 <= args.tasks <= 100_000 or
            args.budget not in (8, 64, 512, 4096) or
            not args.blockers or
            any(x not in (3, 4) for x in args.blockers) or
            not args.producers or
            any(x not in (1, 4, 8) for x in args.producers)):
        p.error("invalid bounded R0.5 victim-sweep settings")
    for sequence in (args.blockers, args.producers, args.policies,
                     args.notify, args.workloads):
        if len(set(sequence)) != len(sequence):
            p.error("duplicate independent factors")

    self_check_victim_scan()
    root = Path(__file__).resolve().parents[2]
    build(root, args.compiler)
    args.output.mkdir(parents=True, exist_ok=True)
    bursts, siblings, searches, search_events, mixed, pairs = [], [], [], [], [], []
    for round_id in range(args.rounds):
        for storage in args.policies:
            for notify in args.notify:
                for blockers in args.blockers:
                    observed = {}
                    for mode in case_order(round_id, blockers, storage, notify):
                        exe = root / BINS[mode]["burst"][1]
                        case, members = base.burst_case(
                            exe, root, 8, storage, notify,
                            blockers, args.burst_ms)
                        case.update(variant=mode, round=round_id)
                        bursts.append(case)
                        for member in members:
                            member.update(variant=mode, round=round_id)
                            siblings.append(member)
                        observed[mode] = case
                    old, full = observed["old"], observed["full"]
                    pairs.append(dict(
                        kind="burst", round=round_id, storage=storage,
                        notify=notify, blockers=blockers, producers="",
                        workload="", metric="pre_gate_siblings",
                        old=old["siblings_started_before_gate"],
                        full=full["siblings_started_before_gate"],
                        delta=full["siblings_started_before_gate"] -
                        old["siblings_started_before_gate"], ratio=""))
                    for mode in case_order(round_id + 1, blockers, storage, notify):
                        exe = root / BINS[mode]["trace"][1]
                        case, events = run_search(exe, root, storage, notify,
                                                  blockers, args.burst_ms,
                                                  mode, round_id)
                        searches.append(case)
                        search_events.extend(events)
                    print(f"burst r={round_id} {storage}/{notify} b={blockers}: "
                          f"old={old['siblings_started_before_gate']} "
                          f"full={full['siblings_started_before_gate']}",
                          flush=True)
                for workload in args.workloads:
                    for producers in args.producers:
                        observed = {}
                        for mode in case_order(
                                round_id, producers, storage, notify):
                            exe = root / BINS[mode]["mixed"][1]
                            case = base.mixed_case(
                                exe, root, 8, storage, notify, producers,
                                args.tasks, args.budget, workload)
                            case.update(variant=mode, round=round_id)
                            mixed.append(case)
                            observed[mode] = case
                        old, full = observed["old"], observed["full"]
                        pairs.append(dict(
                            kind="mixed", round=round_id, storage=storage,
                            notify=notify, blockers="", producers=producers,
                            workload=workload, metric="throughput_per_s",
                            old=old["throughput_per_s"],
                            full=full["throughput_per_s"],
                            delta=full["throughput_per_s"] -
                            old["throughput_per_s"],
                            ratio=full["throughput_per_s"] /
                            old["throughput_per_s"]))
                        print(f"mixed r={round_id} {storage}/{notify} "
                              f"p={producers} workload={workload}: "
                              f"full/old={full['throughput_per_s'] / old['throughput_per_s']:.3f}",
                              flush=True)

    base.write_csv(args.output / "burst_cases.csv", bursts)
    base.write_csv(args.output / "burst_siblings.csv", siblings)
    base.write_csv(args.output / "worker_search_cases.csv", searches)
    base.write_csv(args.output / "worker_search_events.csv", search_events)
    base.write_csv(args.output / "mixed_cases.csv", mixed)
    base.write_csv(args.output / "pairs.csv", pairs)

    summary = []
    for kind, extra in (("burst", "blockers"), ("mixed", "producers")):
        for storage in args.policies:
            for notify in args.notify:
                for value in (args.blockers if kind == "burst"
                              else args.producers):
                    for workload in ([""] if kind == "burst"
                                     else args.workloads):
                        group = [
                            r for r in pairs if r["kind"] == kind and
                            r["storage"] == storage and
                            r["notify"] == notify and
                            r[extra] == value and
                            r["workload"] == workload]
                        if len(group) != args.rounds:
                            raise RuntimeError("incomplete paired comparisons")
                        summary.append(dict(
                            kind=kind, storage=storage, notify=notify,
                            blockers=value if kind == "burst" else "",
                            producers=value if kind == "mixed" else "",
                            workload=workload, rounds=len(group),
                            metric=group[0]["metric"],
                            median_old=statistics.median(
                                row["old"] for row in group),
                            median_full=statistics.median(
                                row["full"] for row in group),
                            median_paired_delta=statistics.median(
                                row["delta"] for row in group),
                            median_paired_ratio=(
                                statistics.median(
                                    row["ratio"] for row in group)
                                if kind == "mixed" else ""),
                            full_faster_rounds=(
                                sum(row["ratio"] > 1 for row in group)
                                if kind == "mixed" else "")))
    base.write_csv(args.output / "summary.csv", summary)
    with (args.output / "environment.txt").open("w") as fd:
        fd.write(f"platform={platform.platform()}\ncompiler={args.compiler}\n"
                 f"rounds={args.rounds} workers=4 burst_ms={args.burst_ms}\n"
                 f"storage={args.policies} notify={args.notify} "
                 f"blockers={args.blockers}\n"
                 f"producers={args.producers} workloads={args.workloads} "
                 f"tasks={args.tasks} budget={args.budget}\n"
                 "batch=8 BOTH. Only victim slots (N-1 vs N) differ.\n"
                 "Untraced throughput and sibling starts; worker search is "
                 "separate observational evidence.\n")
        for cmd in (["git", "rev-parse", "HEAD"], [args.compiler, "--version"],
                    ["lscpu"]):
            fd.write("$ " + " ".join(cmd) + "\n")
            try:
                fd.write(subprocess.run(cmd, cwd=root, check=True,
                    capture_output=True, text=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")
    print("R0.5 complete victim sweep: mechanism A/B only, no promotion")
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
