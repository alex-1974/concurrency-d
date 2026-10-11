#!/usr/bin/env python3
"""R0.5 bounded per-task diagnostic; never a scheduler throughput gate.

Runs the original (untraced) burst executable alongside the separately
version-compiled trace variant. The trace mutex changes scheduling; all
causal conclusions must be qualified against uninstrumented controls.
"""
import argparse
import collections
import csv
from pathlib import Path
import platform
import statistics
import subprocess
import time

EVENT_COLS = ("sequence", "task_id", "kind", "worker", "victim",
              "batch_id", "offset_ns")
STATUS_COLS = ("admitted", "lost_events", "registry_overflow",
               "unmatched", "still_live")
KINDS = {"published", "claimed", "enqueueBegin", "enqueueOk",
         "enqueueFull", "ownerPop", "stolen", "dispatchBegin",
         "dispatchEnd", "accounted"}
REQUIRED = ("published", "claimed", "dispatchBegin",
            "dispatchEnd", "accounted")


def output_rows(text):
    return list(csv.reader(text.splitlines()))


def measure(binary, root, notify, storage, blockers, siblings, probe_ms):
    args = [str(binary), notify, storage, "4", str(blockers),
            str(siblings), str(probe_ms)]
    start = time.monotonic_ns()
    try:
        done = subprocess.run(args, cwd=root, capture_output=True,
                              text=True, timeout=15)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"bounded burst timed out: {args}") from exc
    wall = time.monotonic_ns() - start
    if done.returncode != 0:
        raise RuntimeError(f"burst failed: {args}\n"
                           + (done.stdout + done.stderr)[-7000:])
    rows = output_rows(done.stdout)
    summary = [r for r in rows if r and r[0] == "burst"]
    if len(summary) != 1 or len(summary[0]) != 14:
        raise RuntimeError("missing or malformed burst summary")
    return wall, rows


def trace_check(rows, blockers, siblings):
    expected = blockers + siblings
    status = [r for r in rows if r and r[0] == "trace_status"]
    controls = [r for r in rows if r and r[0] == "control"]
    traces = [r for r in rows if r and r[0] == "trace"]
    if len(status) != 1 or len(status[0]) != 6:
        raise RuntimeError("missing trace_status")
    s = dict(zip(STATUS_COLS, map(int, status[0][1:])))
    if s != dict(admitted=expected, lost_events=0, registry_overflow=0,
                 unmatched=0, still_live=0):
        raise RuntimeError(f"lost events / incorrect identity: {s}")
    if len(controls) != 2 or {r[1] for r in controls} != {
            "gateRelease", "joined"}:
        raise RuntimeError("missing gate-release/join timeline")
    if any(len(r) != 3 for r in controls):
        raise RuntimeError("malformed control event")
    gate = int(next(r[2] for r in controls if r[1] == "gateRelease"))
    joined = int(next(r[2] for r in controls if r[1] == "joined"))
    if gate <= 0 or joined < gate:
        raise RuntimeError("invalid external-release time ordering")

    events = []
    for row in traces:
        if len(row) != 8:
            raise RuntimeError(f"malformed trace row: {row}")
        sequence, task_id, kind, worker, victim, batch, offset = row[1:]
        kind = kind.split(".")[-1]
        if kind not in KINDS:
            raise RuntimeError(f"unknown trace kind {kind}")
        ev = dict(sequence=int(sequence), task_id=int(task_id),
                  kind=kind, worker=int(worker), victim=int(victim),
                  batch_id=int(batch), offset_ns=int(offset))
        if not 1 <= ev["task_id"] <= expected or ev["offset_ns"] < 0:
            raise RuntimeError(f"invalid traced task/timestamp: {ev}")
        if kind != "published" and not 0 <= ev["worker"] < 4:
            raise RuntimeError(f"invalid logical worker: {ev}")
        events.append(ev)
    if [e["sequence"] for e in events] != list(range(1, len(events) + 1)):
        raise RuntimeError("non-contiguous trace sequence")
    by_task = collections.defaultdict(list)
    for ev in events:
        by_task[ev["task_id"]].append(ev)
    if set(by_task) != set(range(1, expected + 1)):
        raise RuntimeError("incomplete accepted-task identity set")
    for task_id, history in by_task.items():
        count = collections.Counter(e["kind"] for e in history)
        for name in REQUIRED:
            if count[name] != 1:
                raise RuntimeError(f"task {task_id}: not exactly one {name}")
        stamps = {e["kind"]: e["sequence"] for e in history}
        if not (stamps["published"] < stamps["claimed"]
                < stamps["dispatchBegin"] < stamps["dispatchEnd"]
                < stamps["accounted"]):
            raise RuntimeError(f"task {task_id}: invalid lifecycle ordering")
        claim = next(e for e in history if e["kind"] == "claimed")
        dispatch = next(e for e in history if e["kind"] == "dispatchBegin")
        if claim["batch_id"] == 0:
            raise RuntimeError("claimed task lacks batch identity")
        if count["enqueueBegin"] != count["enqueueOk"] + count["enqueueFull"]:
            raise RuntimeError("unbalanced deque enqueue window")
        if count["enqueueBegin"] > 1:
            raise RuntimeError("task was enqueued multiple times")
        transfers = count["ownerPop"] + count["stolen"]
        if transfers > 1:
            raise RuntimeError("task popped or stolen more than once")
        if count["enqueueOk"] != transfers:
            raise RuntimeError("successful enqueue must pop or steal exactly once")
        if transfers == 0 and claim["worker"] != dispatch["worker"]:
            raise RuntimeError("direct-ingress task changed worker")
        if transfers:
            terminal = next(e for e in history
                            if e["kind"] in ("ownerPop", "stolen"))
            if terminal["worker"] != dispatch["worker"]:
                raise RuntimeError("work-source/dispatch worker mismatch")
            if terminal["kind"] == "ownerPop":
                if terminal["worker"] != claim["worker"]:
                    raise RuntimeError("non-owner popped the task")
            elif terminal["victim"] != claim["worker"]:
                raise RuntimeError("steal victim differs from enqueue owner")
        for ev in history:
            if ev["kind"].startswith("enqueue") and (
                    ev["worker"] != claim["worker"]):
                raise RuntimeError("enqueue by wrong owner")
    # Link the instrumented scheduler sequence to actual user-callable starts.
    # The burst has one producer; submission IDs are blocker IDs first,
    # then sibling IDs. The mapping is independent of recycled addresses.
    actual = []
    for tag, task_count, offset in (("task", blockers, 0),
                                    ("sibling", siblings, blockers)):
        entries = [r for r in rows if r and r[0] == tag]
        if len(entries) != task_count:
            raise RuntimeError(f"incomplete {tag} callable-start rows")
        seen = set()
        for row in entries:
            if len(row) != 5:
                raise RuntimeError(f"malformed {tag} row")
            index, started_before, worker, start_ns = map(int, row[1:])
            if index in seen or not 0 <= index < task_count:
                raise RuntimeError("duplicate/invalid callable-start index")
            seen.add(index)
            task_id = offset + index + 1
            dispatch = next(e for e in by_task[task_id]
                            if e["kind"] == "dispatchBegin")
            if worker != dispatch["worker"] or start_ns < 0:
                raise RuntimeError("callable start / dispatch worker mismatch")
            actual.append(dict(task_id=task_id,
                               category="blocker" if tag == "task"
                               else "sibling", worker=worker,
                               started_before_release=started_before,
                               callable_start_ns=start_ns))
    return events, actual, gate, joined


def write_csv(path, rows):
    if not rows:
        raise RuntimeError(f"empty evidence: {path}")
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--probe-ms", type=int, default=100)
    p.add_argument("--blockers", type=int, nargs="+", default=[3, 4])
    p.add_argument("--policies", nargs="+", choices=("gc", "recycle"),
                   default=["gc", "recycle"])
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-task-trace"))
    args = p.parse_args()
    if (platform.system() != "Linux" or not 1 <= args.rounds <= 20
            or not 1 <= args.probe_ms <= 2000 or not args.blockers
            or any(b not in (3, 4) for b in args.blockers)):
        p.error("unsupported bounded R0.5 trace parameters")

    root = Path(__file__).resolve().parents[2]
    binaries = {
        "off": ("burst-head-of-line-benchmark",
                "concurrency-burst-head-of-line"),
        "on": ("burst-head-of-line-trace",
               "concurrency-burst-head-of-line-trace"),
    }
    for config, _ in binaries.values():
        subprocess.run(["dub", "build", "--config=" + config,
                        "--build=release", "--compiler=" + args.compiler,
                        "--force"], check=True, cwd=root)

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    observations, trace_events, callable_rows = [], [], []
    for round_id in range(args.rounds):
        for storage in args.policies:
            for blockers in args.blockers:
                for notify in ("always", "waiter"):
                    # Pair both builds in alternating order across rounds.
                    order = ("off", "on") if round_id % 2 == 0 else (
                        "on", "off")
                    measurements = {}
                    for mode in order:
                        binary = root / binaries[mode][1]
                        wall, rows = measure(binary, root, notify, storage,
                                             blockers, 8, args.probe_ms)
                        measurements[mode] = wall
                        if mode == "on":
                            events, actual, gate, joined = trace_check(
                                rows, blockers, 8)
                            for row in actual:
                                row.update(round=round_id, notify=notify,
                                           storage=storage, blockers=blockers)
                                callable_rows.append(row)
                            for ev in events:
                                ev.update(round=round_id, notify=notify,
                                          storage=storage, blockers=blockers)
                                trace_events.append(ev)
                    row = dict(round=round_id, notify=notify, storage=storage,
                               blockers=blockers, siblings=8,
                               off_wall_ns=measurements["off"],
                               on_wall_ns=measurements["on"],
                               wall_ratio_on_over_off=(
                                   measurements["on"] / measurements["off"]),
                               trace_gate_release_ns=gate,
                               trace_joined_ns=joined)
                    observations.append(row)
                    print(f"R05 trace round={round_id} {storage}/{notify} "
                          f"blockers={blockers} events={len(events)} "
                          f"wall(on/off)={row['wall_ratio_on_over_off']:.3f}",
                          flush=True)

    write_csv(output / "cases.csv", observations)
    write_csv(output / "events.csv", trace_events)
    write_csv(output / "callables.csv", callable_rows)
    medians = []
    for blockers in args.blockers:
        for storage in args.policies:
            for notify in ("always", "waiter"):
                subset = [r for r in observations
                          if r["blockers"] == blockers
                          and r["storage"] == storage
                          and r["notify"] == notify]
                medians.append(dict(blockers=blockers, storage=storage,
                    notify=notify, rounds=len(subset),
                    median_wall_ratio_on_over_off=statistics.median(
                        r["wall_ratio_on_over_off"] for r in subset)))
    write_csv(output / "summary.csv", medians)
    with (output / "environment.txt").open("w") as fd:
        fd.write(f"platform={platform.platform()}\n"
                 f"compiler={args.compiler}\n"
                 f"probe_ms={args.probe_ms} rounds={args.rounds}\n"
                 "workers=4 siblings=8\n"
                 "TRACE IS DIAGNOSTIC; mutex changes scheduling.\n"
                 "wall includes child process startup + fixed sleep; "
                 "NOT a throughput metric.\n")
        for cmd in (["git", "rev-parse", "HEAD"],
                    [args.compiler, "--version"], ["lscpu"]):
            fd.write("$ " + " ".join(cmd) + "\n")
            try:
                fd.write(subprocess.run(cmd, cwd=root, check=True,
                       capture_output=True, text=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")
    print("R05 task trace: correlation only; no causal scheduler verdict")
    print("evidence: " + str(output))


if __name__ == "__main__":
    main()
