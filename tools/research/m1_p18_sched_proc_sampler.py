#!/usr/bin/env python3
"""P18 opt-in unprivileged /proc per-thread scheduler diagnostics, NOT perf.

Only reads /proc/<launched-PID>/task/<TID> for a child process launched by
this collector; no tracefs, perf, ptrace, privilege changes or other PIDs.
Sampling misses events, short-lived threads and beginning/end of lifetimes.
Totals are observed lower bounds, NOT full thread lifetime counters.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

COLUMNS = (
    "sample_ns", "pid", "tid", "starttime", "comm", "state", "last_cpu",
    "run_ns", "runqueue_wait_ns", "timeslices", "voluntary_switches",
    "involuntary_switches", "nr_migrations",
)


def _read(path):
    return Path(path).read_text(encoding="utf-8")


def stat_fields(value):
    # comm is inside parentheses and may itself contain blanks/parentheses.
    pos = value.rfind(") ")
    if pos < 0:
        raise ValueError("malformed Linux task stat")
    rest = value[pos + 2:].split()
    if len(rest) < 37:
        raise ValueError("short Linux task stat")
    # /proc/[pid]/stat starts with pid=field 1 and comm=field 2.
    # rest[0]=field 3, starttime=22, last_processor=39.
    return rest[0], int(rest[19]), int(rest[36])


def status_switches(raw):
    fields = {}
    for line in raw.splitlines():
        if line.startswith("voluntary_ctxt_switches:"):
            fields["voluntary_switches"] = int(line.split(":", 1)[1])
        elif line.startswith("nonvoluntary_ctxt_switches:"):
            fields["involuntary_switches"] = int(line.split(":", 1)[1])
    if len(fields) != 2:
        raise ValueError("Linux task status context-switch counters unavailable")
    return fields


def sched_migrations(raw):
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        if key.strip() in ("nr_migrations", "se.nr_migrations"):
            return int(value.strip().split()[0])
    return None


def kernel_wait_capability():
    path = Path("/proc/sys/kernel/sched_schedstats")
    try:
        value = path.read_text().strip()
        return value == "1", value
    except OSError:
        return False, "unavailable"


def get_thread(pid, tid, sample_ns):
    root = Path("/proc") / str(pid) / "task" / str(tid)
    state, starttime, cpu = stat_fields(_read(root / "stat"))
    run = _read(root / "schedstat").split()
    if len(run) != 3:
        raise ValueError("Linux task schedstat has unexpected field count")
    switches = status_switches(_read(root / "status"))
    try:
        migrations = sched_migrations(_read(root / "sched"))
    except (OSError, ValueError):
        migrations = None
    try:
        comm = _read(root / "comm").strip()
    except OSError:
        comm = ""
    return dict(
        sample_ns=sample_ns, pid=pid, tid=tid, starttime=starttime,
        comm=comm, state=state, last_cpu=cpu, run_ns=int(run[0]),
        runqueue_wait_ns=int(run[1]), timeslices=int(run[2]),
        nr_migrations=migrations, **switches,
    )


def sample_threads(pid, writer):
    root = Path("/proc") / str(pid) / "task"
    now = time.monotonic_ns()
    try:
        tids = [int(entry.name) for entry in root.iterdir()
                if entry.name.isdecimal()]
    except (FileNotFoundError, ProcessLookupError):
        return 0, 0
    count = 0
    dropped = 0
    for tid in tids:
        try:
            writer.writerow(get_thread(pid, tid, now))
            count += 1
        except (FileNotFoundError, ProcessLookupError, PermissionError,
                ValueError, OSError):
            # Task disappeared or the kernel lacks the requested field.
            dropped += 1
    return count, dropped


def deltas(first, last, field):
    a, b = first.get(field), last.get(field)
    if a is None or b is None or a == "" or b == "":
        return None
    diff = int(b) - int(a)
    return diff if diff >= 0 else None


def summarize(rows, pid, metadata):
    grouped = {}
    for row in rows:
        key = (int(row["tid"]), int(row["starttime"]))
        grouped.setdefault(key, []).append(row)
    by_tid = []
    for (tid, starttime), group in sorted(grouped.items()):
        group.sort(key=lambda row: int(row["sample_ns"]))
        first, last = group[0], group[-1]
        cpu_changes = sum(
            group[i]["last_cpu"] != group[i-1]["last_cpu"]
            for i in range(1, len(group))
        )
        report = {
            "tid": tid, "starttime": starttime,
            "role": "main_producer" if tid == pid else "other_thread_unverified",
            "comm": last["comm"], "samples": len(group),
            "observed_elapsed_ns": int(last["sample_ns"]) - int(first["sample_ns"]),
            "observed_cpu_changes_min": cpu_changes,
        }
        for key in ("run_ns", "runqueue_wait_ns", "timeslices",
                    "voluntary_switches", "involuntary_switches",
                    "nr_migrations"):
            report["observed_" + key + "_delta"] = deltas(first, last, key)
        if not metadata["kernel_sched_schedstats_enabled"]:
            report["observed_runqueue_wait_ns_delta"] = None
        by_tid.append(report)
    metadata["unique_thread_epochs_observed"] = len(by_tid)
    metadata["nonmain_thread_epochs_observed"] = sum(
        x["role"] != "main_producer" for x in by_tid
    )
    metadata["main_thread_observed"] = any(
        x["role"] == "main_producer" for x in by_tid
    )
    metadata["thread_coverage"] = (
        "ATTENTION_NO_NONMAIN_THREAD_OBSERVED"
        if not metadata["nonmain_thread_epochs_observed"] else
        "OBSERVED_NONMAIN_TID_NOT_PROVEN_POOL_WORKER"
    )
    metadata["statistic_scope"] = (
        "observed first-to-last sample deltas per thread epoch ONLY; "
        "not complete lifetime, not exact context-switch/wakeup sequence"
    )
    metadata["threads"] = by_tid
    return metadata


def probe():
    supported, raw = kernel_wait_capability()
    pid = os.getpid()
    try:
        thread = get_thread(pid, pid, time.monotonic_ns())
        ok = True
        failure = None
    except (OSError, ValueError) as exc:
        ok = False
        thread = None
        failure = repr(exc)
    result = {
        "linux": sys.platform == "linux",
        "proc_task_readable": ok,
        "kernel_sched_schedstats_value": raw,
        "kernel_sched_schedstats_enabled": supported,
        "runnable_wait_time_available": supported and ok,
        "thread_sched_migrations_available": (
            thread is not None and thread["nr_migrations"] is not None
        ),
        "privileges_modified": False,
        "scope": "own process and explicitly launched child tasks only",
        "sampling_loses_short_lived_threads": True,
        "failure": failure,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if ok and result["linux"] else 3


def build_command(args):
    # Popen accepts os.PathLike values; JSON provenance does not.
    # Keep the command construction shared by the actual record path and
    # regression self-test rather than independently recreating its shape.
    return [
        "taskset", "-c", args.cpus, str(args.binary),
        "--profile", args.profile, "--count", str(args.count),
        "--waves", str(args.waves), "--warmup", "2",
        "--rounds", str(args.rounds), "--seed", str(args.seed)
    ]


def record(args):
    if not sys.platform.startswith("linux"):
        raise RuntimeError("Linux /proc required")
    if not Path(args.binary).is_file():
        raise RuntimeError("binary missing")
    supported, schedstats_value = kernel_wait_capability()
    if args.require_runqueue_wait and not supported:
        raise RuntimeError(
            "runqueue-wait unavailable: kernel.sched_schedstats is not 1; "
            "no kernel settings changed")
    args.samples.parent.mkdir(parents=True, exist_ok=True)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.stdout.parent.mkdir(parents=True, exist_ok=True)
    command = build_command(args)
    metadata = {
        "backend": "procfs_thread_polling_EXPLICIT_OPT_IN_NOT_PERF",
        "requested_interval_ms": args.interval_ms,
        "kernel_sched_schedstats_value": schedstats_value,
        "kernel_sched_schedstats_enabled": supported,
        "runnable_wait_time_available": supported,
        "sampled_task_scope": "launched benchmark PID/TIDs ONLY",
        "perf_tracepoints_collected": False,
        "no_kernel_or_permission_changes": True,
        "not_performance_evidence": True,
        "limitations": (
            "Polling perturbs scheduling and misses short-lived threads, "
            "switch events and CPU migrations between samples. Time "
            "deltas reflect observed windows, not complete lifetimes. "
            "Other threads are not verified worker TIDs."
        ),
        "command": command,
    }
    if args.interval_ms < 0.2 or args.interval_ms > 100:
        raise ValueError("sampling interval must be 0.2..100ms")
    started = time.monotonic()
    with args.stdout.open("w") as process_output, \
         args.samples.open("w", newline="") as csv_output:
        writer = csv.DictWriter(csv_output, fieldnames=COLUMNS)
        writer.writeheader()
        child = subprocess.Popen(
            command, stdout=process_output, stderr=subprocess.STDOUT,
            start_new_session=True)
        metadata["pid"] = child.pid
        metadata["total_samples"] = 0
        metadata["dropped_thread_reads"] = 0
        try:
            while True:
                seen, dropped = sample_threads(child.pid, writer)
                metadata["total_samples"] += seen
                metadata["dropped_thread_reads"] += dropped
                if child.poll() is not None:
                    break
                if time.monotonic() - started > args.timeout_s:
                    raise TimeoutError("P18 procfs run exceeded requested timeout")
                time.sleep(args.interval_ms / 1000)
            metadata["process_exit_code"] = child.returncode
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
    with args.samples.open(newline="") as recorded:
        rows = list(csv.DictReader(recorded))
    metadata = summarize(rows, child.pid, metadata)
    metadata["wall_interval_from_monitor_s"] = time.monotonic() - started
    args.summary.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    if metadata["process_exit_code"] != 0:
        raise RuntimeError("P18 benchmark exited nonzero")
    if (not metadata["main_thread_observed"] or
        not metadata["nonmain_thread_epochs_observed"]):
        raise RuntimeError(
            "thread-sampling incomplete: main/other thread not both observed")
    print("P18 PROCFS OBSERVATIONAL TRACE", args.summary,
          "threads_seen", metadata["unique_thread_epochs_observed"])
    if not supported:
        print("ATTENTION: runnable/runqueue wait UNAVAILABLE because "
              "kernel.sched_schedstats != 1", file=sys.stderr)


def self_test():
    state, starttime, cpu = stat_fields(
        "191 (worker with ) char) S " + " ".join(str(i) for i in range(1, 47))
    )
    assert state == "S"
    assert starttime == 19 and cpu == 36
    assert status_switches(
        "voluntary_ctxt_switches:\t13\nnonvoluntary_ctxt_switches:\t7\n"
    ) == {"voluntary_switches":13, "involuntary_switches":7}
    assert sched_migrations("nr_migrations : 4\n") == 4
    assert sched_migrations("se.nr_migrations : 9\n") == 9
    assert sched_migrations("other : 0\n") is None
    # A subprocess can accept pathlib.Path in its argv, but json.dumps
    # cannot. Exercise the same metadata schema that previously failed on
    # Dell XPS Python 3.14, including a genuine Path input.
    synthetic_command = build_command(argparse.Namespace(
        cpus="0,1,2,3", binary=Path("/tmp/p18-control"),
        profile="sched8", count=16, waves=2, rounds=1, seed=42,
    ))
    assert all(isinstance(item, str) for item in synthetic_command)
    record_metadata = {
        "command": synthetic_command,
        "pid": 421,
        "total_samples": 2,
        "process_exit_code": 0,
        "kernel_sched_schedstats_enabled": False,
    }
    sample = dict.fromkeys(COLUMNS, "0")
    sample.update(sample_ns="1", pid="421", tid="421",
                  starttime="99", run_ns="100", last_cpu="1")
    later = dict(sample, sample_ns="2", run_ns="200")
    json_payload = json.dumps(
        summarize([sample, later], 421, record_metadata),
        indent=2, sort_keys=True,
    )
    roundtrip = json.loads(json_payload)
    assert roundtrip["command"][3] == "/tmp/p18-control"
    assert roundtrip["threads"][0]["observed_run_ns_delta"] == 100
    assert roundtrip["threads"][0]["observed_runqueue_wait_ns_delta"] is None
    assert roundtrip["process_exit_code"] == 0
    assert deltas({"a":4},{"a":7},"a") == 3
    assert deltas({"a":7},{"a":4},"a") is None
    a = dict.fromkeys(COLUMNS, "0")
    b = a.copy()
    a.update(sample_ns="1", pid="1", tid="1", starttime="10",
             last_cpu="0", run_ns="30", runqueue_wait_ns="20", timeslices="1")
    b.update(sample_ns="50", pid="1", tid="1", starttime="10",
             last_cpu="1", run_ns="40", runqueue_wait_ns="22", timeslices="2")
    m = summarize([a, b], 1, {"kernel_sched_schedstats_enabled":False})
    assert m["threads"][0]["observed_cpu_changes_min"] == 1
    assert m["threads"][0]["observed_run_ns_delta"] == 10
    assert m["threads"][0]["observed_runqueue_wait_ns_delta"] is None
    print("P18 PROCFS sampler synthetic self-test PASS")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="action", required=True)
    sub.add_parser("probe")
    sub.add_parser("self-test")
    cmd = sub.add_parser("record")
    for name in ("binary", "stdout", "samples", "summary"):
        cmd.add_argument("--"+name, type=Path, required=True)
    cmd.add_argument("--cpus", default="0,1,2,3")
    cmd.add_argument("--profile", choices=("sched8","sched2048"), required=True)
    cmd.add_argument("--count", type=int, default=2048)
    cmd.add_argument("--waves", type=int, default=3)
    cmd.add_argument("--rounds", type=int, default=24)
    cmd.add_argument("--seed", type=int, required=True)
    cmd.add_argument("--interval-ms", type=float, default=1.0)
    cmd.add_argument("--timeout-s", type=float, default=90)
    cmd.add_argument("--require-runqueue-wait", action="store_true")
    args = p.parse_args()
    if args.action == "self-test":
        self_test()
    elif args.action == "probe":
        raise SystemExit(probe())
    else:
        record(args)


if __name__ == "__main__":
    main()
