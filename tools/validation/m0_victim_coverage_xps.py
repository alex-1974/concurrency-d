#!/usr/bin/env python3
"""Isolated production-M0 before/after victim-coverage performance qualification.

The benchmark source and DUB configuration are identical in two temporary
detached worktrees. Their scheduler code is taken from independently pinned
develop and fix commits. Neither the caller's checkout nor any other
repository is changed. Timing never includes compilation or CSV validation.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import statistics
import subprocess
import tempfile
import time

BASELINE_DEFAULT = "822a866d866dbb176f5435a41b09d189b8d0c4cb"
FIX_DEFAULT = "31f97b8315980b4b52a97cb1706a507a1422eaa5"

# Appended unmodified to each pinned source tree's own DUB metadata.
EXTRA_DUB = """
// Temporary identical external benchmark only; no public API/build change.
configuration "m0-victim-validation" {
    targetType "executable"
    mainSourceFile "benchmarks/m0_victim_coverage/main.d"
    sourcePaths "source" "benchmarks/m0_victim_coverage"
    importPaths "source" "benchmarks/m0_victim_coverage"
    targetName "concurrency-m0-victim-validation"
}
"""

MIXED = ("kind", "workers", "producers", "tasks", "budget", "rounds",
         "elapsed_ns", "accepted", "completed", "retries", "checksum")
IDLE = ("kind", "workers", "idle_ms", "samples", "gap_ms", "idle_cpu_us",
        "idle_wall_ns", "p50_ns", "p95_ns", "p99_ns", "max_ns",
        "completed", "checksum")
MODES = ("baseline", "fix")


def command(argv, cwd, timeout=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                            timeout=timeout)
    if result.returncode:
        raise RuntimeError(
            "command failed " + " ".join(map(str, argv)) + "\n" +
            (result.stdout + result.stderr)[-6000:])
    return result.stdout.strip()


def git(root, *args):
    return command(["git", *args], root)


def csv_save(path, records):
    if not records:
        raise RuntimeError("refuse empty evidence: " + str(path))
    with path.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)


def cpu_clock_snapshot_khz():
    """Optional CPU-frequency snapshot; NOT a workload average or control."""
    observed = []
    for path in Path("/sys/devices/system/cpu").glob(
            "cpu[0-9]*/cpufreq/scaling_cur_freq"):
        try:
            observed.append(int(path.read_text().strip()))
        except (OSError, ValueError):
            pass
    return int(statistics.median(observed)) if observed else ""


def run_child(executable, cwd, args, fields, cpu_snapshots=False):
    freq_before = cpu_clock_snapshot_khz() if cpu_snapshots else ""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter_ns()
    child = subprocess.run([str(executable), *map(str, args)], cwd=cwd,
                           capture_output=True, text=True, timeout=180)
    outer_ns = time.perf_counter_ns() - t0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    freq_after = cpu_clock_snapshot_khz() if cpu_snapshots else ""
    if child.returncode:
        raise RuntimeError("bad benchmark exit: " +
                           (child.stdout + child.stderr)[-7000:])
    rows = [row for row in csv.reader(child.stdout.splitlines())
            if row and row[0] == args[0]]
    if len(rows) != 1 or len(rows[0]) != len(fields):
        raise RuntimeError("missing/incorrect CSV schema: " + child.stdout)
    row = dict(zip(fields, rows[0]))
    result = {key: int(val) if key != "kind" else val
              for key, val in row.items()}
    result.update(
        process_wall_ns=outer_ns,
        process_user_cpu_us=round((after.ru_utime - before.ru_utime) * 1e6),
        process_sys_cpu_us=round((after.ru_stime - before.ru_stime) * 1e6),
        process_voluntary_cs=after.ru_nvcsw - before.ru_nvcsw,
        process_involuntary_cs=after.ru_nivcsw - before.ru_nivcsw,
        # ru_maxrss with RUSAGE_CHILDREN is a cumulative maximum, so its
        # value is not a reliable per-child RSS delta.
        process_peak_rss_kib=after.ru_maxrss,
        cpu_snapshot_median_khz_before=freq_before,
        cpu_snapshot_median_khz_after=freq_after)
    return result


def prepare_worktree(root, target, sha, source, compiler):
    git(root, "worktree", "add", "--detach", "--quiet", str(target), sha)
    dst = target / "benchmarks/m0_victim_coverage/main.d"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, dst)
    dub = target / "dub.sdl"
    text = dub.read_text()
    if "m0-victim-validation" in text:
        raise RuntimeError("benchmark config unexpected in pinned commit")
    dub.write_text(text.rstrip() + "\n" + EXTRA_DUB)
    command(["dub", "build", "--config=m0-victim-validation",
             "--build=release", "--compiler=" + compiler, "--force"],
            target, timeout=180)
    exe = target / "concurrency-m0-victim-validation"
    if not exe.is_file():
        raise RuntimeError("dub did not produce benchmark binary")
    return exe


def order(round_id, factor):
    return MODES if (round_id + factor) % 2 else tuple(reversed(MODES))


def pairs_for(kind, key, examples, measures):
    result = []
    for metric in measures:
        a, b = examples["baseline"][metric], examples["fix"][metric]
        result.append(dict(kind=kind, metric=metric, **key,
                           baseline=a, fix=b, delta=b - a,
                           ratio=(b / a if a != 0 else "")))
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--baseline", default=BASELINE_DEFAULT)
    p.add_argument("--fix", default=FIX_DEFAULT)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--tasks", type=int, default=100_000)
    p.add_argument("--budget", type=int, default=512)
    p.add_argument("--workers", nargs="+", type=int, default=[1, 2, 4, 8])
    p.add_argument("--producers", nargs="+", type=int, default=[1, 4])
    p.add_argument("--workloads", nargs="+", choices=("minimal", "compute"),
                   default=["minimal", "compute"])
    p.add_argument("--compute-rounds", type=int, default=1024)
    p.add_argument("--idle-ms", type=int, default=300)
    p.add_argument("--wake-samples", type=int, default=64)
    p.add_argument("--gap-ms", type=int, default=1)
    p.add_argument("--cooldown-ms", type=int, default=25)
    p.add_argument("--idle-only", action="store_true",
                   help="Run paired idle/wake tests without mixed throughput")
    p.add_argument("--mixed-only", action="store_true",
                   help="Run paired mixed throughput without idle/wake probes")
    p.add_argument("--cpu-snapshots", action="store_true",
                   help="Record available CPU frequency snapshots around "
                        "each case (diagnostic only, no clock control)")
    p.add_argument("--output", type=Path,
                   default=Path("evidence/m0-victim-coverage-xps"))
    a = p.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= a.rounds <= 20 or
            not 384 <= a.tasks <= 500_000 or
            not 1 <= a.budget <= 4096 or
            not a.workers or any(w not in (1, 2, 3, 4, 8, 16)
                                 for w in a.workers) or
            not a.producers or any(x not in (1, 4, 8)
                                   for x in a.producers) or
            not 1 <= a.compute_rounds <= 4096 or
            not 100 <= a.idle_ms <= 10_000 or
            not 8 <= a.wake_samples <= 1000 or
            not 1 <= a.gap_ms <= 100 or
            not 0 <= a.cooldown_ms <= 1000):
        p.error("invalid bounded production M0 benchmark setting")
    if a.idle_only and a.mixed_only:
        p.error("--mixed-only and --idle-only are mutually exclusive")
    for f in (a.workers, a.producers, a.workloads):
        if len(f) != len(set(f)):
            p.error("duplicate independent factor")
    if len(a.baseline) != 40 or len(a.fix) != 40 or a.baseline == a.fix:
        p.error("must select distinct exact 40-hex Git commit SHAs")

    root = Path(__file__).resolve().parents[2]
    original_head = git(root, "rev-parse", "HEAD")
    for sha in (a.baseline, a.fix):
        git(root, "cat-file", "-e", sha + "^{commit}")
    if (git(root, "rev-parse", a.baseline) != a.baseline or
            git(root, "rev-parse", a.fix) != a.fix):
        raise RuntimeError("commit SHA resolution mismatch")

    source = root / "benchmarks/m0_victim_coverage/main.d"
    shared_source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
    a.output.mkdir(parents=True, exist_ok=True)
    output = a.output.resolve()
    mixed, idle, comparisons = [], [], []
    with tempfile.TemporaryDirectory(prefix="concurrency-m0-ab-") as tmp:
        dirs = {m: Path(tmp) / m for m in MODES}
        binaries = {}
        try:
            for m, sha in (("baseline", a.baseline), ("fix", a.fix)):
                binaries[m] = prepare_worktree(
                    root, dirs[m], sha, source, a.compiler)
                if hashlib.sha256(
                        (dirs[m] / "benchmarks/m0_victim_coverage/main.d"
                         ).read_bytes()).hexdigest() != shared_source_digest:
                    raise RuntimeError("benchmark source mismatch")
            # After both builds, require identical resolved DUB dependencies.
            locks = []
            for m in MODES:
                lock = dirs[m] / "dub.selections.json"
                locks.append(json.loads(lock.read_text())
                             if lock.is_file() else None)
            if locks[0] != locks[1]:
                raise RuntimeError(
                    "DUB dependency resolution differs between compared builds")
            # A correctness/pre-warmup smoke before timing of each executable.
            for mode in MODES:
                x = run_child(binaries[mode], dirs[mode],
                              ["mixed", 2, 2, 1024, 64, 16], MIXED)
                if x["accepted"] != 1024 or x["completed"] != 1024:
                    raise RuntimeError("warmup failed")
            for rnd in range(a.rounds):
                for workers in a.workers:
                    for producers in ([] if a.idle_only else a.producers):
                        for workload in a.workloads:
                            rounds = (0 if workload == "minimal"
                                      else a.compute_rounds)
                            rows = {}
                            for mode in order(
                                    rnd, workers + producers + rounds):
                                r = run_child(
                                    binaries[mode], dirs[mode],
                                    ["mixed", workers, producers, a.tasks,
                                     a.budget, rounds], MIXED,
                                    cpu_snapshots=a.cpu_snapshots)
                                if (r["workers"] != workers or
                                        r["producers"] != producers or
                                        r["tasks"] != a.tasks or
                                        r["budget"] != a.budget or
                                        r["rounds"] != rounds or
                                        r["accepted"] != a.tasks or
                                        r["completed"] != a.tasks or
                                        r["elapsed_ns"] <= 0):
                                    raise RuntimeError("mixed accounting failed")
                                r["throughput_per_s"] = (
                                    a.tasks * 1_000_000_000.0 /
                                    r["elapsed_ns"])
                                r.update(mode=mode, round=rnd,
                                         workload=workload)
                                mixed.append(r)
                                rows[mode] = r
                                time.sleep(a.cooldown_ms / 1000.0)
                            if rows["baseline"]["checksum"] !=                                     rows["fix"]["checksum"]:
                                raise RuntimeError(
                                    "different results between exact commits")
                            key = dict(round=rnd, workers=workers,
                                       producers=producers, workload=workload)
                            comparisons += pairs_for("mixed", key, rows,
                                ("throughput_per_s", "elapsed_ns",
                                 "process_user_cpu_us", "process_sys_cpu_us",
                                 "process_voluntary_cs",
                                 "process_involuntary_cs"))
                            print("mixed", key,
                                  "fix/base throughput:",
                                  round(rows["baseline"]["elapsed_ns"] /
                                        rows["fix"]["elapsed_ns"], 4),
                                  flush=True)
                for workers in ([] if a.mixed_only else a.workers):
                    rows = {}
                    for mode in order(rnd, workers):
                        r = run_child(binaries[mode], dirs[mode],
                            ["idle", workers, a.idle_ms,
                             a.wake_samples, a.gap_ms], IDLE)
                        if (r["workers"] != workers or
                                r["completed"] != a.wake_samples or
                                not (0 <= r["p50_ns"] <= r["p95_ns"] <=
                                     r["p99_ns"] <= r["max_ns"])):
                            raise RuntimeError("invalid idle results")
                        r.update(mode=mode, round=rnd)
                        idle.append(r)
                        rows[mode] = r
                        time.sleep(a.cooldown_ms / 1000.0)
                    if rows["baseline"]["checksum"] != rows["fix"]["checksum"]:
                        raise RuntimeError("idle result mismatch")
                    comparisons += pairs_for("idle",
                        dict(round=rnd, workers=workers,
                             producers="", workload=""), rows,
                        ("idle_cpu_us", "p50_ns", "p95_ns", "p99_ns",
                         "process_voluntary_cs",
                         "process_involuntary_cs"))
                    print("idle", rnd, workers,
                          "fix/base CPU us", rows["fix"]["idle_cpu_us"],
                          rows["baseline"]["idle_cpu_us"], flush=True)
        finally:
            # Clean up even after a child error. Original checkout untouched.
            for mode in reversed(MODES):
                if (dirs[mode] / ".git").exists():
                    subprocess.run(["git", "worktree", "remove", "--force",
                                    str(dirs[mode])], cwd=root,
                                   capture_output=True, text=True)
    if mixed:
        csv_save(output / "mixed.csv", mixed)
    if idle:
        csv_save(output / "idle.csv", idle)
    csv_save(output / "pairs.csv", comparisons)

    # A true one-worker no-stealing control can reveal common environment
    # drift in matching same-round, same-producer, same-workload pairs.
    # Keep absolute throughput ratios: normalization is diagnostic only.
    mixed_index = {
        (r["round"], r["workers"], r["producers"], r["workload"], r["mode"]): r
        for r in mixed
    }
    controls = []
    if 1 in a.workers:
        for rnd in range(a.rounds):
            for producers in a.producers:
                for workload in a.workloads:
                    base = mixed_index.get(
                        (rnd, 1, producers, workload, "baseline"))
                    fix = mixed_index.get(
                        (rnd, 1, producers, workload, "fix"))
                    if base is None or fix is None:
                        continue
                    control_ratio = (fix["throughput_per_s"] /
                                     base["throughput_per_s"])
                    for workers in a.workers:
                        if workers == 1:
                            continue
                        target_base = mixed_index.get(
                            (rnd, workers, producers, workload, "baseline"))
                        target_fix = mixed_index.get(
                            (rnd, workers, producers, workload, "fix"))
                        if target_base is None or target_fix is None:
                            raise RuntimeError("missing paired target control")
                        target_ratio = (target_fix["throughput_per_s"] /
                                        target_base["throughput_per_s"])
                        controls.append(dict(
                            round=rnd, workers=workers,
                            producers=producers, workload=workload,
                            target_fix_over_baseline=target_ratio,
                            worker1_fix_over_baseline=control_ratio,
                            relative_to_worker1=target_ratio / control_ratio))
    if controls:
        csv_save(output / "control_pairs.csv", controls)

    groups = {}
    for r in comparisons:
        g = (r["kind"], r["workers"], r["producers"],
             r["workload"], r["metric"])
        groups.setdefault(g, []).append(r)
    summary = []
    for (kind, workers, producers, workload, metric), group in sorted(
            groups.items(), key=lambda item: str(item[0])):
        if (len(group) != a.rounds or
                len({r["round"] for r in group}) != a.rounds):
            raise RuntimeError("incomplete M0 paired evidence")
        valid_ratios = [r["ratio"] for r in group if r["ratio"] != ""]
        summary.append(dict(
            kind=kind, workers=workers, producers=producers,
            workload=workload, metric=metric,
            rounds=len(group),
            median_base=statistics.median(r["baseline"] for r in group),
            median_fix=statistics.median(r["fix"] for r in group),
            median_paired_delta=statistics.median(r["delta"] for r in group),
            median_paired_ratio=(
                statistics.median(valid_ratios)
                if len(valid_ratios) == a.rounds else ""),
            fix_higher_rounds=sum(r["delta"] > 0 for r in group)))
    csv_save(output / "summary.csv", summary)

    with (output / "environment.txt").open("w") as out:
        out.write(f"validation_head={original_head}\n"
                  f"baseline={a.baseline}\nfix={a.fix}\n"
                  f"benchmark_sha256={shared_source_digest}\n"
                  f"platform={platform.platform()}\n"
                  f"compiler={a.compiler}\n"
                  f"rounds={a.rounds} tasks={a.tasks} budget={a.budget}\n"
                  f"workers={a.workers} producers={a.producers} "
                  f"workloads={a.workloads} compute_rounds={a.compute_rounds}\n"
                  f"idle_only={a.idle_only} mixed_only={a.mixed_only} "
                  f"cpu_snapshots={a.cpu_snapshots}\n"
                  f"idle_ms={a.idle_ms} wake_samples={a.wake_samples} "
                  f"gap_ms={a.gap_ms} cooldown_ms={a.cooldown_ms}\n"
                  "Both detached worktrees receive the identical benchmark "
                  "source/config. DUB dependency locks must agree.\n"
                  "Measured mixed ns excludes record verification and builds.\n"
                  "Idle CPU is whole process during quiet interval, "
                  "not per-worker energy use. Wake percentiles use per-run "
                  "nearest rank, not a long-term tail SLA.\n"
                  "Throughput ratios use exact same-round pairs. "
                  "One-worker control ratios are diagnostic only; "
                  "do not replace absolute changes or infer causality.\n"
                  "CPU clock snapshots are instantaneous multi-CPU "
                  "medians, not measured workload frequency; no governor "
                  "or thermal policy is changed. RUSAGE_CHILDREN ru_maxrss "
                  "is cumulative across children.\n")
        for cmd in (["git", "status", "--short", "--branch"],
                    [a.compiler, "--version"], ["dub", "--version"],
                    ["lscpu"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            out.write("$ " + " ".join(cmd) + "\n")
            try:
                out.write(command(list(cmd), root) + "\n")
            except (OSError, RuntimeError):
                out.write("unavailable\n")
    print("M0 HEAD pinned before/after: correctness and diagnostics only.")
    print("evidence:", output)


if __name__ == "__main__":
    main()
