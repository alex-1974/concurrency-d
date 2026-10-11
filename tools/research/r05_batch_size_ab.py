#!/usr/bin/env python3
"""R0.5 untraced ingress-batch A/B: 1 versus unchanged default 8.

Paired fresh-process bursts report actual callable starts and gate release;
mixed-producer runs report internal end-to-end throughput. Every run performs
the benchmark's typed-result and exactly-once checks. No trace mutex is used.
This is research evidence, NOT a production default/promotion gate.
"""
import argparse
import csv
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import time


BURST = ("metric", "notify", "storage", "workers", "blockers", "siblings",
         "probe_ms", "started_before_release", "siblings_before_release",
         "distinct_workers", "claimed_tasks", "local_executions",
         "stolen_executions", "siblings_after_all_starts")
CLAIM = ("metric", "worker", "ingress_batches", "claimed_tasks",
         "local_executions", "direct_executions", "stolen_executions",
         "executions")
TASK = ("metric", "task", "started_before_release", "worker",
        "start_delay_ns")
MULTI = ("metric", "scenario", "policy", "workers", "producers", "budget",
         "tasks", "elapsed_ms", "throughput_per_s", "fresh_nodes",
         "reused_nodes", "producer_gc_bytes", "used_close_delta",
         "used_after_collect_delta", "observed_handles", "completed")
BINS = {
    8: {
        "burst": ("burst-head-of-line-benchmark",
                  "concurrency-burst-head-of-line"),
        "mixed": ("task-pipeline-mixed-benchmark",
                  "concurrency-task-pipeline-mixed"),
    },
    1: {
        "burst": ("burst-head-of-line-batch1",
                  "concurrency-burst-head-of-line-batch1"),
        "mixed": ("task-pipeline-mixed-batch1",
                  "concurrency-task-pipeline-mixed-batch1"),
    },
}


def run_child(cmd, root):
    """Measure only a fresh binary's execution, never its DUB build."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter_ns()
    try:
        completed = subprocess.run(
            cmd, cwd=root, text=True, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired as err:
        raise RuntimeError(f"child watchdog expired: {cmd}") from err
    wall = time.perf_counter_ns() - t0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if completed.returncode:
        raise RuntimeError(f"child rc={completed.returncode}: {cmd}\n"
                           + (completed.stdout + completed.stderr)[-7000:])
    resources = {
        "child_wall_ns": wall,
        "child_cpu_user_us": round(
            (after.ru_utime - before.ru_utime) * 1_000_000),
        "child_cpu_system_us": round(
            (after.ru_stime - before.ru_stime) * 1_000_000),
        "child_voluntary_switches": after.ru_nvcsw - before.ru_nvcsw,
        "child_involuntary_switches": after.ru_nivcsw - before.ru_nivcsw,
    }
    return list(csv.reader(completed.stdout.splitlines())), resources


def one(rows, kind, schema):
    found = [r for r in rows if r and r[0] == kind]
    if len(found) != 1 or len(found[0]) != len(schema):
        raise RuntimeError(f"expected one {kind} row of {len(schema)} columns")
    return dict(zip(schema, found[0]))


def percentile(values, p):
    """Nearest-rank percentile; p99 of eight tasks is their maximum."""
    values = sorted(values)
    return values[max(0, (len(values) * p + 99) // 100 - 1)]


def burst_case(binary, root, batch, policy, notify, blockers, probe_ms):
    rows, cpu = run_child(
        [str(binary), notify, policy, "4", str(blockers), "8",
         str(probe_ms)], root)
    top = one(rows, "burst", BURST)
    expected = {"notify": notify, "storage": policy,
                "workers": "4", "blockers": str(blockers),
                "siblings": "8", "probe_ms": str(probe_ms),
                "claimed_tasks": str(blockers + 8)}
    for key, value in expected.items():
        if top[key] != value:
            raise RuntimeError(f"incorrect burst {key}: {top[key]}")
    claim_rows = [r for r in rows if r and r[0] == "claim"]
    blocker_rows = [r for r in rows if r and r[0] == "task"]
    sibling_rows = [r for r in rows if r and r[0] == "sibling"]
    controls = [r for r in rows if r and r[0] == "control"]
    if (len(claim_rows) != 4 or len(blocker_rows) != blockers or
            len(sibling_rows) != 8 or len(controls) != 2):
        raise RuntimeError("incomplete burst/worker/control record")
    claims = [dict(zip(CLAIM, r)) for r in claim_rows]
    if any(len(r) != len(CLAIM) for r in claim_rows):
        raise RuntimeError("invalid claim row")
    if sorted(int(r["worker"]) for r in claims) != list(range(4)):
        raise RuntimeError("missing worker identity")
    for name in ("claimed_tasks", "executions"):
        if sum(int(r[name]) for r in claims) != blockers + 8:
            raise RuntimeError(f"nonconserved {name}")
    if sum(int(r["stolen_executions"]) for r in claims) != int(
            top["stolen_executions"]):
        raise RuntimeError("nonconserved steal count")

    timeline = {}
    for row in controls:
        if len(row) != 3 or row[1] in timeline:
            raise RuntimeError("bad/duplicate control event")
        timeline[row[1]] = int(row[2])
    if set(timeline) != {"gateRelease", "joined"}:
        raise RuntimeError("missing gate release or join")
    gate = timeline["gateRelease"]
    if gate <= 0 or timeline["joined"] < gate:
        raise RuntimeError("invalid gate/join time")

    def parse_tasks(parts, expected_count):
        seen = set()
        tasks = []
        for row in parts:
            if len(row) != len(TASK):
                raise RuntimeError("invalid task row")
            info = dict(zip(TASK, row))
            task_id = int(info["task"])
            worker = int(info["worker"])
            delay = int(info["start_delay_ns"])
            if (task_id in seen or not 0 <= task_id < expected_count or
                    not 0 <= worker < 4 or delay < 0 or
                    int(info["started_before_release"]) not in (0, 1)):
                raise RuntimeError("duplicate/invalid task identity or start")
            seen.add(task_id)
            tasks.append(info)
        if seen != set(range(expected_count)):
            raise RuntimeError("missing task IDs")
        return tasks

    blockers_data = parse_tasks(blocker_rows, blockers)
    siblings_data = parse_tasks(sibling_rows, 8)
    if sum(int(t["started_before_release"]) for t in blockers_data) != int(
            top["started_before_release"]):
        raise RuntimeError("blocker snapshot count mismatch")
    if sum(int(t["started_before_release"]) for t in siblings_data) != int(
            top["siblings_before_release"]):
        raise RuntimeError("sibling snapshot count mismatch")
    # An observer can sample a sibling just before it starts but still before
    # notification: snapshot flag and actual gate-time are NOT equivalent.
    all_blocker_started_at_ns = max(
        int(t["start_delay_ns"]) for t in blockers_data)
    fully_blocked_before_gate = all_blocker_started_at_ns < gate
    individual = []
    for task in siblings_data:
        delay = int(task["start_delay_ns"])
        individual.append(dict(
            batch=batch, storage=policy, notify=notify, blockers=blockers,
            sibling_id=int(task["task"]), worker=int(task["worker"]),
            start_ns=delay, gate_release_ns=gate,
            start_before_gate=int(delay < gate),
            start_after_all_blockers_before_gate=int(
                fully_blocked_before_gate and
                all_blocker_started_at_ns <= delay < gate),
            snapshot_before_release=int(task["started_before_release"])))
    starts = [row["start_ns"] for row in individual]
    case = dict(batch=batch, storage=policy, notify=notify,
                blockers=blockers, siblings=8,
                gate_release_ns=gate, joined_ns=timeline["joined"],
                final_blocker_start_ns=all_blocker_started_at_ns,
                all_blockers_started_before_gate=int(fully_blocked_before_gate),
                siblings_started_before_gate=sum(
                    x["start_before_gate"] for x in individual),
                siblings_started_after_gate=sum(
                    not x["start_before_gate"] for x in individual),
                progress_after_final_blocker=sum(
                    x["start_after_all_blockers_before_gate"]
                    for x in individual),
                start_p50_ns=percentile(starts, 50),
                start_p95_ns=percentile(starts, 95),
                start_p99_ns=percentile(starts, 99),
                accepted_tasks=blockers + 8,
                stolen_executions=int(top["stolen_executions"]),
                claimed_tasks=int(top["claimed_tasks"]),
                claimed_batches=sum(int(r["ingress_batches"]) for r in claims))
    case.update(cpu)
    return case, individual


def mixed_case(binary, root, batch, storage, notify, producers,
               tasks, budget, workload):
    rows, resources = run_child([
        str(binary), "4", str(producers), str(tasks), str(budget),
        storage, "striped", "off", workload, "off", notify], root)
    row = one(rows, "multi", MULTI)
    if (row["scenario"] != "mixed" or row["policy"] != storage or
            int(row["workers"]) != 4 or
            int(row["producers"]) != producers or
            int(row["budget"]) != budget or
            int(row["tasks"]) != tasks or
            int(row["completed"]) != tasks or
            float(row["throughput_per_s"]) <= 0):
        raise RuntimeError("mixed accounting or typed results mismatch")
    result = dict(batch=batch, storage=storage, notify=notify,
                  producers=producers, tasks=tasks, budget=budget,
                  workload=workload,
                  elapsed_ms=float(row["elapsed_ms"]),
                  throughput_per_s=float(row["throughput_per_s"]),
                  fresh_nodes=int(row["fresh_nodes"]),
                  reused_nodes=int(row["reused_nodes"]),
                  producer_gc_bytes=int(row["producer_gc_bytes"]))
    result.update(resources)
    return result


def write_csv(path, rows):
    if not rows:
        raise RuntimeError(f"no results for {path}")
    with path.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--compiler", default="ldc2")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--burst-ms", type=int, default=100)
    ap.add_argument("--blockers", nargs="+", type=int, default=[3, 4])
    ap.add_argument("--policies", nargs="+", choices=("gc", "recycle"),
                    default=["gc", "recycle"])
    ap.add_argument("--notify", nargs="+", choices=("always", "waiter"),
                    default=["always", "waiter"])
    ap.add_argument("--tasks", type=int, default=6000)
    ap.add_argument("--producers", nargs="+", type=int, default=[1, 4])
    ap.add_argument("--budget", type=int, default=512)
    ap.add_argument("--workload", choices=("minimal", "compute"),
                    default="minimal")
    ap.add_argument("--output", type=Path,
                    default=Path("evidence/r05-batch-size-ab"))
    a = ap.parse_args()
    if (platform.system() != "Linux" or platform.architecture()[0] != "64bit" or
            not 1 <= a.rounds <= 20 or not 10 <= a.burst_ms <= 2000 or
            not 1 <= a.tasks <= 100_000 or not a.blockers or
            any(x not in (3, 4) for x in a.blockers) or
            not a.producers or any(x not in (1, 4, 8) for x in a.producers) or
            a.budget not in (8, 64, 512, 4096)):
        ap.error("unsupported bounded A/B parameters")
    if len(set(a.blockers)) != len(a.blockers) or len(set(a.producers)) != len(
            a.producers) or len(set(a.policies)) != len(a.policies) or len(set(a.notify)) != len(a.notify):
        ap.error("duplicate independent factor")

    root = Path(__file__).resolve().parents[2]
    for batch in (8, 1):
        for config, binary in BINS[batch].values():
            subprocess.run(
                ["dub", "build", "--config=" + config, "--build=release",
                 "--compiler=" + a.compiler, "--force"],
                cwd=root, check=True)
            if not (root / binary).is_file():
                raise RuntimeError(f"DUB did not produce {binary}")
    a.output.mkdir(parents=True, exist_ok=True)
    cases, siblings, mixed, pairs = [], [], [], []
    for rnd in range(a.rounds):
        for storage in a.policies:
            for notify in a.notify:
                for blockers in a.blockers:
                    order = (8, 1) if (rnd + blockers +
                        (storage == "recycle") + (notify == "waiter")) % 2 == 0 else (1, 8)
                    results = {}
                    for batch in order:
                        binary = root / BINS[batch]["burst"][1]
                        case, tasks = burst_case(
                            binary, root, batch, storage, notify, blockers,
                            a.burst_ms)
                        case["round"] = rnd
                        cases.append(case)
                        for row in tasks:
                            row["round"] = rnd
                            siblings.append(row)
                        results[batch] = case
                    old, new = results[8], results[1]
                    pairs.append(dict(kind="burst", round=rnd, storage=storage,
                        notify=notify, blockers=blockers, producers="",
                        metric="siblings_started_before_gate",
                        batch8=old["siblings_started_before_gate"],
                        batch1=new["siblings_started_before_gate"],
                        delta_batch1_minus_batch8=(
                            new["siblings_started_before_gate"] -
                            old["siblings_started_before_gate"])))
                    print(f"burst r={rnd} {storage}/{notify} blockers={blockers} "
                          f"pre-gate: 8={old['siblings_started_before_gate']} "
                          f"1={new['siblings_started_before_gate']} "
                          f"progress: 8={old['progress_after_final_blocker']} "
                          f"1={new['progress_after_final_blocker']}", flush=True)
                for producers in a.producers:
                    order = (8, 1) if (rnd + producers +
                        (storage == "recycle") + (notify == "waiter")) % 2 == 0 else (1, 8)
                    results = {}
                    for batch in order:
                        binary = root / BINS[batch]["mixed"][1]
                        case = mixed_case(binary, root, batch, storage, notify,
                                          producers, a.tasks, a.budget,
                                          a.workload)
                        case["round"] = rnd
                        mixed.append(case)
                        results[batch] = case
                    old, new = results[8], results[1]
                    pairs.append(dict(kind="mixed", round=rnd, storage=storage,
                        notify=notify, blockers="", producers=producers,
                        metric="throughput_per_s",
                        batch8=old["throughput_per_s"],
                        batch1=new["throughput_per_s"],
                        delta_batch1_minus_batch8=round(
                            new["throughput_per_s"] -
                            old["throughput_per_s"], 3)))
                    print(f"mixed r={rnd} {storage}/{notify} producers={producers} "
                          f"tasks/s: 8={old['throughput_per_s']:.0f} "
                          f"1={new['throughput_per_s']:.0f}", flush=True)

    write_csv(a.output / "burst_cases.csv", cases)
    write_csv(a.output / "burst_siblings.csv", siblings)
    write_csv(a.output / "mixed_cases.csv", mixed)
    write_csv(a.output / "pairs.csv", pairs)

    summary = []
    for storage in a.policies:
        for notify in a.notify:
            for blockers in a.blockers:
                group = [r for r in pairs if r["kind"] == "burst"
                         and r["storage"] == storage and r["notify"] == notify
                         and r["blockers"] == blockers]
                if len(group) != a.rounds:
                    raise RuntimeError("missing burst A/B pairs")
                summary.append(dict(kind="burst", storage=storage,
                    notify=notify, blockers=blockers, producers="",
                    rounds=a.rounds, metric="pre_gate_siblings",
                    median_batch8=statistics.median(r["batch8"] for r in group),
                    median_batch1=statistics.median(r["batch1"] for r in group),
                    median_paired_delta=statistics.median(
                        r["delta_batch1_minus_batch8"] for r in group)))
            for producers in a.producers:
                group = [r for r in pairs if r["kind"] == "mixed"
                         and r["storage"] == storage and r["notify"] == notify
                         and r["producers"] == producers]
                if len(group) != a.rounds:
                    raise RuntimeError("missing mixed A/B pairs")
                summary.append(dict(kind="mixed", storage=storage,
                    notify=notify, blockers="", producers=producers,
                    rounds=a.rounds, metric="throughput_per_s",
                    median_batch8=statistics.median(r["batch8"] for r in group),
                    median_batch1=statistics.median(r["batch1"] for r in group),
                    median_paired_delta=statistics.median(
                        r["delta_batch1_minus_batch8"] for r in group)))
    write_csv(a.output / "summary.csv", summary)

    # Descriptive grouped latency distribution from the *actual* runnable
    # callable starts, not child walltime or the instrumented trace.
    # Keep per-round observations for uncertainty and paired analyses.
    latency = []
    for storage in a.policies:
        for notify in a.notify:
            for blockers in a.blockers:
                for batch in (8, 1):
                    group = [r for r in cases
                             if r["batch"] == batch and
                             r["storage"] == storage and
                             r["notify"] == notify and
                             r["blockers"] == blockers]
                    samples = [r["start_ns"] for r in siblings
                               if r["batch"] == batch and
                               r["storage"] == storage and
                               r["notify"] == notify and
                               r["blockers"] == blockers]
                    if len(group) != a.rounds or len(samples) != 8 * a.rounds:
                        raise RuntimeError("missing sibling latency evidence")
                    latency.append(dict(
                        storage=storage, notify=notify,
                        blockers=blockers, batch=batch,
                        rounds=a.rounds, sibling_samples=len(samples),
                        start_p50_ns=percentile(samples, 50),
                        start_p95_ns=percentile(samples, 95),
                        start_p99_ns=percentile(samples, 99),
                        median_case_start_p95_ns=statistics.median(
                            r["start_p95_ns"] for r in group),
                        total_before_gate=sum(
                            r["siblings_started_before_gate"] for r in group),
                        total_after_gate=sum(
                            r["siblings_started_after_gate"] for r in group),
                        progress_after_final_blocker=sum(
                            r["progress_after_final_blocker"] for r in group),
                        median_child_cpu_user_us=statistics.median(
                            r["child_cpu_user_us"] for r in group),
                        median_child_cpu_system_us=statistics.median(
                            r["child_cpu_system_us"] for r in group)))
    write_csv(a.output / "latency_summary.csv", latency)

    with (a.output / "environment.txt").open("w") as fp:
        fp.write(f"platform={platform.platform()}\n"
                 f"machine={platform.machine()} compiler={a.compiler}\n"
                 f"rounds={a.rounds} workers=4 burst_ms={a.burst_ms}\n"
                 f"blockers={a.blockers} storage={a.policies} "
                 f"notification={a.notify}\n"
                 f"mixed_producers={a.producers} tasks={a.tasks} "
                 f"budget={a.budget} workload={a.workload}\n"
                 "batch8=production-baseline; batch1=isolated-research-variant\n"
                 "No task trace; child process resource is NOT worker idle CPU.\n"
                 "Burst p99 of eight tasks is only an observed maximum.\n")
        for command in (["git", "rev-parse", "HEAD"],
                        [a.compiler, "--version"], ["lscpu"]):
            fp.write("$ " + " ".join(command) + "\n")
            try:
                fp.write(subprocess.run(command, cwd=root,
                    capture_output=True, text=True, check=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fp.write("unavailable\n")
    print("R0.5 batch size: research-only untraced pairing, no promotion")
    print("evidence: " + str(a.output))


if __name__ == "__main__":
    main()
