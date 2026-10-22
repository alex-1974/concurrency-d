#!/usr/bin/env python3
"""Validate P42.17 flow counters beside intact P42.16 task/round evidence.

Each P42_FLOW observation is a pre-submission to pre-close *delta*.
notify calls do not equal worker wakeups; correlated rounds are not iid.
"""
import csv
from pathlib import Path
import sys

from m1_p42_multi_idle_extract import (
    RAW_NAME, ROUNDS, SHAPES, collect, parse_fields, vector,
)


FLOW_KEYS = (
    "publish_with_waiters", "publish_without_waiters",
    "notify_calls", "notify_skipped",
)
VECTORS = ("wait_returns", "predicate_changed", "predicate_unchanged")


def check_flow(data, arm, shape, round_id):
    """Validate the policy accounting without treating wakes as notifications."""
    if data["arm"] != arm or int(data["tasks"]) != shape or int(data["round"]) != round_id:
        raise ValueError("flow identity mismatch: " + str(data))
    counts = {key: int(data[key]) for key in FLOW_KEYS}
    if any(value < 0 for value in counts.values()):
        raise ValueError("negative flow count")
    if counts["publish_with_waiters"] + counts["publish_without_waiters"] != shape:
        raise ValueError("missing/duplicate publications")
    if counts["notify_calls"] + counts["notify_skipped"] != shape:
        raise ValueError("publication notification accounting mismatch")
    if arm == "baseline":
        if counts["notify_calls"] != shape or counts["notify_skipped"] != 0:
            raise ValueError("baseline skipped publication notify")
    else:
        if (counts["notify_calls"] != counts["publish_with_waiters"] or
                counts["notify_skipped"] != counts["publish_without_waiters"]):
            raise ValueError("conditional publication policy mismatch")
    observed = {key: vector(data[key]) for key in VECTORS}
    for worker in range(4):
        if (observed["wait_returns"][worker] !=
                observed["predicate_changed"][worker] +
                observed["predicate_unchanged"][worker]):
            raise ValueError("wait-return predicate classification mismatch")
    return (counts, observed)


def flow_rows(path, session, pair, arm):
    flows = {}
    passed = 0
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("P42_FLOW arm="):
                data = parse_fields(line, "P42_FLOW")
                key = int(data["tasks"]), int(data["round"])
                if key in flows:
                    raise ValueError("duplicate P42_FLOW round: " + str(key))
                flows[key] = data
            elif line.startswith("P42_FLOW_PASS "):
                if ("snapshots=pre_submit_and_pre_close" not in line or
                        "notify_calls_are_not_wakeup_events" not in line):
                    raise ValueError("unsupported flow PASS marker")
                passed += 1
    if passed != 1 or len(flows) != len(SHAPES) * ROUNDS:
        raise ValueError(f"incomplete P42_FLOW evidence: {path}: "
                         f"flows={len(flows)} PASS={passed}")
    result = []
    for shape in SHAPES:
        for round_id in range(ROUNDS):
            key = (shape, round_id)
            if key not in flows:
                raise ValueError("missing P42_FLOW round: " + str(key))
            counts, observed = check_flow(flows[key], arm, shape, round_id)
            result.append((
                session, pair, arm, shape, round_id,
                *(counts[key] for key in FLOW_KEYS),
                *(val for key in VECTORS for val in observed[key]),
                *(sum(observed[key]) for key in VECTORS),
            ))
    return result


def self_test():
    item = dict(arm="conditional", tasks="4", round="0",
                publish_with_waiters="2", publish_without_waiters="2",
                notify_calls="2", notify_skipped="2",
                wait_returns="1,0,2,1", predicate_changed="1,0,1,1",
                predicate_unchanged="0,0,1,0")
    assert check_flow(item, "conditional", 4, 0)[0]["notify_skipped"] == 2
    for update in (
        {"notify_skipped": "1"},
        {"notify_calls": "3"},
        {"predicate_unchanged": "0,0,0,0"},
        {"arm": "baseline"},
    ):
        changed = dict(item, **update)
        try:
            check_flow(changed, "conditional", 4, 0)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid flow accepted: " + str(update))
    baseline = dict(item, arm="baseline", notify_calls="4", notify_skipped="0")
    assert check_flow(baseline, "baseline", 4, 0)
    print("P42_FLOW_EXTRACT_SELF_TEST_PASS")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: m1_p42_flow_extract.py EXISTING-RESULTS-DIR")
    root = Path(sys.argv[1])
    paths = sorted(p for p in (root / "raw").glob("*.txt")
                   if RAW_NAME.fullmatch(p.name))
    if len(paths) != 36:
        raise ValueError(f"expected 36 paired flow logs, found {len(paths)}")
    task_rows, round_rows, flow_data, seen = [], [], [], set()
    for path in paths:
        match = RAW_NAME.fullmatch(path.name)
        session, pair, arm = int(match[1]), int(match[2]), match[3]
        key = session, pair, arm
        if key in seen:
            raise ValueError("duplicate arm: " + str(key))
        seen.add(key)
        # Existing structural validator rejects missing/duplicated task IDs,
        # inconsistent worker histograms and incomplete four-waiter evidence.
        task, rounds = collect(path, session, pair, arm)
        flow = flow_rows(path, session, pair, arm)
        task_rows.extend(task)
        round_rows.extend(rounds)
        flow_data.extend(flow)
    for session in range(1, 4):
        for pair in range(1, 7):
            for arm in ("baseline", "conditional"):
                if (session, pair, arm) not in seen:
                    raise ValueError("missing pair arm " + str((session, pair, arm)))
    for filename, headers, rows in (
        ("tasks.csv",
         ("session", "pair", "arm", "shape_tasks", "round", "task_id",
          "worker", "publish_ticks", "start_ticks", "own_latency_ticks"),
         task_rows),
        ("rounds.csv",
         ("session", "pair", "arm", "shape_tasks", "round",
          "observed_waiters", "wait_entries_w0", "wait_entries_w1",
          "wait_entries_w2", "wait_entries_w3", "tasks_w0", "tasks_w1",
          "tasks_w2", "tasks_w3", "active_workers", "max_burst_ticks"),
         round_rows),
        ("flow.csv",
         ("session", "pair", "arm", "shape_tasks", "round",
          *FLOW_KEYS,
          *(f"{key}_w{worker}" for key in VECTORS for worker in range(4)),
          *(f"{key}_total" for key in VECTORS)),
         flow_data),
    ):
        with (root / filename).open("x", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(headers)
            writer.writerows(rows)
    print(f"P42_FLOW_EXTRACT_PASS files={len(paths)} "
          f"task_rows={len(task_rows)} round_rows={len(round_rows)} "
          f"flow_rows={len(flow_data)}")


if __name__ == "__main__":
    main()
