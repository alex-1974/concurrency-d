#!/usr/bin/env python3
"""Audit original R0.5 XPS victim-search traces without running D code.

The record is per-worker ordered, never a globally synchronized event log.
This script computes completed unsuccessful search sequences, not CPU timing
or a queue-emptiness guarantee. No scheduler instrumentation is introduced.

Example:
  python3 tools/research/r05_victim_repeat_trace_audit.py \\
    --archive r05-xps-victim-sweep.tar.gz \\
    --output victim-repeat-summary.csv
"""
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import io
from pathlib import Path
import tarfile

ARCHIVE_SHA256 = "46653953b304ff5567f8656a693acb30e4bc11ba993afa22358e7b43172cc111"
MEMBER = "r05-xps-victim-sweep/worker_search_events.csv"
KEYS = ("variant", "round", "storage", "notify", "blockers", "worker")
SUCCESSES = {"ingressClaim", "localPop", "stealHit"}
VARIANTS = {"old", "full"}


def check_cursor_model():
    """Candidate positions versus actual foreign probes, all worker IDs."""
    missed = 0
    for workers in (2, 3, 4, 5, 8, 16, 32):
        for owner in range(workers):
            foreign = set(range(workers)) - {owner}
            for start in range(workers):
                old = [((start + i) % workers)
                       for i in range(workers - 1)
                       if (start + i) % workers != owner]
                full = [((start + i) % workers)
                        for i in range(workers)
                        if (start + i) % workers != owner]
                if len(old) != len(foreign):
                    missed += 1
                assert len(full) == len(foreign)
                assert len(set(full)) == len(full)
                assert set(full) == foreign
            for start in range(workers):
                full = [((start + i) % workers)
                        for i in range(workers)
                        if (start + i) % workers != owner]
                repeated = [((start + workers + i) % workers)
                            for i in range(workers)
                            if (start + workers + i) % workers != owner]
                assert full == repeated
    assert missed > 0


def audit_worker(key, events, workers=4):
    """Parse only worker-local events; count pairs of empty searches."""
    variant = key[0]
    owner = int(key[-1])
    expected = workers - 1
    current = []
    prev_empty = None
    success_between = False
    prev_tick = None
    counters = Counter()
    for event in events:
        tick = int(event["offset_ns"])
        if prev_tick is not None and tick < prev_tick:
            raise ValueError("nonmonotonic worker-local trace")
        prev_tick = tick
        kind = event["kind"]
        if kind in SUCCESSES:
            if kind == "stealHit":
                victim = int(event["victim"])
                if victim == owner or not 0 <= victim < workers:
                    raise ValueError("invalid successful victim")
            if prev_empty is not None:
                success_between = True
            current.clear()
        elif kind == "stealMiss":
            victim = int(event["victim"])
            if victim == owner or not 0 <= victim < workers:
                raise ValueError("invalid missed victim")
            current.append(victim)
        elif kind == "searchEmpty":
            if not current or len(current) != len(set(current)):
                raise ValueError("empty search has missing or duplicate victim")
            if variant == "full":
                if len(current) != expected or set(current) != (
                        set(range(workers)) - {owner}):
                    raise ValueError("full search skipped a victim")
            elif len(current) not in (expected, expected - 1):
                raise ValueError("unexpected old candidate search length")
            counters["empty_scans"] += 1
            if len(current) < expected:
                counters["omitted_foreign"] += 1
            candidate = tuple(current)
            if prev_empty is not None:
                counters["pairs_of_empty_scans"] += 1
                if success_between:
                    counters["pairs_with_success_between"] += 1
                else:
                    counters["success_free_pairs"] += 1
                    if candidate == prev_empty:
                        counters["same_order"] += 1
                    else:
                        counters["different_order"] += 1
            prev_empty = candidate
            success_between = False
            current.clear()
    return counters


def read_original(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != ARCHIVE_SHA256:
        raise ValueError("original evidence SHA256 mismatch: " + digest)
    with tarfile.open(path, "r:gz") as archive:
        member = archive.getmember(MEMBER)
        if not member.isfile():
            raise ValueError("not a regular raw trace CSV")
        with archive.extractfile(member) as binary:
            rows = list(csv.DictReader(io.TextIOWrapper(binary, encoding="utf-8")))
    if len(rows) != 4110:
        raise ValueError("expected 4,110 canonical trace events")
    if not all(row["variant"] in VARIANTS for row in rows):
        raise ValueError("unexpected search variant")
    return rows


def summarize(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[tuple(row[k] for k in KEYS)].append(row)
    results = {"old": Counter(), "full": Counter()}
    for key, events in groups.items():
        results[key[0]].update(audit_worker(key, events))
    if len(groups) != 320:
        raise ValueError("expected 320 worker-local trace streams")
    # Guard against confusing interrupted failure sequences with
    # uninterrupted searches when work *did* arrive between them.
    expect = {
        "old": (278, 211, 102, 0, 102),
        "full": (271, 0, 100, 100, 0),
    }
    for mode, (empty, omitted, pairs, same, different) in expect.items():
        c = results[mode]
        if (c["empty_scans"], c["omitted_foreign"],
            c["success_free_pairs"], c["same_order"],
            c["different_order"]) != (empty, omitted, pairs, same, different):
            raise ValueError("native source trace count changed: " + mode)
    return results


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--archive", type=Path)
    p.add_argument("--output", type=Path)
    a = p.parse_args()
    check_cursor_model()
    if a.archive is None:
        if a.output is not None:
            p.error("--output requires --archive")
        print("PASS: candidate coverage and same-start model")
        return
    summary = summarize(read_original(a.archive))
    fields = ("variant", "empty_scans", "omitted_foreign",
              "pairs_of_empty_scans", "pairs_with_success_between",
              "success_free_pairs", "same_order", "different_order")
    records = [dict(variant=key, **{k: summary[key][k] for k in fields[1:]})
               for key in ("old", "full")]
    if a.output:
        a.output.parent.mkdir(parents=True, exist_ok=True)
        with a.output.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows(records)
    for record in records:
        print(record)
    print("PASS: pinned native trace replay and per-worker conservation")


if __name__ == "__main__":
    main()
