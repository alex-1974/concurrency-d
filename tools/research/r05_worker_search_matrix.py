#!/usr/bin/env python3
"""R0.5 worker-local missed-steal/park search trace versus untraced control.

Diagnostic evidence only. Trace adds worker-local monotonic-time sampling,
while the baseline does not. No trace mutex, task-record changes or timing gate.
"""
import argparse
import csv
from pathlib import Path
import platform
import statistics
import subprocess

import r05_batch_size_ab as baseline


SIZES = (8, 1)
KINDS = {"localPop", "ingressClaim", "stealMiss", "stealHit",
         "searchEmpty", "parkCheck", "parkReturn", "drained"}
NAMES = {
    8: ("concurrency-burst-head-of-line",
        "concurrency-burst-head-of-line-search-batch8"),
    1: ("concurrency-burst-head-of-line-batch1",
        "concurrency-burst-head-of-line-search-batch1"),
}
CONFIGS = {
    8: ("burst-head-of-line-benchmark",
        "burst-head-of-line-search-batch8"),
    1: ("burst-head-of-line-batch1",
        "burst-head-of-line-search-batch1"),
}


def parse_case(rows, blockers, batch):
    top = baseline.one(rows, "burst", baseline.BURST)
    if (top["blockers"] != str(blockers) or
            top["workers"] != "4" or
            top["siblings"] != "8" or
            top["claimed_tasks"] != str(blockers + 8)):
        raise RuntimeError("bad burst summary/accounting")

    c = {}
    for row in rows:
        if row and row[0] == "control":
            if len(row) != 3 or row[1] in c:
                raise RuntimeError("bad control row")
            c[row[1]] = int(row[2])
    if set(c) != {"gateRelease", "joined"}:
        raise RuntimeError("missing control events")
    gate = c["gateRelease"]
    if gate <= 0 or c["joined"] < gate:
        raise RuntimeError("bad gate/join chronology")

    blockers_data = [r for r in rows if r and r[0] == "task"]
    sibling_data = [r for r in rows if r and r[0] == "sibling"]
    claim_data = [r for r in rows if r and r[0] == "claim"]
    if (len(blockers_data) != blockers or len(sibling_data) != 8 or
            len(claim_data) != 4):
        raise RuntimeError("missing blocker, sibling or claim rows")
    if (sorted(int(r[1]) for r in blockers_data) !=
            list(range(blockers)) or
            sorted(int(r[1]) for r in sibling_data) != list(range(8)) or
            sorted(int(r[1]) for r in claim_data) != list(range(4))):
        raise RuntimeError("duplicate/missing ID")
    if sum(int(r[3]) for r in claim_data) != blockers + 8:
        raise RuntimeError("claim conservation mismatch")
    if sum(int(r[7]) for r in claim_data) != blockers + 8:
        raise RuntimeError("execution conservation mismatch")

    blocker_starts = [
        (int(r[3]), int(r[4])) for r in blockers_data]
    if any(not 0 <= worker < 4 or start < 0
           for worker, start in blocker_starts):
        raise RuntimeError("invalid blocker startup")
    active_blockers = {w for w, t in blocker_starts if t < gate}
    final_start = max(t for _, t in blocker_starts)
    if (final_start < gate and len(active_blockers) != blockers):
        raise RuntimeError("concurrent blockers share a worker")
    siblings_before = sum(int(r[4]) < gate for r in sibling_data)
    return dict(batch=batch, blockers=blockers,
                gate_release_ns=gate, final_blocker_start_ns=final_start,
                all_blockers_before_gate=int(final_start < gate),
                sibling_pre_gate=siblings_before,
                free_workers=sorted(set(range(4)) - active_blockers),
                blocked_workers=sorted(active_blockers))


def parse_search(rows, gate):
    status = [r for r in rows if r and r[0] == "search_status"]
    raw = [r for r in rows if r and r[0] == "search"]
    if len(status) != 1 or len(status[0]) != 5:
        raise RuntimeError("missing worker search status")
    workers, count, lost, capacity = map(int, status[0][1:])
    if workers != 4 or count != len(raw) or lost or capacity < 16:
        raise RuntimeError("worker search trace overflow/incompleteness")
    events = []
    previous = {}  # each worker's log is sequenced; cross-worker isn't
    pending_park = {i: None for i in range(workers)}
    for r in raw:
        if len(r) != 6:
            raise RuntimeError("malformed worker search row")
        kind = r[1].split(".")[-1]
        worker, victim, detail, ns = map(int, r[2:])
        if kind not in KINDS or not 0 <= worker < 4:
            raise RuntimeError("bad worker search event kind/worker")
        if (kind in ("stealMiss", "stealHit") and
                (not 0 <= victim < 4 or victim == worker)):
            raise RuntimeError("invalid steal victim")
        if kind == "ingressClaim" and not 1 <= detail <= 8:
            raise RuntimeError("invalid claimed batch size")
        if kind == "parkReturn" and detail not in (0, 1):
            raise RuntimeError("invalid real-wait classification")
        if worker in previous and ns < previous[worker]:
            raise RuntimeError("non-monotonic worker-local event timestamps")
        previous[worker] = ns
        # Uniform event schema is required for csv.DictWriter regardless
        # of whether the first event happens to be a park return.
        event = dict(worker=worker, kind=kind, victim=victim,
                     detail=detail, offset_ns=ns,
                     before_gate=int(ns < gate),
                     park_duration_ns=0, park_spanned_gate=0)
        if kind == "parkCheck":
            if pending_park[worker] is not None:
                raise RuntimeError("nested park checks")
            pending_park[worker] = ns
        if kind == "parkReturn":
            begin = pending_park[worker]
            if begin is None or ns < begin:
                raise RuntimeError("park return without check")
            event["park_duration_ns"] = ns - begin
            event["park_spanned_gate"] = int(
                detail == 1 and begin < gate <= ns)
            pending_park[worker] = None
        events.append(event)
    if any(pending_park[x] is not None for x in pending_park):
        raise RuntimeError("park check without return after join")
    return events


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compiler", default="ldc2")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--burst-ms", type=int, default=100)
    p.add_argument("--blockers", nargs="+", type=int, default=[3, 4])
    p.add_argument("--policies", nargs="+", choices=("gc", "recycle"),
                   default=["gc", "recycle"])
    p.add_argument("--notify", nargs="+", choices=("always", "waiter"),
                   default=["always", "waiter"])
    p.add_argument("--output", type=Path,
                   default=Path("evidence/r05-worker-search"))
    a = p.parse_args()
    if (platform.system() != "Linux" or
            not 1 <= a.rounds <= 20 or
            not 10 <= a.burst_ms <= 2000 or
            not a.blockers or any(b not in (3, 4) for b in a.blockers)):
        p.error("invalid worker-search parameters")
    for setting in (a.blockers, a.policies, a.notify):
        if len(setting) != len(set(setting)):
            p.error("duplicate independent factor")

    root = Path(__file__).resolve().parents[2]
    for batch in SIZES:
        for config in CONFIGS[batch]:
            subprocess.run(
                ["dub", "build", "--config=" + config,
                 "--build=release", "--compiler=" + a.compiler, "--force"],
                cwd=root, check=True)
        for executable in NAMES[batch]:
            if not (root / executable).is_file():
                raise RuntimeError("missing compiled " + executable)

    a.output.mkdir(parents=True, exist_ok=True)
    cases, events_out, workers_out = [], [], []
    for rnd in range(a.rounds):
        for storage in a.policies:
            for notify in a.notify:
                for blockers in a.blockers:
                    for batch in SIZES:
                        # Alternate traced/untraced order within each case.
                        order = (0, 1) if (
                            rnd + blockers + batch + (storage == "recycle") +
                            (notify == "waiter")) % 2 else (1, 0)
                        measures = {}
                        worker_events = None
                        for mode in order:
                            exe = root / NAMES[batch][mode]
                            rows, resources = baseline.run_child(
                                [str(exe), notify, storage, "4",
                                 str(blockers), "8", str(a.burst_ms)], root)
                            data = parse_case(rows, blockers, batch)
                            measures[mode] = (data, resources)
                            if mode == 1:
                                worker_events = parse_search(
                                    rows, data["gate_release_ns"])
                        normal = measures[0][0]
                        traced = measures[1][0]
                        gate = traced["gate_release_ns"]
                        start = traced["final_blocker_start_ns"]
                        free = traced["free_workers"]
                        # Analyze spare worker(s) only when all blockers
                        # started before external release; otherwise report
                        # as an incomplete saturation control.
                        fully_started = traced["all_blockers_before_gate"]
                        free_valid = free if fully_started else []
                        total_miss = total_hit = total_park = total_long = 0
                        for worker in range(4):
                            per_worker = [e for e in worker_events
                                          if e["worker"] == worker]
                            relevant = [
                                e for e in per_worker
                                if start <= e["offset_ns"] < gate]
                            misses = sum(
                                e["kind"] == "stealMiss" for e in relevant)
                            hits = sum(
                                e["kind"] == "stealHit" for e in relevant)
                            parks = sum(
                                e["kind"] == "parkCheck" for e in relevant)
                            spanning = sum(
                                e["kind"] == "parkReturn" and
                                e.get("park_spanned_gate", 0) for e in per_worker)
                            if worker in free_valid:
                                total_miss += misses
                                total_hit += hits
                                total_park += parks
                                total_long += spanning
                            workers_out.append(dict(
                                round=rnd, batch=batch, storage=storage,
                                notify=notify, blockers=blockers,
                                worker=worker,
                                blocked_at_final_start=int(
                                    worker not in free and fully_started),
                                spare_worker=int(worker in free_valid),
                                steal_misses_in_window=misses,
                                steal_hits_in_window=hits,
                                park_checks_in_window=parks,
                                park_spanned_gate=spanning))
                            for e in per_worker:
                                e.update(round=rnd, batch=batch,
                                         storage=storage, notify=notify,
                                         blockers=blockers)
                                events_out.append(e)
                        cases.append(dict(
                            round=rnd, batch=batch, storage=storage,
                            notify=notify, blockers=blockers,
                            untraced_before_gate=normal["sibling_pre_gate"],
                            traced_before_gate=traced["sibling_pre_gate"],
                            untraced_free_workers=len(normal["free_workers"]),
                            traced_free_workers=len(free_valid),
                            all_blockers_started_before_gate=fully_started,
                            spare_steal_misses=total_miss,
                            spare_steal_hits=total_hit,
                            spare_park_checks=total_park,
                            spare_parks_spanning_gate=total_long,
                            trace_events=len(worker_events),
                            untraced_child_wall_ns=measures[0][1][
                                "child_wall_ns"],
                            traced_child_wall_ns=measures[1][1][
                                "child_wall_ns"]))
                        print(f"search r={rnd} b={batch} {storage}/{notify} "
                              f"blockers={blockers} sibling pre-gate "
                              f"off={normal['sibling_pre_gate']} "
                              f"on={traced['sibling_pre_gate']} "
                              f"spare misses={total_miss} parks={total_park} "
                              f"spanning={total_long}", flush=True)

    baseline.write_csv(a.output / "cases.csv", cases)
    baseline.write_csv(a.output / "workers.csv", workers_out)
    baseline.write_csv(a.output / "events.csv", events_out)
    summary = []
    for batch in SIZES:
        for storage in a.policies:
            for notify in a.notify:
                for blockers in a.blockers:
                    group = [r for r in cases if r["batch"] == batch and
                             r["storage"] == storage and
                             r["notify"] == notify and
                             r["blockers"] == blockers]
                    if len(group) != a.rounds:
                        raise RuntimeError("missing search control pairing")
                    summary.append(dict(
                        batch=batch, storage=storage, notify=notify,
                        blockers=blockers, rounds=a.rounds,
                        fully_started=sum(
                            r["all_blockers_started_before_gate"]
                            for r in group),
                        median_untraced_pre_gate=statistics.median(
                            r["untraced_before_gate"] for r in group),
                        median_traced_pre_gate=statistics.median(
                            r["traced_before_gate"] for r in group),
                        median_spare_misses=statistics.median(
                            r["spare_steal_misses"] for r in group),
                        median_spare_parks=statistics.median(
                            r["spare_park_checks"] for r in group),
                        spare_park_spanned_gate_total=sum(
                            r["spare_parks_spanning_gate"] for r in group)))
    baseline.write_csv(a.output / "summary.csv", summary)
    with (a.output / "environment.txt").open("w") as fd:
        fd.write(f"platform={platform.platform()}\ncompiler={a.compiler}\n"
                 f"rounds={a.rounds} blockers={a.blockers} "
                 f"burst_ms={a.burst_ms} batches={SIZES}\n"
                 "Worker-local timestamps are observation times; "
                 "no global serial trace order.\n"
                 "Tracing changes scheduler timing; paired normal cases "
                 "are a perturbation control, not throughput data.\n")
        for cmd in (["git", "rev-parse", "HEAD"], [a.compiler, "--version"],
                    ["lscpu"]):
            fd.write("$ " + " ".join(cmd) + "\n")
            try:
                fd.write(subprocess.run(cmd, cwd=root, capture_output=True,
                    text=True, check=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                fd.write("unavailable\n")
    print("R0.5 worker search: diagnostics only; no scheduler promotion")
    print("evidence: " + str(a.output))


if __name__ == "__main__":
    main()
