#!/usr/bin/env python3
"""R0.5 full-victim CPU/scheduling qualification without executor probes.

Run fresh Linux child processes with unchanged, uninstrumented release
consumer. wait4() is always collected per child. Optional perf stat
runs are separate diagnostic samples, never pooled with plain throughput.
No sudo, sysctl changes, CPU affinity, modified notifications or GC semantics.
"""
import argparse
import csv
import hashlib
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile
import time

PERF_EVENTS = (
    "task-clock", "context-switches", "cpu-migrations", "page-faults",
    "cycles", "instructions",
)
FIELDS = (
    "metric", "scenario", "policy", "workers", "producers", "budget",
    "tasks", "elapsed_ms", "throughput_per_s", "fresh_nodes",
    "reused_nodes", "producer_gc_bytes", "used_close_delta",
    "used_after_collect_delta", "observed_handles", "completed",
)
RESOURCE = (
    "metric", "policy", "counter_mode", "workers", "producers", "budget", "tasks",
    "producer_user_us", "producer_system_us", "producer_voluntary",
    "producer_involuntary", "producer_minor_faults", "producer_major_faults",
)
BUILD_CONFIG = "task-pipeline-mixed-full-victim-sweep"
BINARY = "concurrency-task-pipeline-mixed-full-victim-sweep"


def command_output(args, root, allow_failure=False):
    result = subprocess.run(args, cwd=root, text=True,
                            capture_output=True, timeout=180)
    if result.returncode != 0 and not allow_failure:
        raise RuntimeError("command failed: " + repr(args) + "\n" +
                           result.stderr[-4000:])
    return result


def build(root, compiler):
    command_output(["dub", "build", "--config=" + BUILD_CONFIG,
                    "--build=release", "--compiler=" + compiler,
                    "--force"], root)
    binary = root / BINARY
    if not binary.is_file():
        raise RuntimeError("DUB did not create " + str(binary))
    return binary


def parse_line(output, marker, fields):
    matching = [line for line in output.splitlines()
                if line.startswith(marker)]
    if len(matching) != 1:
        raise RuntimeError("expected one " + marker + " output row: " +
                           output[-4500:])
    values = next(csv.reader(matching))
    if len(values) != len(fields):
        raise RuntimeError("unexpected metric width for " + marker +
                           f": {len(values)} != {len(fields)}")
    return dict(zip(fields, values))


def run_child(root, binary, round_no, producers, budget, policy, workload,
              workers, tasks, counter, perf_output=None):
    # Fully explicit arguments prohibit accidentally enabling the
    # AdmissionProbe, worker-parking profile or a changed notify policy.
    consumer = [str(binary), str(workers), str(producers), str(tasks),
                str(budget), policy, counter, "off", workload, "off",
                "always"]
    mode = "plain"
    if perf_output is None:
        command = consumer
    else:
        mode = "perf"
        command = [
            "perf", "stat", "-x,", "--no-big-num",
            "--output", str(perf_output),
            "-e", ",".join(PERF_EVENTS), "--",
        ] + consumer

    started = time.monotonic_ns()
    with tempfile.TemporaryFile(mode="w+t") as log:
        proc = subprocess.Popen(command, cwd=root, stdout=log,
                                stderr=subprocess.STDOUT, text=True)
        _, status, usage = os.wait4(proc.pid, 0)
        wall_ns = time.monotonic_ns() - started
        log.seek(0)
        output = log.read()
    code = os.waitstatus_to_exitcode(status)
    if code != 0:
        raise RuntimeError(f"{mode} workload={workload} producers={producers}"
                           f" policy={policy} round={round_no} failed"
                           f" (exit {code}):\n{output[-5500:]}")

    result = parse_line(output, "multi,mixed,", FIELDS)
    producer = parse_line(output, "resource,", RESOURCE)
    other = parse_line(output, "workload,", (
        "metric", "workload", "compute_rounds", "checksum"))
    if (result["policy"] != policy or
            int(result["tasks"]) != tasks or
            int(result["completed"]) != tasks or
            int(result["workers"]) != workers or
            int(result["producers"]) != producers or
            int(result["budget"]) != budget or
            int(result["fresh_nodes"]) +
            int(result["reused_nodes"]) != tasks or
            result["scenario"] != "mixed" or
            float(result["throughput_per_s"]) <= 0 or
            other["workload"] != workload or
            int(other["compute_rounds"]) !=
            (1024 if workload == "compute" else 0) or
            producer["policy"] != policy or
            producer["counter_mode"] != counter or
            producer["workers"] != str(workers) or
            producer["producers"] != str(producers)):
        raise RuntimeError("consumer work/ownership/checksum metadata mismatch")
    row = dict(
        round=round_no, profile_mode=mode, workers=workers,
        producers=producers, budget=budget, policy=policy,
        workload=workload, counter=counter, tasks=tasks,
        throughput_per_s=float(result["throughput_per_s"]),
        timed_elapsed_ms=float(result["elapsed_ms"]),
        external_wall_ms=wall_ns / 1_000_000,
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
        producer_minor_faults=int(producer["producer_minor_faults"]),
        producer_gc_bytes=int(result["producer_gc_bytes"]),
        observed_handles=int(result["observed_handles"]),
        fresh_nodes=int(result["fresh_nodes"]),
        reused_nodes=int(result["reused_nodes"]),
        completed=int(result["completed"]),
        checksum=other["checksum"],
    )
    row["child_cpu_over_external_wall"] = (
        (row["child_user_us"] + row["child_system_us"]) * 1000 /
        wall_ns)
    return row


def write_csv(path, rows):
    if not rows:
        raise RuntimeError("empty CSV " + str(path))
    with path.open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=tuple(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def perf_preflight(root):
    if shutil.which("perf") is None:
        return False, "perf executable missing"
    try:
        trial = subprocess.run(
            ["perf", "stat", "-x,", "-e", ",".join(PERF_EVENTS),
             "--", "/bin/true"], cwd=root, text=True,
            capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as failure:
        return False, f"perf preflight exception: {failure}"
    if trial.returncode:
        return False, ("perf stat preflight refused/unsupported: " +
                       trial.stderr[-2000:].replace("\n", " "))
    return True, "perf stat preflight passed (not a performance result)"


def parse_perf(path):
    # Preserve the raw perf -x output as the primary evidence; parsed
    # values are optional since event names/permissions differ by host.
    parsed = {name: "" for name in PERF_EVENTS}
    raw = path.read_text(errors="replace")
    for line in raw.splitlines():
        if not line or line.startswith("#"):
            continue
        values = next(csv.reader([line]))
        if len(values) < 3:
            continue
        value, event = values[0].strip(), values[2].strip()
        if event in parsed and value and not value.startswith("<"):
            try:
                parsed[event] = float(value)
            except ValueError:
                pass
    return parsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="ldc2")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--tasks", type=int, default=30000)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--producers", nargs="+", type=int,
                        default=[1, 4, 8])
    parser.add_argument("--budgets", nargs="+", type=int, default=[512])
    parser.add_argument("--policies", nargs="+", choices=["gc", "recycle"],
                        default=["gc", "recycle"])
    parser.add_argument("--workloads", nargs="+",
                        choices=["minimal", "compute"],
                        default=["minimal", "compute"])
    parser.add_argument("--counter", choices=["shared", "striped"],
                        default="shared")
    parser.add_argument("--perf-stat", choices=["off", "try", "require"],
                        default="try")
    parser.add_argument("--perf-repeats", type=int, default=2)
    parser.add_argument("--perf-producers", nargs="+", type=int,
                        default=[4, 8])
    parser.add_argument("--output", type=Path,
                        default=Path("evidence/r05-native-system"))
    a = parser.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= a.rounds <= 20 or
            not 1 <= a.tasks <= 2_000_000 or
            not 1 <= a.workers <= 64 or
            not a.producers or not a.budgets or
            not a.policies or not a.workloads or
            len(set(a.producers)) != len(a.producers) or
            len(set(a.budgets)) != len(a.budgets) or
            len(set(a.policies)) != len(a.policies) or
            len(set(a.workloads)) != len(a.workloads) or
            any(n < 1 or n > 64 for n in a.producers) or
            any(n not in (8, 64, 512, 4096) for n in a.budgets) or
            not 0 <= a.perf_repeats <= 10 or
            (a.perf_stat != "off" and a.perf_repeats > 0 and
             any(n not in a.producers for n in a.perf_producers))):
        parser.error("invalid bounded study configuration")
    root = Path(__file__).resolve().parents[2]
    binary = build(root, a.compiler)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    a.output.mkdir(parents=True, exist_ok=True)

    rows = []
    for rnd in range(a.rounds):
        for workload in a.workloads:
            for producers in a.producers:
                for budget in a.budgets:
                    policies = (list(a.policies) if (rnd + producers) % 2
                                else list(reversed(a.policies)))
                    for policy in policies:
                        row = run_child(
                            root, binary, rnd, producers, budget, policy,
                            workload, a.workers, a.tasks, a.counter)
                        rows.append(row)
                        print("R05 system plain", rnd, workload, producers,
                              budget, policy, "rate",
                              round(row["throughput_per_s"]),
                              "child-switches",
                              row["child_voluntary_switches"],
                              row["child_involuntary_switches"], flush=True)
    write_csv(a.output / "raw.csv", rows)
    cases = {(r["round"], r["workload"], r["producers"], r["budget"],
              r["policy"]): r for r in rows}
    if len(cases) != len(rows):
        raise RuntimeError("duplicate process scenario")
    pairs, summary = [], []
    if set(a.policies) == {"gc", "recycle"}:
        for workload in a.workloads:
            for producers in a.producers:
                for budget in a.budgets:
                    group = []
                    for rnd in range(a.rounds):
                        gc = cases[(rnd, workload, producers, budget, "gc")]
                        re = cases[(rnd, workload, producers, budget, "recycle")]
                        ratio = re["throughput_per_s"] / gc["throughput_per_s"]
                        group.append(ratio)
                        pairs.append(dict(
                            round=rnd, workload=workload,
                            producers=producers, budget=budget,
                            recycle_over_gc=ratio,
                            gc_tasks_per_s=gc["throughput_per_s"],
                            recycle_tasks_per_s=re["throughput_per_s"],
                            gc_voluntary_switches=gc[
                                "child_voluntary_switches"],
                            recycle_voluntary_switches=re[
                                "child_voluntary_switches"],
                            gc_child_user_us=gc["child_user_us"],
                            recycle_child_user_us=re["child_user_us"]))
                    summary.append(dict(
                        workload=workload, producers=producers,
                        budget=budget, rounds=len(group),
                        paired_median_recycle_over_gc=statistics.median(group),
                        recycle_wins=sum(x > 1.0 for x in group)))
        write_csv(a.output / "pairs.csv", pairs)
        write_csv(a.output / "summary.csv", summary)

    perf_ok, perf_message = False, "perf disabled by user"
    if a.perf_stat != "off" and a.perf_repeats:
        perf_ok, perf_message = perf_preflight(root)
        if not perf_ok and a.perf_stat == "require":
            raise RuntimeError(perf_message +
                "; no privilege or system-setting changes are attempted")
    perf_rows = []
    if perf_ok:
        output_dir = a.output / "perf-raw"
        output_dir.mkdir(exist_ok=True)
        for rnd in range(a.perf_repeats):
            for workload in a.workloads:
                for producers in a.perf_producers:
                    for budget in a.budgets:
                        for policy in a.policies:
                            path = output_dir / (
                                f"r{rnd}-{workload}-p{producers}-"
                                f"b{budget}-{policy}.csv")
                            row = run_child(
                                root, binary, rnd, producers, budget, policy,
                                workload, a.workers, a.tasks, a.counter,
                                perf_output=path.resolve())
                            perf_row = dict(row)
                            perf_row.update({
                                "perf_raw_file": str(path.relative_to(a.output))
                            })
                            perf_row.update({
                                "perf_" + name.replace("-", "_"): value
                                for name, value in parse_perf(path).items()
                            })
                            perf_rows.append(perf_row)
        write_csv(a.output / "perf.csv", perf_rows)

    with (a.output / "environment.txt").open("w") as f:
        f.write("benchmark=r05-full-victim-uninstrumented-native-system\n")
        f.write("research_head=" + command_output(
            ["git", "rev-parse", "HEAD"], root).stdout.strip() + "\n")
        f.write("build_config=" + BUILD_CONFIG + "\n")
        f.write("compiled_versions=R05FullVictimSweep only\n")
        f.write("instrumentation=off; parking=off; notify=always\n")
        f.write("binary_sha256=" + digest + "\n")
        f.write(f"workers={a.workers} tasks={a.tasks} rounds={a.rounds}"
                f" producers={a.producers} budgets={a.budgets}"
                f" policies={a.policies} workloads={a.workloads}"
                f" counter={a.counter}\n")
        f.write(f"perf_mode={a.perf_stat}; perf_repeats={a.perf_repeats}"
                f"; perf_available={perf_ok}\n"
                f"perf_preflight={perf_message}\n")
        f.write("wait4() usage applies to each direct child process"
                " (for perf mode, perf wrapper and waited descendants).\n")
        f.write("perf stat is a SEPARATE measured mode; do not pool its"
                " throughput with plain pairs or subtract its overhead.\n")
        f.write("context switches do not identify owning thread or"
                " futex cause. perf events may be missing/not counted.\n")
        for cmd in ([a.compiler, "--version"], ["dub", "--version"],
                    ["lscpu"], ["git", "status", "--short",
                                "--untracked-files=no"],
                    ["cat", "/proc/sys/kernel/perf_event_paranoid"],
                    ["cat", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            f.write("$ " + " ".join(cmd) + "\n")
            result = command_output(list(cmd), root, allow_failure=True)
            f.write((result.stdout if result.returncode == 0 else
                     "unavailable: " + result.stderr[-450:]) + "\n")
        f.write("platform=" + platform.platform() + "\n")
    print("PASS: unchanged uninstrumented scheduler semantics; native"
          " evidence at", a.output, "perf:", perf_message)


if __name__ == "__main__":
    main()
