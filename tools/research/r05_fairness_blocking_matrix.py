#!/usr/bin/env python3
"""R0.5 research: paired fair scheduling / bounded semaphore blocking.

A fresh child process is used for each mode. Distribution is evidence,
not a requirement that workers execute equally many tasks.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


def run(exe, root, trial, notify, storage, workers, producers, tasks,
        blocked, siblings, round_id):
    command = [str(exe), trial, notify, storage, str(workers),
               str(producers if trial == "fair" else blocked),
               str(tasks if trial == "fair" else siblings)]
    with tempfile.TemporaryFile(mode="w+t") as tmp:
        process = subprocess.Popen(command, cwd=root, stdout=tmp,
                                   stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(process.pid, 0)
        tmp.seek(0)
        output = tmp.read()
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise RuntimeError(f"FAILED {command} code={exit_code}\n" +
                           output[-4000:])
    lines = [list(csv.reader([line]))[0] for line in output.splitlines()
             if line.startswith(("worker,", "fairness,", "blocking,"))]
    main = [x for x in lines if x[0] == (
        "fairness" if trial == "fair" else "blocking")]
    if len(main) != 1:
        raise RuntimeError("missing scenario result\n" + output[-4000:])
    row = {
        "round": round_id, "scenario": trial, "notification": notify,
        "storage": storage, "workers": workers,
        "producers": producers if trial == "fair" else "",
        "blocked": blocked if trial == "block" else "",
        "tasks": tasks if trial == "fair" else siblings,
        "process_voluntary": usage.ru_nvcsw,
        "process_involuntary": usage.ru_nivcsw,
        "process_user_us": round(usage.ru_utime * 1e6),
        "process_system_us": round(usage.ru_stime * 1e6),
        "maxrss_kib": usage.ru_maxrss,
        "active_workers": "", "max_worker_share": "",
        "jain_dispatch_index": "", "elapsed_ns": "",
        "progress_before_release": "", "completed": "",
    }
    fields = main[0]
    if trial == "fair":
        if len(fields) != 7:
            raise RuntimeError("unexpected fairness schema: " + str(fields))
        counts = [int(x[2]) for x in lines if x[0] == "worker"]
        if (len(counts) != workers or sum(counts) != tasks or
            int(fields[3]) != tasks or int(fields[4]) < 1):
            raise RuntimeError("per-worker fairness accounting failed")
        row["active_workers"] = sum(x > 0 for x in counts)
        row["max_worker_share"] = round(max(counts) / tasks, 6)
        # Jain's index = 1 for perfectly equal shares, 1/workers
        # for one exclusive worker. NO fixed fairness threshold.
        row["jain_dispatch_index"] = round(
            tasks ** 2 / (workers * sum(x*x for x in counts)), 6)
        row["elapsed_ns"] = fields[6]
    else:
        if len(fields) != 6:
            raise RuntimeError("unexpected blocking schema: " + str(fields))
        expected = int(blocked < workers)
        if (int(fields[4]) != expected or
            int(fields[5]) != blocked + siblings):
            raise RuntimeError("blocking progress/completion mismatch")
        row["progress_before_release"] = expected
        row["completed"] = fields[5]
    return row


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--producers", type=int, default=4)
    p.add_argument("--tasks", type=int, default=1024)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--siblings", type=int, default=32)
    p.add_argument("--policies", nargs="+", choices=["gc", "recycle"],
                   default=["gc", "recycle"])
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-fairness-blocking"))
    a = p.parse_args()
    if (platform.system() != "Linux" or
        not 1 <= a.workers <= 64 or not 1 <= a.producers <= 64 or
        not 1 <= a.tasks <= 20000 or not 1 <= a.rounds <= 20 or
        not 1 <= a.siblings <= 64):
        p.error("invalid or unsupported configuration")
    root = Path(__file__).resolve().parents[2]
    subprocess.run(["dub", "build", "--config=fairness-blocking-benchmark",
                    "--build=release", "--compiler=" + a.compiler,
                    "--force"], check=True, cwd=root)
    exe = root / "concurrency-fairness-blocking"
    if not exe.is_file():
        raise RuntimeError("fairness executable missing")
    a.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for rnd in range(a.rounds):
        order = ("always", "waiter") if rnd % 2 == 0 else (
            "waiter", "always")
        for policy in a.policies:
            for mode in order:
                for scenario, blocked, siblings in (
                    ("fair", 0, 0), ("block", 1, a.siblings),
                    ("block", a.workers, 1)):
                    row = run(exe, root, scenario, mode, policy,
                              a.workers, a.producers, a.tasks,
                              blocked, siblings, rnd)
                    rows.append(row)
                    print(f"R05 {scenario} policy={policy} notify={mode} "
                          f"round={rnd} active={row['active_workers']} "
                          f"Jain={row['jain_dispatch_index']} "
                          f"progress={row['progress_before_release']}",
                          flush=True)
    with (a.output / "raw.csv").open("w", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    summary = []
    for policy in a.policies:
        for mode in ("always", "waiter"):
            matches = [x for x in rows if x["scenario"] == "fair" and
                       x["storage"] == policy and x["notification"] == mode]
            summary.append({
                "policy": policy, "notification": mode,
                "rounds": a.rounds, "workers": a.workers,
                "tasks": a.tasks,
                "median_active_workers": statistics.median(
                    x["active_workers"] for x in matches),
                "median_max_worker_share": statistics.median(
                    x["max_worker_share"] for x in matches),
                "median_jain_index": statistics.median(
                    x["jain_dispatch_index"] for x in matches),
                "median_elapsed_ns": statistics.median(
                    int(x["elapsed_ns"]) for x in matches),
            })
    with (a.output / "summary.csv").open("w", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    with (a.output / "environment.txt").open("w") as fd:
        fd.write(f"compiler={a.compiler} platform={platform.platform()}\n"
                 f"workers={a.workers} producers={a.producers}\n"
                 f"tasks={a.tasks} siblings={a.siblings} rounds={a.rounds}\n"
                 f"policies={a.policies}\n")
        for cmd in (["git", "rev-parse", "HEAD"],
                    [a.compiler, "--version"], ["lscpu"]):
            try:
                fd.write("$ " + " ".join(cmd) + "\n")
                fd.write(subprocess.run(cmd, check=True, capture_output=True,
                                        text=True, cwd=root).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")
    print("R05 fairness/blocking: correctness and dispatch distribution")
    print("evidence: " + str(a.output))


if __name__ == "__main__":
    main()
