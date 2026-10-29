#!/usr/bin/env python3
"""Run repeated local batch-size/task-cost sweeps and retain raw CSV."""

import csv
import hashlib
import json
import os
import pathlib
import platform
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None
DC = os.environ.get("DC", "ldc2")
ITEMS = int(os.environ.get("ITEMS", "2048"))
WORKERS = int(os.environ.get("WORKERS", "4"))
SESSIONS = int(os.environ.get("SESSIONS", "3"))
SAMPLES = int(os.environ.get("SAMPLES", "7"))
WARMUPS = int(os.environ.get("WARMUPS", "2"))
ITERATIONS = tuple(map(int, os.environ.get("ITERATIONS", "0,8,64").split(",")))
HOT_ITEMS = int(os.environ.get("HOT_ITEMS", str(max(1, ITEMS // 16))))
EXTRA_ITERATIONS = int(os.environ.get("EXTRA_ITERATIONS", "64"))
LAYOUTS = ("clustered", "scattered", "single")


def run(command, cwd=ROOT):
    return subprocess.run(command, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT).stdout


def percentile(values, fraction):
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1,
                       int((len(ordered) * fraction + 0.999999)) - 1))
    return ordered[index]


def main():
    if OUT is None:
        raise SystemExit("usage: capture_batch_tuning.py OUTPUT_DIRECTORY")
    if OUT.exists():
        raise SystemExit(f"output directory already exists: {OUT}")
    if min(ITEMS, WORKERS, SESSIONS, SAMPLES) < 1 or WARMUPS < 0:
        raise SystemExit("invalid capture dimensions")
    if HOT_ITEMS < 1 or ITEMS % HOT_ITEMS:
        raise SystemExit("HOT_ITEMS must be positive and divide ITEMS")
    if EXTRA_ITERATIONS * HOT_ITEMS > 100_000:
        raise SystemExit("single-outlier work must not exceed 100,000 iterations")
    OUT.mkdir(parents=True)

    build_log = run(["dub", "build", "--root=benchmarks/batch-tuning",
                     f"--compiler={DC}", "--build=release", "--force"])
    (OUT / "build.log").write_text(build_log)
    binary = ROOT / "benchmarks/batch-tuning/concurrency-batch-tuning-benchmark"
    if not binary.is_file():
        raise RuntimeError(f"missing benchmark binary: {binary}")

    modes = ((1, ITEMS, ITEMS, "unbounded"),
             (4, ITEMS, ITEMS, "unbounded"),
             (4, 256, 512, "bounded-256-512"))
    metadata = {
        "status": "IN_PROGRESS",
        "commit": run(["git", "rev-parse", "HEAD"]).strip(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "method": (f"{SESSIONS} independent process sessions; {SAMPLES} "
                   f"measured plus {WARMUPS} warmups; {ITEMS} items; "
                   f"{WORKERS} executor workers; base recurrence counts "
                   f"{ITERATIONS}; {HOT_ITEMS} hot items receive "
                   f"{EXTRA_ITERATIONS} extra recurrences in clustered/"
                   f"scattered layouts; single concentrates the same total "
                   f"extra work into one item; layouts={LAYOUTS}; "
                   f"producers/capacity modes {modes}; grains "
                   "1,4,16,64,256; checksum verified every sample; producer "
                   "thread startup/join included for four-producer cases"),
        "machine": platform.uname()._asdict(),
        "cpuinfo": pathlib.Path("/proc/cpuinfo").read_text(),
        "lscpu": run(["lscpu"]),
        "compiler": run([DC, "--version"]),
        "dub": run(["dub", "--version"]),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    raw_rows = []
    accepted_grains = (1, 4, 16, 64, 256)
    def skew_checksum(iterations, layout):
        mask = (1 << 64) - 1
        total = 0
        stride = ITEMS // HOT_ITEMS
        for index in range(ITEMS):
            if layout == "single":
                extra = HOT_ITEMS * EXTRA_ITERATIONS if index == 0 else 0
            else:
                hot = (index < HOT_ITEMS if layout == "clustered" else
                       index % stride == 0 and index // stride < HOT_ITEMS)
                extra = EXTRA_ITERATIONS if hot else 0
            count = iterations + extra
            value = index + 1
            for iteration in range(count):
                value = (value * 6364136223846793005 + iteration +
                         1442695040888963407) & mask
            total = (total + value) & mask
        return total

    checksums = {(iterations, layout): skew_checksum(iterations, layout)
                 for iterations in ITERATIONS for layout in LAYOUTS}
    for producer, ingress, retained, capacity_mode in modes:
        for iterations in ITERATIONS:
            for layout in LAYOUTS:
                for session in range(1, SESSIONS + 1):
                    command = [str(binary), str(SAMPLES), str(WARMUPS),
                               str(ITEMS), str(WORKERS), str(producer),
                               str(ingress), str(retained), str(iterations),
                               str(HOT_ITEMS), str(EXTRA_ITERATIONS), layout]
                    stdout = run(command)
                    path = OUT / (f"p{producer}-{capacity_mode}-i{iterations}-"
                                  f"{layout}-session{session}.csv")
                    path.write_text(stdout)
                    with path.open(newline="") as stream:
                        rows = list(csv.DictReader(stream))
                    valid = set()
                    for grain in accepted_grains:
                        tasks = (ITEMS + grain - 1) // grain
                        largest = (tasks + producer - 1) // producer
                        if largest <= min(ingress, retained):
                            valid.add(grain)
                    if (not rows or
                            {int(row["grain"]) for row in rows} != valid):
                        raise RuntimeError(f"unexpected grain set in {path}")
                    expected_rows = (SAMPLES + WARMUPS) * len(valid)
                    if len(rows) != expected_rows:
                        raise RuntimeError(f"unexpected row count in {path}")
                    seen = set()
                    for row in rows:
                        sample = int(row["sample"])
                        grain = int(row["grain"])
                        key = (sample, grain)
                        if key in seen:
                            raise RuntimeError(
                                f"duplicate sample in {path}: {key}")
                        seen.add(key)
                        if row["phase"] != ("warmup" if sample < WARMUPS
                                             else "measure"):
                            raise RuntimeError(f"phase mismatch in {path}")
                        if (int(row["checksum"]) !=
                                checksums[iterations, layout] or
                                int(row["total_ns"]) <= 0 or
                                int(row["items"]) != ITEMS or
                                int(row["workers"]) != WORKERS or
                                int(row["iterations"]) != iterations or
                                int(row["hot_items"]) != HOT_ITEMS or
                                int(row["effective_extra_iterations"]) !=
                                (HOT_ITEMS * EXTRA_ITERATIONS
                                 if layout == "single" else
                                 EXTRA_ITERATIONS) or
                                row["layout"] != layout or
                                int(row["producers"]) != producer or
                                int(row["ingress"]) != ingress or
                                int(row["retained"]) != retained or
                                int(row["tasks"]) !=
                                (ITEMS + grain - 1) // grain):
                            raise RuntimeError(f"result mismatch in {path}")
                        raw_rows.append({"session": session,
                                         "capacity_mode": capacity_mode,
                                         "layout": layout,
                                         **row})

    with (OUT / "observations.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(raw_rows[0]))
        writer.writeheader()
        writer.writerows(raw_rows)

    per_session = {}
    for row in raw_rows:
        if row["phase"] != "measure":
            continue
        key = (row["capacity_mode"], int(row["producers"]),
               int(row["iterations"]), row["layout"], int(row["grain"]),
               int(row["session"]))
        per_session.setdefault(key, []).append(int(row["total_ns"]))

    grouped = {}
    session_rows = []
    for key, times in sorted(per_session.items()):
        p50, p95 = statistics.median(times), percentile(times, 0.95)
        capacity_mode, producer, iterations, layout, grain, session = key
        grouped.setdefault(key[:-1], []).append((p50, p95))
        session_rows.append({"capacity_mode": capacity_mode,
                             "producers": producer,
                             "iterations_per_item": iterations,
                             "layout": layout,
                             "grain": grain,
                             "session": session,
                             "samples": len(times),
                             "p50_ns": int(p50), "p95_ns": p95})
    with (OUT / "session-summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(session_rows[0]))
        writer.writeheader()
        writer.writerows(session_rows)

    summaries = []
    for key, values in sorted(grouped.items()):
        p50s, p95s = [item[0] for item in values], [item[1] for item in values]
        summaries.append({"capacity_mode": key[0], "producers": key[1],
                          "iterations_per_item": key[2], "layout": key[3],
                          "grain": key[4],
                          "sessions": len(values),
                          "median_session_p50_ns": int(statistics.median(p50s)),
                          "session_p50_min_ns": int(min(p50s)),
                          "session_p50_max_ns": int(max(p50s)),
                          "median_session_p95_ns": int(statistics.median(p95s)),
                          "session_p95_min_ns": int(min(p95s)),
                          "session_p95_max_ns": int(max(p95s))})
    with (OUT / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)

    metadata["status"] = "PASS"
    metadata["completed_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                               time.gmtime())
    (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print((OUT / "summary.csv").read_text(), end="")


if __name__ == "__main__":
    main()
