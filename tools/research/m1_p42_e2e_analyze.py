#!/usr/bin/env python3
"""Strict P42.18 raw+CSV auditor; no inferred speedup or automatic go verdict.

288 independent *process runs*, balanced 6 sessions x 6 pairs x 2 costs
x 2 scenarios (4P/4W target vs 1P/1W policy-exposed drift control) x 2 arms.
The independent unit is the paired invocation within a session, NOT a task.
"""
import csv
from pathlib import Path
import re
from statistics import median
import sys


NAME = re.compile(
    r"^s([1-6])-p([1-6])-(light|medium)-(target|control)"
    r"-(baseline|conditional)\.txt$"
)
LINE = re.compile(
    r"^P42_BENCH arm=(baseline|conditional) producers=(\d+) "
    r"workers=(\d+) tasks=(\d+) elapsed_us=(\d+)$"
)
FIELDS = ("session", "pair", "cost", "scenario", "arm", "producers",
          "workers", "tasks", "elapsed_us")
COSTS = ("light", "medium")
SCENARIOS = ("target", "control")
ARMS = ("baseline", "conditional")
TASKS = 131072
EXPECTED = 6 * 6 * 2 * 2 * 2


def expected_keys():
    return {(session, pair, cost, scenario, arm)
            for session in range(1, 7) for pair in range(1, 7)
            for cost in COSTS for scenario in SCENARIOS for arm in ARMS}


def planned_order():
    """Balanced, fully specified order is essential for pairing/drift checks."""
    for session in range(1, 7):
        for pair in range(1, 7):
            costs = COSTS if (session + pair) % 2 == 0 else COSTS[::-1]
            for cost in costs:
                cost_index = 0 if cost == "light" else 1
                scenarios = (SCENARIOS if (session + pair + cost_index) % 2 == 0
                             else SCENARIOS[::-1])
                for scenario in scenarios:
                    scenario_index = 0 if scenario == "target" else 1
                    arms = (ARMS if (session + pair + cost_index + scenario_index) % 2 == 0
                            else ARMS[::-1])
                    for arm in arms:
                        yield session, pair, cost, scenario, arm


def load_capture(root):
    """Validate raw records against CSV; refuse omission, duplicates or edits."""
    rawdir = root / "raw"
    paths = list(rawdir.glob("*.txt"))
    if len(paths) != EXPECTED:
        raise ValueError(f"expected {EXPECTED} raw logs, got {len(paths)}")
    observed = {}
    for path in paths:
        name = NAME.fullmatch(path.name)
        if name is None:
            raise ValueError("unexpected raw file " + path.name)
        session, pair = int(name[1]), int(name[2])
        cost, scenario, arm = name[3], name[4], name[5]
        key = session, pair, cost, scenario, arm
        if key in observed:
            raise ValueError("duplicate raw measurement " + str(key))
        content = path.read_text(encoding="utf-8").splitlines()
        if len(content) != 1:
            raise ValueError("not exactly one benchmark line: " + path.name)
        match = LINE.fullmatch(content[0])
        if match is None:
            raise ValueError("malformed benchmark stdout: " + path.name)
        parsed_arm = match[1]
        producers, workers, tasks, elapsed = map(int, match.group(2, 3, 4, 5))
        expected_dims = (4, 4) if scenario == "target" else (1, 1)
        if (parsed_arm != arm or (producers, workers) != expected_dims or
                tasks != TASKS or elapsed <= 0):
            raise ValueError("raw semantic/dimension mismatch: " + path.name)
        observed[key] = (producers, workers, tasks, elapsed)
    if set(observed) != expected_keys():
        raise ValueError("missing or invalid paired raw filenames")
    csv_map = {}
    csv_order = []
    with (root / "results.csv").open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("unexpected CSV schema")
        for row in reader:
            try:
                key = (int(row["session"]), int(row["pair"]),
                       row["cost"], row["scenario"], row["arm"])
                values = tuple(int(row[name]) for name in
                               ("producers", "workers", "tasks", "elapsed_us"))
            except (ValueError, KeyError, TypeError) as error:
                raise ValueError("malformed CSV row") from error
            if key in csv_map or key not in observed or observed[key] != values:
                raise ValueError("CSV duplicate or raw mismatch " + str(key))
            csv_map[key] = values
            csv_order.append(key)
    if set(csv_map) != set(observed):
        raise ValueError("CSV missing raw measurements")
    if csv_order != list(planned_order()):
        raise ValueError("CSV execution order deviates from balanced plan")
    return observed


def analyze(observed):
    """Return fully paired rows plus session-level descriptive summaries."""
    paired = []
    for session in range(1, 7):
        for pair in range(1, 7):
            for cost in COSTS:
                for scenario in SCENARIOS:
                    base = observed[session, pair, cost, scenario, "baseline"][3]
                    cond = observed[session, pair, cost, scenario, "conditional"][3]
                    delta_pct = 100.0 * (cond / base - 1.0)
                    paired.append((session, pair, cost, scenario,
                                   base, cond, cond - base, delta_pct))
    by_pair = {(x[0], x[1], x[2], x[3]): x for x in paired}
    sessions = []
    for session in range(1, 7):
        for cost in COSTS:
            target = [by_pair[session, pair, cost, "target"][7]
                      for pair in range(1, 7)]
            control = [by_pair[session, pair, cost, "control"][7]
                       for pair in range(1, 7)]
            diagnostic = [t - c for t, c in zip(target, control)]
            sessions.append((
                session, cost, median(target), median(control),
                median(diagnostic), sum(v < 0 for v in target),
                sum(v < 0 for v in control),
                min(target), max(target),
            ))
    return paired, sessions


def self_test():
    from tempfile import TemporaryDirectory
    with TemporaryDirectory(prefix="p42-e2e-") as tmp:
        root = Path(tmp)
        (root / "raw").mkdir()
        rows = []
        for key in planned_order():
            session, pair, cost, scenario, arm = key
            p, w = (4, 4) if scenario == "target" else (1, 1)
            value = 1000 + 10 * session + pair + (10 if arm == "conditional" else 0)
            filename = f"s{session}-p{pair}-{cost}-{scenario}-{arm}.txt"
            (root / "raw" / filename).write_text(
                f"P42_BENCH arm={arm} producers={p} workers={w} "
                f"tasks={TASKS} elapsed_us={value}\n", encoding="utf-8"
            )
            rows.append((session, pair, cost, scenario, arm, p, w, TASKS, value))
        with (root / "results.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.writer(file)
            writer.writerow(FIELDS)
            writer.writerows(rows)
        samples = load_capture(root)
        paired, sessions = analyze(samples)
        assert len(samples) == 288 and len(paired) == 144 and len(sessions) == 12
        first = root / "raw" / "s1-p1-light-target-conditional.txt"
        original = first.read_text()
        for bad in (
            original.replace("workers=4", "workers=3"),
            original.replace("elapsed_us=1021", "elapsed_us=0"),
            original.replace("arm=conditional", "arm=baseline"),
            original + original,
        ):
            first.write_text(bad, encoding="utf-8")
            try:
                load_capture(root)
            except ValueError:
                pass
            else:
                raise AssertionError("malformed benchmark raw sample accepted")
        first.write_text(original, encoding="utf-8")
        # CSV must not silently diverge from source logs.
        csv_file = root / "results.csv"
        original_csv = csv_file.read_text()
        # The synthetic values begin at 1011; corrupt one known sample.
        csv_file.write_text(original_csv.replace("1011", "9999", 1))
        try:
            load_capture(root)
        except ValueError:
            pass
        else:
            raise AssertionError("CSV/raw divergence accepted")
        # Explicit negative: the parser must reject an AB/BA order reversal,
        # even when all raw contents and individual CSV rows remain valid.
        csv_file.write_text(original_csv, encoding="utf-8")
        lines = original_csv.splitlines()
        lines[1], lines[2] = lines[2], lines[1]
        csv_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        try:
            load_capture(root)
        except ValueError:
            pass
        else:
            raise AssertionError("unbalanced execution-order control accepted")
    print("P42_E2E_ANALYZE_SELF_TEST_PASS")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: m1_p42_e2e_analyze.py EXISTING-RESULTS-DIR")
    root = Path(sys.argv[1])
    rows = load_capture(root)
    paired, sessions = analyze(rows)
    with (root / "paired.csv").open("x", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(("session", "pair", "cost", "scenario", "baseline_us",
                         "conditional_us", "conditional_minus_baseline_us",
                         "conditional_minus_baseline_pct"))
        writer.writerows(paired)
    with (root / "sessions.csv").open("x", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(("session", "cost", "target_median_delta_pct",
                         "control_median_delta_pct",
                         "median_pairwise_target_minus_control_pp",
                         "target_conditional_faster_pairs",
                         "control_conditional_faster_pairs",
                         "min_target_delta_pct", "max_target_delta_pct"))
        writer.writerows(sessions)
    print(f"P42_E2E_ANALYZE_PASS raw={len(rows)} pairs={len(paired)} "
          f"sessions={len(sessions)}")
    print("P42_E2E_NO_AUTOMATIC_PERFORMANCE_APPROVAL")


if __name__ == "__main__":
    main()
