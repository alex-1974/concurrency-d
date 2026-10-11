#!/usr/bin/env python3
"""R0.5 diagnostic: bounded burst-blocker placement, steals and starts.

The test deliberately does NOT require all blockers to begin promptly.
Every child releases its own semaphore gate after a fixed sleep,
then checks exact typed results, claim provenance and clean shutdown.
"""
import argparse
import csv
from pathlib import Path
import platform
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
SIBLING = ("metric", "task", "started_before_release", "worker",
           "start_delay_ns")


def parse_line(line, schema):
    parts = next(csv.reader([line]))
    if len(parts) != len(schema):
        raise RuntimeError(f"bad diagnostic row {schema[0]}: {line}")
    return dict(zip(schema, parts))


def run(binary, cwd, policy, storage, workers, blockers, siblings, probe_ms,
        round_id):
    cmd = [str(binary), policy, storage, str(workers), str(blockers),
           str(siblings), str(probe_ms)]
    started = time.monotonic_ns()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           timeout=15)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"burst process timed out after gate deadline: {cmd}") from exc
    wall = time.monotonic_ns() - started
    if p.returncode:
        raise RuntimeError(f"burst failed {cmd}, rc={p.returncode}\n"
                           + (p.stdout + p.stderr)[-6000:])
    lines = [x for x in p.stdout.splitlines() if
             x.startswith(("burst,", "claim,", "task,", "sibling,"))]
    top = [parse_line(x, BURST) for x in lines if x.startswith("burst,")]
    claims = [parse_line(x, CLAIM) for x in lines if x.startswith("claim,")]
    tasks = [parse_line(x, TASK) for x in lines if x.startswith("task,")]
    sibling_rows = [parse_line(x, SIBLING) for x in lines
                    if x.startswith("sibling,")]
    if (len(top) != 1 or len(claims) != workers or
        len(tasks) != blockers or len(sibling_rows) != siblings):
        raise RuntimeError("incomplete burst diagnostic output")
    record = top[0]
    for name, expected in (("notify", policy), ("storage", storage),
                           ("workers", workers), ("blockers", blockers),
                           ("siblings", siblings), ("probe_ms", probe_ms),
                           ("claimed_tasks", blockers + siblings)):
        if str(record[name]) != str(expected):
            raise RuntimeError(f"invalid {name} in {record}")
    if (int(record["started_before_release"]) !=
            sum(int(x["started_before_release"]) for x in tasks)):
        raise RuntimeError("start count was not conserved")
    if (int(record["distinct_workers"]) !=
            len(set(int(x["worker"]) for x in tasks))):
        raise RuntimeError("distinct worker attribution mismatch")
    if sorted(int(x["worker"]) for x in claims) != list(range(workers)):
        raise RuntimeError("missing per-worker claim counter")
    if sorted(int(x["task"]) for x in tasks) != list(range(blockers)):
        raise RuntimeError("duplicate/missing blocker task ID")
    if (sorted(int(x["task"]) for x in sibling_rows) !=
        list(range(siblings)) or
        int(record["siblings_before_release"]) != sum(
            int(x["started_before_release"]) for x in sibling_rows)):
        raise RuntimeError("duplicate/missing sibling or wrong start count")
    if any(int(x["start_delay_ns"]) < 0 for x in tasks + sibling_rows):
        raise RuntimeError("negative task startup delay")
    if (sum(int(x["claimed_tasks"]) for x in claims) !=
            blockers + siblings or
        sum(int(x["executions"]) for x in claims) !=
            blockers + siblings or
        sum(int(x["stolen_executions"]) for x in claims) !=
            int(record["stolen_executions"])):
        raise RuntimeError("post-join worker source accounting mismatch")

    record.update(round=round_id, wall_ns=wall)
    for row in claims:
        row.update(round=round_id, notify=policy, storage=storage,
                   blockers=blockers)
    for row in tasks + sibling_rows:
        row.update(round=round_id, notify=policy, storage=storage,
                   blockers=blockers)
    return record, claims, tasks, sibling_rows


def write_csv(path, rows):
    if not rows:
        raise ValueError("no rows")
    with path.open("w", newline="") as f:
        out = csv.DictWriter(f, fieldnames=list(rows[0]))
        out.writeheader()
        out.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--siblings", type=int, default=8)
    p.add_argument("--probe-ms", type=int, default=100)
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--blockers", type=int, nargs="+", default=[3, 4])
    p.add_argument("--policies", nargs="+", default=["gc", "recycle"],
                   choices=("gc", "recycle"))
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-burst-head-of-line"))
    args = p.parse_args()
    if (platform.system() != "Linux" or
        not 1 <= args.workers <= 32 or
        not 1 <= args.siblings <= 64 or
        not 1 <= args.probe_ms <= 2000 or
        not 1 <= args.rounds <= 20 or
        not args.blockers or
        any(not 1 <= n <= args.workers for n in args.blockers)):
        p.error("invalid bounded burst parameters")
    root = Path(__file__).resolve().parents[2]
    subprocess.run(["dub", "build", "--config=burst-head-of-line-benchmark",
                    "--build=release", "--compiler=" + args.compiler,
                    "--force"], cwd=root, check=True)
    binary = root / "concurrency-burst-head-of-line"
    if not binary.exists():
        raise RuntimeError("DUB burst executable was not emitted")
    args.output.mkdir(parents=True, exist_ok=True)
    records, claims, tasks, sibling_tasks = [], [], [], []
    for rnd in range(args.rounds):
        modes = ("always", "waiter") if rnd % 2 == 0 else (
            "waiter", "always")
        for storage in args.policies:
            for blocked in args.blockers:
                for notify in modes:
                    row, r_claims, r_tasks, r_siblings = run(
                        binary, root, notify, storage, args.workers,
                        blocked, args.siblings, args.probe_ms, rnd)
                    records.append(row)
                    claims.extend(r_claims)
                    tasks.extend(r_tasks)
                    sibling_tasks.extend(r_siblings)
                    print(
                        f"R05 burst round={rnd} {storage}/{notify} "
                        f"blockers={blocked} started="
                        f"{row['started_before_release']}/{blocked} "
                        f"siblings={row['siblings_before_release']}"
                        f"/{args.siblings} after-all-starts="
                        f"{row['siblings_after_all_starts']} "
                        f"steals={row['stolen_executions']}",
                        flush=True)
    write_csv(args.output / "raw.csv", records)
    write_csv(args.output / "claims.csv", claims)
    write_csv(args.output / "tasks.csv", tasks)
    write_csv(args.output / "siblings.csv", sibling_tasks)
    summary = []
    for storage in args.policies:
        for blocked in args.blockers:
            for notify in ("always", "waiter"):
                group = [x for x in records if x["storage"] == storage
                         and int(x["blockers"]) == blocked
                         and x["notify"] == notify]
                if len(group) != args.rounds:
                    raise RuntimeError("missing paired result")
                summary.append({
                    "storage": storage, "notify": notify,
                    "blockers": blocked, "workers": args.workers,
                    "siblings": args.siblings, "rounds": args.rounds,
                    "fully_started_before_release": sum(
                        int(x["started_before_release"]) == blocked
                        for x in group),
                    "median_started_before_release": statistics.median(
                        int(x["started_before_release"]) for x in group),
                    "median_siblings_before_release": statistics.median(
                        int(x["siblings_before_release"]) for x in group),
                    "median_claimed": statistics.median(
                        int(x["claimed_tasks"]) for x in group),
                    "median_steals": statistics.median(
                        int(x["stolen_executions"]) for x in group),
                    "median_siblings_after_all_starts": statistics.median(
                        int(x["siblings_after_all_starts"]) for x in group),
                })
    write_csv(args.output / "summary.csv", summary)
    with (args.output / "environment.txt").open("w") as fd:
        fd.write(f"platform={platform.platform()}\n"
                 f"compiler={args.compiler} workers={args.workers}\n"
                 f"blockers={args.blockers} siblings={args.siblings}\n"
                 f"probe_ms={args.probe_ms} rounds={args.rounds}\n")
        for cmd in (["git", "rev-parse", "HEAD"], [args.compiler, "--version"],
                    ["lscpu"]):
            try:
                fd.write("$ " + " ".join(cmd) + "\n")
                fd.write(subprocess.run(cmd, cwd=root, check=True,
                    capture_output=True, text=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")
    print("R05 burst HEAD-OF-LINE: observation only, not a fairness gate")
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
