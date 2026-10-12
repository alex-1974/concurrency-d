#!/usr/bin/env python3
"""Paired R0.5 admission-stage research after the full-victim M0 fix.

No production optimization is applied. Both binaries use the exact same
task input/GC contracts and full N-slot foreign victim search. The off
binary is not instrumented; the on binary adds per-producer admission
timers and four stage sums; on-vs-off throughput is a probe perturbation
diagnostic, NOT a corrected estimate of profiler-free stage costs.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from r05_admission_matrix import METRICS, ADMISSION

CONFIGS = {
    "off": ("task-pipeline-mixed-full-victim-sweep",
            "concurrency-task-pipeline-mixed-full-victim-sweep"),
    "on": ("task-pipeline-mixed-full-victim-admission-stages",
           "concurrency-task-pipeline-mixed-full-victim-admission-stages"),
}
STAGE = (
    "metric", "policy", "counter_mode", "producers", "workers", "budget",
    "tasks", "gate_count", "gate_ns", "cell_count", "cell_ns",
    "node_count", "node_ns", "publish_count", "publish_ns",
    "root_append_count", "root_append_ns",
    "inbox_submit_count", "inbox_submit_ns",
)


def call(args, root, timeout=200):
    return subprocess.run(args, cwd=root, text=True, capture_output=True,
                          check=True, timeout=timeout).stdout.strip()


def build(root, compiler):
    binaries = {}
    for mode, (config, name) in CONFIGS.items():
        call(["dub", "build", "--config=" + config, "--build=release",
              "--compiler=" + compiler, "--force"], root)
        target = root / name
        if not target.is_file():
            raise RuntimeError("missing benchmark binary: " + str(target))
        binaries[mode] = target
    return binaries


def one(content, marker, fields, required):
    lines = [line for line in content.splitlines()
             if line.startswith(marker + ",")]
    if len(lines) != (1 if required else 0):
        raise RuntimeError("unexpected " + marker + " rows: " +
                           repr(lines[:5]))
    if not required:
        return None
    values = next(csv.reader(lines))
    if len(values) != len(fields):
        raise RuntimeError(marker + " schema mismatch: " +
                           str(len(values)) + " vs " + str(len(fields)))
    return dict(zip(fields, values))


def measure(binary, root, round_id, mode, policy,
            workers, producers, budget, tasks, workload, counter):
    args = [str(binary), str(workers), str(producers), str(tasks),
            str(budget), policy, counter,
            "on" if mode == "on" else "off", workload, "off", "always"]
    with tempfile.TemporaryFile(mode="w+t") as capture:
        child = subprocess.Popen(args, cwd=root, stdout=capture,
                                 stderr=subprocess.STDOUT, text=True)
        _, status, usage = os.wait4(child.pid, 0)
        capture.seek(0)
        output = capture.read()
    if os.waitstatus_to_exitcode(status):
        raise RuntimeError("benchmark failed: " + repr(args) + "\n" +
                           output[-8000:])

    perf = one(output, "multi", METRICS, True)
    adm = one(output, "admission", ADMISSION, mode == "on")
    stage = one(output, "stage", STAGE, mode == "on")
    if (perf["scenario"] != "mixed" or perf["policy"] != policy or
            int(perf["workers"]) != workers or
            int(perf["producers"]) != producers or
            int(perf["budget"]) != budget or
            int(perf["tasks"]) != tasks or
            int(perf["completed"]) != tasks or
            int(perf["fresh_nodes"]) + int(perf["reused_nodes"]) != tasks or
            float(perf["throughput_per_s"]) <= 0):
        raise RuntimeError("wrong task/result accounting")

    row = dict(round=round_id, profile=mode, policy=policy,
               producers=producers, workers=workers, budget=budget,
               tasks=tasks, workload=workload, counter=counter,
               elapsed_ms=float(perf["elapsed_ms"]),
               throughput_per_s=float(perf["throughput_per_s"]),
               fresh_nodes=int(perf["fresh_nodes"]),
               reused_nodes=int(perf["reused_nodes"]),
               producer_gc_bytes=int(perf["producer_gc_bytes"]),
               peak_rss_kib=usage.ru_maxrss,
               observed_handles=int(perf["observed_handles"]))
    if mode == "on":
        for name in ("attempts", "accepted", "retention_full", "ingress_full",
                     "yields", "wait_ns", "hold_ns", "max_wait_ns",
                     "max_hold_ns", "wait_p95_upper_ns", "hold_p95_upper_ns"):
            row[name] = int(adm[name])
        for name in STAGE[7:]:
            row[name] = int(stage[name])
        if (adm["policy"] != policy or stage["policy"] != policy or
                adm["counter_mode"] != counter or
                stage["counter_mode"] != counter or
                int(adm["workers"]) != workers or
                int(stage["workers"]) != workers or
                int(adm["tasks"]) != tasks or
                int(stage["tasks"]) != tasks or
                int(adm["producers"]) != producers or
                int(stage["producers"]) != producers or
                int(adm["budget"]) != budget or
                int(stage["budget"]) != budget):
            raise RuntimeError("profile metadata mismatch")
        if (row["accepted"] != tasks or
                row["attempts"] != tasks + row["retention_full"] +
                row["ingress_full"] or
                row["yields"] != row["retention_full"] +
                row["ingress_full"] or
                row["gate_count"] != row["attempts"] or
                any(row[k] != tasks for k in (
                    "cell_count", "node_count", "publish_count",
                    "root_append_count", "inbox_submit_count")) or
                row["root_append_ns"] > row["publish_ns"] or
                row["inbox_submit_ns"] > row["publish_ns"]):
            raise RuntimeError("profile stage attempt and rejection mismatch")
        for stage_name in ("gate", "cell", "node", "publish",
                           "root_append", "inbox_submit"):
            count = row[stage_name + "_count"]
            row[stage_name + "_ns_per_event"] = (
                row[stage_name + "_ns"] / count if count else 0.0)
        stage_sum = sum(row[name + "_ns"] for name in
                        ("gate", "cell", "node", "publish"))
        row["stage_sum_over_hold_diagnostic"] = (
            stage_sum / row["hold_ns"] if row["hold_ns"] else 0.0)
        # Aggregate publish bracket contains both substages plus all
        # intervening measurement overhead. It is NOT an additive
        # uninstrumented time decomposition.
        row["root_over_publish_diagnostic"] = (
            row["root_append_ns"] / row["publish_ns"]
            if row["publish_ns"] else 0.0)
        row["inbox_over_publish_diagnostic"] = (
            row["inbox_submit_ns"] / row["publish_ns"]
            if row["publish_ns"] else 0.0)
        row["wait_ns_per_attempt"] = (
            row["wait_ns"] / row["attempts"] if row["attempts"] else 0.0)
        row["hold_ns_per_attempt"] = (
            row["hold_ns"] / row["attempts"] if row["attempts"] else 0.0)
        row["retries_per_task"] = row["yields"] / tasks
    return row


def csv_write(path, rows):
    if not rows:
        raise RuntimeError("no rows for " + str(path))
    columns = list(dict.fromkeys(k for row in rows for k in row))
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--tasks", type=int, default=30000)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--producers", type=int, nargs="+", default=[1, 4, 8])
    p.add_argument("--budgets", type=int, nargs="+", default=[8, 512])
    p.add_argument("--workload", choices=["minimal", "compute"],
                   default="minimal")
    p.add_argument("--counter", choices=["shared", "striped"],
                   default="shared")
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-admission-stages"))
    a = p.parse_args()
    if (platform.system() != "Linux" or not 1 <= a.workers <= 64 or
            not 1 <= a.tasks <= 2_000_000 or
            not 1 <= a.rounds <= 20 or
            not a.producers or not a.budgets or
            len(set(a.producers)) != len(a.producers) or
            len(set(a.budgets)) != len(a.budgets) or
            any(x < 1 or x > 64 for x in a.producers) or
            any(x not in (8, 64, 512, 4096) for x in a.budgets)):
        p.error("invalid experiment parameters")
    root = Path(__file__).resolve().parents[2]
    binary = build(root, a.compiler)
    a.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for rnd in range(a.rounds):
        for prod in a.producers:
            for budget in a.budgets:
                modes = ("off", "on") if (rnd + prod) % 2 else ("on", "off")
                for mode in modes:
                    policies = ("gc", "recycle") if (rnd + budget +
                                (mode == "on")) % 2 == 0 else ("recycle", "gc")
                    for policy in policies:
                        row = measure(binary[mode], root, rnd, mode, policy,
                                      a.workers, prod, budget, a.tasks,
                                      a.workload, a.counter)
                        rows.append(row)
                        print(f"R05 stages round={rnd} producers={prod} "
                              f"budget={budget} profile={mode} policy={policy} "
                              f"throughput={row['throughput_per_s']:.0f}", flush=True)
    expected = a.rounds * len(a.producers) * len(a.budgets) * 4
    if len(rows) != expected:
        raise RuntimeError("incomplete matrix")
    keys = {(r["round"], r["producers"], r["budget"],
             r["profile"], r["policy"]): r for r in rows}
    if len(keys) != expected:
        raise RuntimeError("duplicate scenario key")
    csv_write(a.output / "raw.csv", rows)
    pairs = []
    diagnostic = []
    for rnd in range(a.rounds):
        for prod in a.producers:
            for budget in a.budgets:
                for mode in CONFIGS:
                    gc = keys[(rnd, prod, budget, mode, "gc")]
                    recycled = keys[(rnd, prod, budget, mode, "recycle")]
                    pairs.append(dict(
                        round=rnd, producers=prod, budget=budget,
                        profile=mode,
                        recycle_over_gc=recycled["throughput_per_s"] /
                                        gc["throughput_per_s"],
                        gc_tasks_per_s=gc["throughput_per_s"],
                        recycle_tasks_per_s=recycled["throughput_per_s"]))
                    if mode == "on":
                        for case in (gc, recycled):
                            diagnostic.append(dict(
                                round=rnd, producers=prod, budget=budget,
                                policy=case["policy"],
                                gate_ns_per_attempt=case["gate_ns_per_event"],
                                cell_ns_per_admission=case["cell_ns_per_event"],
                                node_ns_per_admission=case["node_ns_per_event"],
                                publish_ns_per_admission=case["publish_ns_per_event"],
                                root_append_ns_per_admission=case[
                                    "root_append_ns_per_event"],
                                inbox_submit_ns_per_admission=case[
                                    "inbox_submit_ns_per_event"],
                                root_over_publish_diagnostic=case[
                                    "root_over_publish_diagnostic"],
                                inbox_over_publish_diagnostic=case[
                                    "inbox_over_publish_diagnostic"],
                                wait_ns_per_attempt=case["wait_ns_per_attempt"],
                                hold_ns_per_attempt=case["hold_ns_per_attempt"],
                                retries_per_task=case["retries_per_task"],
                                summed_stages_over_hold=case[
                                    "stage_sum_over_hold_diagnostic"]))
    csv_write(a.output / "pairs.csv", pairs)
    csv_write(a.output / "diagnostics.csv", diagnostic)
    summary = []
    for prod in a.producers:
        for budget in a.budgets:
            for mode in CONFIGS:
                group = [r["recycle_over_gc"] for r in pairs
                         if r["producers"] == prod and
                         r["budget"] == budget and r["profile"] == mode]
                if len(group) != a.rounds:
                    raise RuntimeError("incomplete paired rounds")
                summary.append(dict(producers=prod, budget=budget,
                    profile=mode, rounds=a.rounds,
                    median_recycle_over_gc=statistics.median(group),
                    recycle_wins=sum(x > 1 for x in group)))
    csv_write(a.output / "summary.csv", summary)
    with (a.output / "environment.txt").open("w") as stream:
        stream.write("benchmark=full-victim-admission-stage-research\n")
        stream.write("head=" + call(["git", "rev-parse", "HEAD"], root) + "\n")
        stream.write(f"compiler={a.compiler}\n")
        stream.write(f"workers={a.workers} producers={a.producers} budgets="
                     f"{a.budgets} tasks={a.tasks} rounds={a.rounds}\n")
        stream.write(f"workload={a.workload} counter={a.counter}\n")
        for cmd in ([a.compiler, "--version"], ["dub", "--version"],
                    ["lscpu"], ["git", "status", "--short",
                                "--untracked-files=no"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            stream.write("$ " + " ".join(cmd) + "\n")
            try:
                stream.write(call(list(cmd), root) + "\n")
            except (OSError, subprocess.CalledProcessError,
                    subprocess.TimeoutExpired):
                stream.write("unavailable\n")
        stream.write("platform=" + platform.platform() + "\n")
        stream.write("Timing is opt-in; all stages include clock/probe overhead.\n"
                     "publish includes GC-root append + nested inbox submit; "
                     "the two substage clocks and counters perturb publish.\n"
                     "inbox_submit includes inner inbox mutex, enqueue and "
                     "possible Condition.notify; cannot attribute it further.\n"
                     "gate counts rejections; cell/node/publish count admission"
                     " attempts only. Lock wait includes OS scheduling.\n"
                     "Stage-sum / hold is diagnostic, not causal. "
                     "R0.5 OwnedTask differs from M0 despite same victim scan.\n")
    print("R05 stage profiling complete; native timings required for decisions.")
    print("evidence:", a.output)


if __name__ == "__main__":
    main()
