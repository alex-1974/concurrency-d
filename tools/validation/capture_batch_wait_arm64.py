#!/usr/bin/env python3
"""Paired native-ARM64 A/B capture for contiguous synchronous batch records."""

import csv
import io
import json
import os
import pathlib
import platform
import shutil
import statistics
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(os.environ.get("BATCH_WAIT_CAPTURE_DIR",
                                 "/tmp/batch-wait-arm64"))
BASELINE_REF = os.environ.get("BASELINE_REF", "c984da8")
SAMPLES = int(os.environ.get("SAMPLES", "15"))
WARMUPS = int(os.environ.get("WARMUPS", "5"))
SESSIONS = int(os.environ.get("SESSIONS", "4"))
ITEMS = int(os.environ.get("ITEMS", "16384"))
WORKERS = int(os.environ.get("WORKERS", "4"))
DC = os.environ.get("DC", "ldc2")
PRODUCERS = (1, 4)
GRAINS = (16, 64, 256)


def run(command, cwd=ROOT):
    return subprocess.run(command, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT).stdout


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1,
                              int((len(ordered) * fraction + 0.999999)) - 1))]


def build(tree, label):
    log = run(["dub", "build", f"--root={tree / 'benchmarks/batch-wait'}",
               f"--compiler={DC}", "--build=release", "--force"], cwd=tree)
    (OUT / f"build-{label}.log").write_text(log)
    binary = tree / "benchmarks/batch-wait/concurrency-batch-wait-benchmark"
    if not binary.is_file():
        raise RuntimeError(f"missing {label} benchmark binary: {binary}")
    return binary


def load_rows(path, sample_count, warmups, producer, items, workers,
              ingress, retained):
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    expected = (sample_count + warmups) * len(GRAINS)
    if len(rows) != expected:
        raise RuntimeError(f"{path}: expected {expected} rows, got {len(rows)}")
    seen = set()
    for row in rows:
        sample = int(row["sample"])
        grain = int(row["grain"])
        key = (sample, grain)
        if key in seen or grain not in GRAINS:
            raise RuntimeError(f"{path}: duplicate or unexpected sample {key}")
        seen.add(key)
        expected_phase = "warmup" if sample < warmups else "measure"
        if row["phase"] != expected_phase:
            raise RuntimeError(f"{path}: wrong phase at sample {sample}")
        if (int(row["workers"]) != workers or
                int(row["producers"]) != producer or
                int(row["items"]) != items or
                int(row["ingress"]) != ingress or
                int(row["retained"]) != retained):
            raise RuntimeError(f"{path}: benchmark dimensions changed")
        expected_checksum = items * (items + 1) // 2
        if int(row["checksum"]) != expected_checksum:
            raise RuntimeError(f"{path}: checksum mismatch")
        if int(row["total_ns"]) <= 0:
            raise RuntimeError(f"{path}: invalid elapsed time")
    return rows


def main():
    if platform.machine().lower() not in ("aarch64", "arm64"):
        raise SystemExit(f"native ARM64 required; got {platform.machine()}")
    if min(SAMPLES, SESSIONS, ITEMS, WORKERS) < 1 or WARMUPS < 0:
        raise SystemExit("invalid capture dimensions")
    if OUT.exists():
        raise SystemExit(f"output directory already exists: {OUT}")
    OUT.mkdir(parents=True)

    baseline_sha = run(["git", "rev-parse", f"{BASELINE_REF}^{{commit}}"])
    candidate_sha = run(["git", "rev-parse", "HEAD"])
    baseline_tree = pathlib.Path("/tmp/batch-wait-arm64-baseline")
    if baseline_tree.exists():
        shutil.rmtree(baseline_tree)
    baseline_tree.mkdir(parents=True)
    archive = subprocess.Popen(["git", "archive", baseline_sha.strip()],
                               cwd=ROOT, stdout=subprocess.PIPE)
    with archive.stdout as stream:
        import tarfile
        with tarfile.open(fileobj=stream, mode="r|") as tar:
            tar.extractall(baseline_tree, filter="data")
    if archive.wait() != 0:
        raise RuntimeError(f"git archive failed for {BASELINE_REF}")
    shutil.copytree(ROOT / "benchmarks/batch-wait",
                    baseline_tree / "benchmarks/batch-wait")
    trees = {"baseline": baseline_tree, "candidate": ROOT}
    binaries = {name: build(tree, name) for name, tree in trees.items()}
    metadata = {
        "status": "IN_PROGRESS",
        "baseline_ref": BASELINE_REF,
        "baseline_commit": baseline_sha.strip(),
        "candidate_commit": candidate_sha.strip(),
        "candidate_event_head": os.environ.get("GITHUB_EVENT_HEAD_SHA"),
        "binary_sha256": {
            name: __import__("hashlib").sha256(path.read_bytes()).hexdigest()
            for name, path in binaries.items()
        },
        "method": (f"{SESSIONS} alternating process-paired sessions; "
                   f"{SAMPLES} measured plus {WARMUPS} warmup samples; "
                   f"{ITEMS} one-store items; {WORKERS} workers; producers "
                   f"{PRODUCERS}; batch grains {GRAINS}; one executor reused "
                   "within each process; identical benchmark source compiled "
                   "against baseline and candidate; correctness checksum on "
                   "every sample; producer thread setup/join included for "
                   "four-producer calls"),
        "machine": platform.uname()._asdict(),
        "cpuinfo": pathlib.Path("/proc/cpuinfo").read_text(),
        "lscpu": run(["lscpu"]),
        "compiler": run([DC, "--version"]),
        "dub": run(["dub", "--version"]),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sessions": [],
    }
    (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    combined = []
    run_metadata = []
    for producer in PRODUCERS:
        ingress, retained = ((ITEMS, ITEMS) if producer == 1 else (256, 512))
        for session in range(1, SESSIONS + 1):
            order = (["baseline", "candidate"] if session % 2
                     else ["candidate", "baseline"])
            pair = {"session": session, "producers": producer,
                    "order": order, "runs": []}
            for variant in order:
                output_path = OUT / (
                    f"session-{session}-p{producer}-{variant}.csv")
                command = [str(binaries[variant]), str(SAMPLES), str(WARMUPS),
                           str(ITEMS), str(WORKERS), str(producer),
                           str(ingress), str(retained)]
                stdout = run(command, cwd=trees[variant])
                output_path.write_text(stdout)
                rows = load_rows(output_path, SAMPLES, WARMUPS, producer,
                                 ITEMS, WORKERS, ingress, retained)
                for row in rows:
                    combined.append({"session": session,
                                     "variant": variant, **row})
                pair["runs"].append({"variant": variant,
                                     "command": command,
                                     "raw_csv": output_path.name})
            run_metadata.append(pair)
    with (OUT / "observations.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(combined[0]))
        writer.writeheader()
        writer.writerows(combined)

    by_key = {}
    for row in combined:
        if row["phase"] != "measure":
            continue
        key = (row["session"], int(row["producers"]), int(row["grain"]),
               int(row["sample"]))
        by_key.setdefault(key, {})[row["variant"]] = int(row["total_ns"])
    paired = []
    for key, times in sorted(by_key.items()):
        if set(times) != {"baseline", "candidate"}:
            raise RuntimeError(f"unpaired observation: {key}")
        paired.append({"session": key[0], "producers": key[1],
                       "grain": key[2], "sample": key[3],
                       "baseline_ns": times["baseline"],
                       "candidate_ns": times["candidate"],
                       "candidate_over_baseline": (
                           times["candidate"] / times["baseline"])})
    with (OUT / "paired.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(paired[0]))
        writer.writeheader()
        writer.writerows(paired)

    summary = []
    for producer in PRODUCERS:
        for grain in GRAINS:
            subset = [row for row in paired if row["producers"] == producer
                      and row["grain"] == grain]
            baseline = [row["baseline_ns"] for row in subset]
            candidate = [row["candidate_ns"] for row in subset]
            ratios = [row["candidate_over_baseline"] for row in subset]
            summary.append({
                "producers": producer, "grain": grain,
                "paired_samples": len(subset),
                "baseline_p50_ns": int(statistics.median(baseline)),
                "candidate_p50_ns": int(statistics.median(candidate)),
                "candidate_over_baseline_p50": statistics.median(ratios),
                "candidate_over_baseline_p95": percentile(ratios, 0.95),
                "candidate_wins": sum(ratio < 1 for ratio in ratios),
            })
    with (OUT / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)

    metadata["status"] = "PASS"
    metadata["sessions"] = run_metadata
    metadata["completed_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                               time.gmtime())
    (OUT / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print((OUT / "summary.csv").read_text(), end="")


if __name__ == "__main__":
    main()
