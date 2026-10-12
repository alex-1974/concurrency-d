#!/usr/bin/env python3
"""R0.5 recycle spare-lookup diagnosis: opt-in vs uninstrumented controls.

Both binaries use the same post-PR37 full-N-slot victim scan, the same
borrowed/owned task semantics and GC vs typed-recycler policy. The opt-in
binary counts casts and times the whole spare scan. Admission profiling
runs only in that binary. No benchmark compares instrumented throughput
to uninstrumented throughput as though it were a scheduler optimization.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from r05_admission_matrix import ADMISSION, METRICS

CONFIGS = {
    "off": ("task-pipeline-mixed-full-victim-sweep",
            "concurrency-task-pipeline-mixed-full-victim-sweep"),
    "on": ("task-pipeline-mixed-full-victim-lookup-probe",
           "concurrency-task-pipeline-mixed-full-victim-lookup-probe"),
}
LOOKUP = ("metric", "policy", "workers", "producers", "budget", "tasks",
          "searches", "empty_searches", "attempted_casts", "hits",
          "misses", "hit_index_sum", "max_hit_index", "max_candidates",
          "lookup_ns", "max_lookup_ns")


def invoke(argv, cwd, timeout=180):
    return subprocess.run(argv, cwd=cwd, text=True, capture_output=True,
                          check=True, timeout=timeout).stdout.strip()


def build(root, compiler):
    binaries = {}
    for mode, (config, name) in CONFIGS.items():
        invoke(["dub", "build", "--config=" + config, "--build=release",
                "--compiler=" + compiler, "--force"], root)
        binary = root / name
        if not binary.is_file():
            raise RuntimeError("missing binary " + str(binary))
        binaries[mode] = binary
    return binaries


def parse_record(output, marker, fields, required):
    lines = [line for line in output.splitlines()
             if line.startswith(marker + ",")]
    if len(lines) != (1 if required else 0):
        raise RuntimeError("unexpected " + marker + " rows:\n" + output[-4000:])
    if not required:
        return None
    parts = next(csv.reader(lines))
    if len(parts) != len(fields):
        raise RuntimeError("bad " + marker + " schema: " +
                           str(len(parts)) + " vs " + str(len(fields)))
    return dict(zip(fields, parts))


def run_one(binary, root, round_id, mode, workers, producers,
            tasks, budget, policy, counter, workload):
    # The same input task sequence and counter layout for both policies.
    args = [str(binary), str(workers), str(producers), str(tasks),
            str(budget), policy, counter,
            "on" if mode == "on" else "off", workload, "off", "always"]
    with tempfile.TemporaryFile(mode="w+t") as file:
        child = subprocess.Popen(args, cwd=root, stdout=file,
                                 stderr=subprocess.STDOUT, text=True)
        _, status, resource = os.wait4(child.pid, 0)
        file.seek(0)
        output = file.read()
    if os.waitstatus_to_exitcode(status):
        raise RuntimeError("benchmark failed: " + repr(args) + "\n" +
                           output[-6000:])
    perf = parse_record(output, "multi", METRICS, True)
    admission = parse_record(output, "admission", ADMISSION, mode == "on")
    lookup = parse_record(output, "lookup", LOOKUP, mode == "on")
    if (perf["policy"] != policy or perf["scenario"] != "mixed" or
            int(perf["workers"]) != workers or
            int(perf["producers"]) != producers or
            int(perf["budget"]) != budget or
            int(perf["tasks"]) != tasks or
            int(perf["completed"]) != tasks or
            int(perf["fresh_nodes"]) + int(perf["reused_nodes"]) != tasks):
        raise RuntimeError("mixed input/result accounting mismatch")
    row = dict(round=round_id, profile=mode, policy=policy,
               workers=workers, producers=producers, budget=budget,
               tasks=tasks, counter_mode=counter, workload=workload,
               throughput_per_s=float(perf["throughput_per_s"]),
               elapsed_ms=float(perf["elapsed_ms"]),
               fresh_nodes=int(perf["fresh_nodes"]),
               reused_nodes=int(perf["reused_nodes"]),
               producer_gc_bytes=int(perf["producer_gc_bytes"]),
               peak_rss_kib=resource.ru_maxrss,
               observed_handles=int(perf["observed_handles"]))
    if mode == "on":
        if (admission["policy"] != policy or lookup["policy"] != policy or
                int(admission["workers"]) != workers or
                int(lookup["workers"]) != workers or
                int(admission["tasks"]) != tasks or
                int(lookup["tasks"]) != tasks):
            raise RuntimeError("profile metadata mismatch")
        for name in ("attempts", "accepted", "retention_full", "ingress_full",
                     "yields", "wait_ns", "hold_ns", "max_wait_ns",
                     "max_hold_ns", "wait_p95_upper_ns", "hold_p95_upper_ns"):
            row[name] = int(admission[name])
        for name in LOOKUP[6:]:
            row[name] = int(lookup[name])
        if (row["accepted"] != tasks or
                row["attempts"] != tasks + row["retention_full"] +
                row["ingress_full"] or
                row["yields"] != row["retention_full"] + row["ingress_full"]):
            raise RuntimeError("admission instrumentation accounting mismatch")
        if policy == "gc":
            if any(row[name] != 0 for name in LOOKUP[6:]):
                raise RuntimeError("fresh-GC executed recycle lookup")
        elif (row["searches"] != tasks or
              row["hits"] != row["reused_nodes"] or
              row["hits"] + row["misses"] != tasks or
              row["attempted_casts"] < row["hits"] or
              row["attempted_casts"] > row["searches"] * budget or
              row["max_candidates"] > budget or
              row["empty_searches"] > row["misses"]):
            raise RuntimeError("recycler lookup counters inconsistent")
        row["mean_casts_per_search"] = (
            row["attempted_casts"] / row["searches"]
            if row["searches"] else 0)
        row["mean_lookup_ns"] = (
            row["lookup_ns"] / row["searches"]
            if row["searches"] else 0)
        row["lookup_over_hold_diagnostic"] = (
            row["lookup_ns"] / row["hold_ns"]
            if row["hold_ns"] else 0)
    return row


def save(path, rows):
    if not rows:
        raise RuntimeError("empty evidence " + str(path))
    with path.open("w", newline="") as output:
        w = csv.DictWriter(output, fieldnames=list(rows[0].keys()),
                           extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--tasks", type=int, default=30000)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--producers", nargs="+", type=int, default=[1, 4, 8])
    p.add_argument("--budgets", nargs="+", type=int, default=[8, 512])
    p.add_argument("--counter-mode", choices=["shared", "striped"],
                   default="shared")
    p.add_argument("--workload", choices=["minimal", "compute"],
                   default="minimal")
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-lookup"))
    a = p.parse_args()
    if (platform.system() != "Linux" or
        not 1 <= a.rounds <= 20 or not 1 <= a.workers <= 64 or
        not 1 <= a.tasks <= 2_000_000 or
        not a.producers or not a.budgets or
        len(set(a.producers)) != len(a.producers) or
        len(set(a.budgets)) != len(a.budgets) or
        any(x not in (1, 4, 8) for x in a.producers) or
        any(x not in (8, 64, 512, 4096) for x in a.budgets)):
        p.error("invalid bounded lookup experiment parameters")

    root = Path(__file__).resolve().parents[2]
    binaries = build(root, a.compiler)
    a.output.mkdir(parents=True, exist_ok=True)
    allrows = []
    # Alternate policy AND profile execution order between rounds,
    # to avoid always benchmarking the instrumented candidate after the
    # same variant. Each case is a fresh child process.
    for rnd in range(a.rounds):
        for producers in a.producers:
            for budget in a.budgets:
                modes = ("off", "on") if (rnd + producers) % 2 == 0 else (
                    "on", "off")
                for mode in modes:
                    policies = ("gc", "recycle") if (rnd + budget +
                                (mode == "on")) % 2 == 0 else ("recycle", "gc")
                    for policy in policies:
                        row = run_one(
                            binaries[mode], root, rnd, mode, a.workers,
                            producers, a.tasks, budget, policy,
                            a.counter_mode, a.workload)
                        allrows.append(row)
                        message = ("lookup casts/search=" +
                                   str(round(row["mean_casts_per_search"], 3))
                                   if mode == "on" and policy == "recycle"
                                   else "")
                        print(f"R05 lookup round={rnd} producers={producers} "
                              f"budget={budget} mode={mode} policy={policy} "
                              f"rate={row['throughput_per_s']:.0f} "
                              + message, flush=True)

    # Normalize rows: instrumented-only fields are blank in 'off' rows.
    columns = list(dict.fromkeys(key for r in allrows for key in r))
    with (a.output / "raw.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=columns)
        writer.writeheader()
        writer.writerows(allrows)
    cases = {(r["round"], r["producers"], r["budget"],
              r["profile"], r["policy"]): r for r in allrows}
    if len(cases) != len(allrows):
        raise RuntimeError("duplicate case key")
    pairs = []
    diagnostics = []
    for rnd in range(a.rounds):
        for producers in a.producers:
            for budget in a.budgets:
                for mode in CONFIGS:
                    gc = cases[(rnd, producers, budget, mode, "gc")]
                    rec = cases[(rnd, producers, budget, mode, "recycle")]
                    pairs.append(dict(
                        round=rnd, producers=producers, budget=budget,
                        profile=mode, recycle_over_gc=(
                            rec["throughput_per_s"] / gc["throughput_per_s"]),
                        gc_throughput=gc["throughput_per_s"],
                        recycle_throughput=rec["throughput_per_s"]))
                    if mode == "on":
                        diagnostics.append(dict(
                            round=rnd, producers=producers, budget=budget,
                            casts_per_search=rec["mean_casts_per_search"],
                            hit_rate=rec["hits"] / rec["searches"],
                            empty_rate=rec["empty_searches"] / rec["searches"],
                            mean_hit_index=(
                                rec["hit_index_sum"] / rec["hits"]
                                if rec["hits"] else 0),
                            lookup_ns_per_search=rec["mean_lookup_ns"],
                            lookup_over_admission_hold=(
                                rec["lookup_over_hold_diagnostic"]),
                            hold_ns_per_attempt=(
                                rec["hold_ns"] / rec["attempts"]),
                            wait_ns_per_attempt=(
                                rec["wait_ns"] / rec["attempts"]),
                            admission_retries_per_task=rec["yields"] / a.tasks))
    save(a.output / "pairs.csv", pairs)
    save(a.output / "diagnostics.csv", diagnostics)
    summary = []
    for producers in a.producers:
        for budget in a.budgets:
            for mode in CONFIGS:
                group = [r for r in pairs if r["producers"] == producers
                         and r["budget"] == budget and r["profile"] == mode]
                ratios = [r["recycle_over_gc"] for r in group]
                summary.append(dict(
                    producers=producers, budget=budget, profile=mode,
                    rounds=len(group), median_recycle_over_gc=statistics.median(ratios),
                    recycle_wins=sum(v > 1 for v in ratios)))
    save(a.output / "summary.csv", summary)
    with (a.output / "environment.txt").open("w") as out:
        out.write(f"research_head={invoke(['git','rev-parse','HEAD'],root)}\n")
        out.write("victim_sweep=full (both binaries)\n")
        out.write(f"compiler={a.compiler}\n")
        for cmd in ([a.compiler, "--version"], ["dub", "--version"],
                    ["lscpu"], ["git", "status", "--short", "--untracked-files=no"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            out.write("$ " + " ".join(cmd) + "\n")
            try:
                out.write(invoke(list(cmd), root) + "\n")
            except (OSError, subprocess.CalledProcessError):
                out.write("unavailable\n")
        out.write(f"platform={platform.platform()}\n"
                  f"workers={a.workers} producers={a.producers} budgets={a.budgets}\n"
                  f"tasks={a.tasks} rounds={a.rounds} workload={a.workload}\n"
                  f"counter_mode={a.counter_mode}\n"
                  "off=unprofiled full-victim; on=lookup timing plus admission "
                  "histograms, compiler-specialized version.\n"
                  "Lookup time covers the scan/rearm path, including timing "
                  "overhead, and is not pure RTTI cast time.\n"
                  "Comparing on/off throughput measures perturbation only, "
                  "not a consumer speedup or calibrated profiler correction.\n")
    print("R05 LOOKUP research diagnostics; no production change.")
    print("evidence:", a.output)


if __name__ == "__main__":
    main()
