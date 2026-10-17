#!/usr/bin/env python3
"""Validate P42.16 observed multi-idle raw logs and extract lossless CSV.

No tick-frequency assumption, OS wake claim, or unpaired p99 inference is made.
The output is diagnostic experiment evidence, not a release performance gate.
"""
import csv
from pathlib import Path
import re
import sys


RAW_NAME = re.compile(r"^s([1-3])-p([1-6])-(baseline|conditional)\.txt$")
SHAPES = (1, 4, 32)
ROUNDS = 12
EXPECTED_TASKS = ROUNDS * sum(SHAPES)


def parse_fields(line, prefix):
    if not line.startswith(prefix + " "):
        raise ValueError("bad " + prefix + ": " + line)
    pieces = line.split()[1:]
    if any("=" not in piece for piece in pieces):
        raise ValueError("malformed diagnostic line: " + line)
    fields = dict(piece.split("=", 1) for piece in pieces)
    if len(fields) != len(pieces):
        raise ValueError("duplicate diagnostic key: " + line)
    return fields


def vector(value):
    result = tuple(int(item) for item in value.split(","))
    if len(result) != 4 or any(item < 0 for item in result):
        raise ValueError("expected four nonnegative worker counts: " + value)
    return result


def collect(path, session, pair, arm):
    waits, tasks, summaries, passed = {}, {}, {}, 0
    with path.open(encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line.startswith("P42_MULTI_IDLE_TASK "):
                data = parse_fields(line, "P42_MULTI_IDLE_TASK")
                key = (int(data["tasks"]), int(data["round"]))
                task_id = int(data["task"])
                if data["arm"] != arm or (key, task_id) in tasks:
                    raise ValueError("arm mismatch or duplicate task: " + line)
                worker = int(data["worker"])
                published, started = int(data["publish_ticks"]), int(data["start_ticks"])
                own = int(data["own_publish_to_start_ticks"])
                if not 0 <= worker < 4 or own < 0 or started - published != own:
                    raise ValueError("invalid task ID/timing: " + line)
                tasks[(key, task_id)] = (worker, published, started, own)
            elif line.startswith("P42_MULTI_IDLE_WAIT "):
                data = parse_fields(line, "P42_MULTI_IDLE_WAIT")
                key = (int(data["tasks"]), int(data["round"]))
                entries = vector(data["wait_entries"])
                enrolled = tuple(x.lower() for x in data["enrolled"].split(","))
                if (data["arm"] != arm or key in waits or
                    int(data["simultaneous_waiters"]) != 4 or
                    enrolled != ("true",) * 4 or min(entries) < 1):
                    raise ValueError("not four current enrolled workers: " + line)
                waits[key] = entries
            elif line.startswith("P42_MULTI_IDLE arm="):
                data = parse_fields(line, "P42_MULTI_IDLE")
                key = (int(data["tasks"]), int(data["round"]))
                counts = vector(data["work_per_worker"])
                burst = int(data["max_publish_to_start_ticks"])
                if data["arm"] != arm or key in summaries or burst < 0:
                    raise ValueError("invalid round summary: " + line)
                summaries[key] = (counts, burst)
            elif line.startswith("P42_MULTI_IDLE_PASS "):
                if "wait_evidence=simultaneous_per_worker_enrollments" not in line:
                    raise ValueError("unexpected PASS evidence: " + line)
                passed += 1
    if passed != 1 or len(tasks) != EXPECTED_TASKS or len(waits) != 36 or len(summaries) != 36:
        raise ValueError(f"incomplete raw log: {path}: tasks={len(tasks)}, "
                         f"waits={len(waits)}, rounds={len(summaries)}, pass={passed}")
    task_rows, round_rows = [], []
    for shape in SHAPES:
        for round_id in range(ROUNDS):
            key = (shape, round_id)
            if key not in waits or key not in summaries:
                raise ValueError("missing round: " + str(key))
            counts = [0] * 4
            own = []
            for task_id in range(shape):
                if (key, task_id) not in tasks:
                    raise ValueError("missing task " + str((key, task_id)))
                worker, published, started, ticks = tasks[(key, task_id)]
                counts[worker] += 1
                own.append(ticks)
                task_rows.append((session, pair, arm, shape, round_id, task_id,
                                  worker, published, started, ticks))
            reported, burst = summaries[key]
            if tuple(counts) != reported or sum(counts) != shape or burst < max(own):
                raise ValueError("worker distribution or burst timing mismatch: " + str(key))
            round_rows.append((session, pair, arm, shape, round_id, 4,
                               *waits[key], *counts, sum(x != 0 for x in counts), burst))
    return task_rows, round_rows


def self_test():
    """Exercise a complete synthetic log and an invalid worker negative control."""
    from tempfile import TemporaryDirectory
    with TemporaryDirectory(prefix="p42-16-extract-") as tmp:
        path = Path(tmp) / "s1-p1-baseline.txt"
        lines = []
        for shape in SHAPES:
            for round_id in range(ROUNDS):
                lines.append(
                    f"P42_MULTI_IDLE_WAIT arm=baseline tasks={shape} "
                    f"round={round_id} simultaneous_waiters=4 "
                    f"wait_entries=1,1,1,1 enrolled=true,true,true,true"
                )
                counts = [0] * 4
                for task_id in range(shape):
                    worker = task_id % 4
                    counts[worker] += 1
                    lines.append(
                        f"P42_MULTI_IDLE_TASK arm=baseline tasks={shape} "
                        f"round={round_id} task={task_id} worker={worker} "
                        f"publish_ticks={100+task_id} "
                        f"start_ticks={200+task_id} own_publish_to_start_ticks=100"
                    )
                lines.append(
                    f"P42_MULTI_IDLE arm=baseline tasks={shape} round={round_id} "
                    f"max_publish_to_start_ticks=120 "
                    f"work_per_worker={','.join(map(str, counts))}"
                )
        lines.append(
            "P42_MULTI_IDLE_PASS workers=4 rounds=12 cases=3 "
            "wait_evidence=simultaneous_per_worker_enrollments "
            "worker_distribution=recorded"
        )
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        samples, rounds = collect(path, 1, 1, "baseline")
        assert len(samples) == EXPECTED_TASKS and len(rounds) == 36
        broken = path.read_text(encoding="utf-8").replace(
            "task=0 worker=0", "task=0 worker=7", 1)
        path.write_text(broken, encoding="utf-8")
        try:
            collect(path, 1, 1, "baseline")
        except ValueError:
            pass
        else:
            raise AssertionError("negative worker-ID control was accepted")
    print("P42_MULTI_IDLE_EXTRACT_SELF_TEST_PASS")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: m1_p42_multi_idle_extract.py EXISTING-RESULTS-DIR")
    root = Path(sys.argv[1])
    raw = root / "raw"
    paths = sorted(p for p in raw.glob("*.txt") if RAW_NAME.fullmatch(p.name))
    if len(paths) != 36:
        raise ValueError(f"expected 36 raw paired runs, found {len(paths)}")
    task_rows, round_rows, seen = [], [], set()
    for path in paths:
        match = RAW_NAME.fullmatch(path.name)
        session, pair, arm = int(match[1]), int(match[2]), match[3]
        key = session, pair, arm
        if key in seen:
            raise ValueError("duplicate measurement arm " + str(key))
        seen.add(key)
        t, r = collect(path, session, pair, arm)
        task_rows.extend(t)
        round_rows.extend(r)
    for session in range(1, 4):
        for pair in range(1, 7):
            if (session, pair, "baseline") not in seen or (session, pair, "conditional") not in seen:
                raise ValueError("unpaired measurement " + str((session, pair)))
    with (root / "tasks.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(("session", "pair", "arm", "shape_tasks", "round", "task_id",
                         "worker", "publish_ticks", "start_ticks", "own_latency_ticks"))
        writer.writerows(task_rows)
    with (root / "rounds.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(("session", "pair", "arm", "shape_tasks", "round",
                         "observed_waiters", "wait_entries_w0", "wait_entries_w1",
                         "wait_entries_w2", "wait_entries_w3", "tasks_w0", "tasks_w1",
                         "tasks_w2", "tasks_w3", "active_workers", "max_burst_ticks"))
        writer.writerows(round_rows)
    print(f"P42_MULTI_IDLE_EXTRACT_PASS files={len(paths)} "
          f"task_rows={len(task_rows)} round_rows={len(round_rows)}")


if __name__ == "__main__":
    main()
