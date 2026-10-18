#!/usr/bin/env python3
"""Fail-closed P42.19 XPS coretemp admission and thermal trace auditor.

The sensor reports a *snapshot* only: pre/post values do not prove absence
of in-run thermal excursions. No governor or affinity settings are changed.
"""
import csv
from datetime import datetime, timezone
from pathlib import Path
import sys
import time

# Pre-registered boundaries. All raw evidence survives a safety abort.
READY_MILLIC = 70_000
POST_ABORT_MILLIC = 95_000
STABLE_READINGS = 2
SAMPLE_SECONDS = 3
MAX_COOL_SECONDS = 600
COLUMNS = ("event", "run_id", "utc", "temp_mc")


def discover(root=Path("/sys/class/hwmon")):
    """Select the Intel coretemp CPU-package sensor, never an arbitrary zone."""
    matches = []
    for node in sorted(root.glob("hwmon*")):
        name = node / "name"
        if not name.is_file() or name.read_text().strip() != "coretemp":
            continue
        for label in sorted(node.glob("temp*_label")):
            if label.read_text().strip() == "Package id 0":
                sensor = label.with_name(label.name.replace("_label", "_input"))
                if sensor.is_file():
                    matches.append(sensor)
    if len(matches) != 1:
        raise ValueError(f"expected one coretemp Package id 0 sensor; got {len(matches)}")
    return matches[0]


def temp_mc(sensor):
    try:
        value = int(sensor.read_text().strip())
    except (OSError, ValueError) as err:
        raise ValueError("cannot read pinned coretemp package sensor") from err
    if not 0 < value < 125_000:
        raise ValueError("implausible CPU package temperature: " + str(value))
    return value


def write_event(csv_path, event, run_id, value):
    with csv_path.open("a", newline="", encoding="utf-8") as target:
        csv.writer(target).writerow(
            (event, run_id, datetime.now(timezone.utc).isoformat(), value)
        )


def cool(sensor, csv_path, run_id):
    """Require two low samples separated in time before EACH arm process."""
    deadline = time.monotonic() + MAX_COOL_SECONDS
    streak = 0
    while True:
        value = temp_mc(sensor)
        write_event(csv_path, "probe", run_id, value)
        streak = streak + 1 if value <= READY_MILLIC else 0
        if streak >= STABLE_READINGS:
            write_event(csv_path, "ready", run_id, value)
            print(f"P42_COOL_READY run={run_id} temp_mC={value}")
            return
        if time.monotonic() >= deadline:
            raise ValueError(
                f"cooldown timeout at run={run_id} temp_mC={value}; "
                "retain incomplete evidence; do not discard failed runs"
            )
        time.sleep(SAMPLE_SECONDS)


def post(sensor, csv_path, run_id):
    value = temp_mc(sensor)
    write_event(csv_path, "post", run_id, value)
    print(f"P42_POST_TEMP run={run_id} temp_mC={value}")
    if value >= POST_ABORT_MILLIC:
        raise ValueError(
            f"package post-run temperature >= {POST_ABORT_MILLIC} mC; "
            "abort without asserting thermal qualification"
        )


def expected_ids():
    from m1_p42_e2e_analyze import planned_order
    return [f"s{s}-p{p}-{cost}-{scenario}-{arm}"
            for s, p, cost, scenario, arm in planned_order()]


def audit(csv_path):
    """Reject thermal omissions, policy breaches and reordered run IDs."""
    ids = expected_ids()
    with csv_path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if tuple(reader.fieldnames or ()) != COLUMNS:
            raise ValueError("unexpected P42 thermal trace schema")
        rows = list(reader)
    completed = []
    position = 0
    states = {run_id: 0 for run_id in ids}
    probe_counts = {run_id: 0 for run_id in ids}
    ready_counts = {run_id: 0 for run_id in ids}
    last_timestamp = None
    for row in rows:
        key, event = row["run_id"], row["event"]
        if position == len(ids) or key != ids[position]:
            raise ValueError("thermal run order/extra run mismatch")
        if event not in ("probe", "ready", "post"):
            raise ValueError("invalid thermal event: " + event)
        moment = datetime.fromisoformat(row["utc"])
        if moment.tzinfo is None:
            raise ValueError("thermal sample without timezone")
        if last_timestamp is not None and moment < last_timestamp:
            raise ValueError("nonmonotonic thermal event time")
        last_timestamp = moment
        value = int(row["temp_mc"])
        if not 0 < value < 125_000:
            raise ValueError("implausible thermal sample")
        stage = states[key]
        if event == "probe" and stage == 0:
            probe_counts[key] += 1
        elif event == "ready" and stage == 0:
            if value > READY_MILLIC or probe_counts[key] < STABLE_READINGS:
                raise ValueError("invalid cooldown admission " + key)
            ready_counts[key] += 1
            states[key] = 1
        elif event == "post" and stage == 1:
            if value >= POST_ABORT_MILLIC:
                raise ValueError("thermal abort boundary exceeded " + key)
            states[key] = 2
            completed.append(key)
            position += 1
        else:
            raise ValueError("misordered or duplicated thermal event " + key)
    if position != len(ids) or any(states[k] != 2 or ready_counts[k] != 1 for k in ids):
        raise ValueError(f"incomplete thermal capture: {position}/{len(ids)}")
    print(f"P42_THERMAL_AUDIT_PASS runs={len(completed)} "
          f"ready_le_mC={READY_MILLIC} post_lt_mC={POST_ABORT_MILLIC}")


def self_test():
    from tempfile import TemporaryDirectory
    with TemporaryDirectory(prefix="p42-thermal-") as tmp:
        root = Path(tmp)
        device = root / "hwmon0"
        device.mkdir()
        (device / "name").write_text("coretemp\n")
        (device / "temp1_label").write_text("Package id 0\n")
        sensor = device / "temp1_input"
        sensor.write_text("65000\n")
        assert discover(root) == sensor
        assert temp_mc(sensor) == 65000
        sensor.write_text("190000\n")
        try:
            temp_mc(sensor)
        except ValueError:
            pass
        else:
            raise AssertionError("implausible temperature accepted")
        sensor.write_text("65000\n")
        trace = root / "thermal.csv"
        with trace.open("w", newline="", encoding="utf-8") as file:
            csv.writer(file).writerow(COLUMNS)
        for run_id in expected_ids():
            for event, temperature in (("probe", 68000), ("probe", 65000),
                                       ("ready", 65000), ("post", 73000)):
                write_event(trace, event, run_id, temperature)
        audit(trace)
        original = trace.read_text()
        corruptions = (
            original.replace(",ready,", ",bad_event,", 1),
            original.replace(",ready,", ",ready,", 1).replace(",65000\n", ",85000\n", 1),
            original.replace(",post,", ",probe,", 1),
            original.replace(",post,", ",post,", 1).replace(",73000\n", ",95000\n", 1),
            "\n".join(original.splitlines()[:-1]) + "\n",
        )
        for corrupt in corruptions:
            trace.write_text(corrupt)
            try:
                audit(trace)
            except ValueError:
                pass
            else:
                raise AssertionError("corrupt thermal trace accepted")
    print("P42_THERMAL_SELF_TEST_PASS")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(sys.argv) == 2 and sys.argv[1] == "discover":
        print(discover())
        return
    if len(sys.argv) == 2 and sys.argv[1] == "audit":
        raise SystemExit("usage: thermal_guard.py audit TRACE_CSV")
    if len(sys.argv) == 3 and sys.argv[1] == "audit":
        audit(Path(sys.argv[2]))
        return
    if len(sys.argv) == 5 and sys.argv[1] in ("cool", "post"):
        mode, sensor, csv_path, run_id = sys.argv[1:]
        sensor, csv_path = Path(sensor), Path(csv_path)
        if not run_id or "," in run_id:
            raise ValueError("invalid run ID")
        (cool if mode == "cool" else post)(sensor, csv_path, run_id)
        return
    raise SystemExit(
        "usage: thermal_guard.py --self-test | discover | "
        "audit TRACE_CSV | (cool|post) SENSOR TRACE_CSV RUN_ID"
    )


if __name__ == "__main__":
    main()
