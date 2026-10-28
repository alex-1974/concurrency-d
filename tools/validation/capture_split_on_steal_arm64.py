#!/usr/bin/env python3
"""Compare v0.3.0, split-on-steal, and Phobos on native ARM64."""
import csv
import hashlib
import io
import json
import os
import pathlib
import platform
import shutil
import statistics
import subprocess
import tarfile
import time
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(os.environ.get("SPLIT_CAPTURE_DIR", "/tmp/split-on-steal-arm64"))
SAMPLES = int(os.environ.get("SAMPLES", "12"))
WARMUPS = int(os.environ.get("WARMUPS", "3"))
SESSIONS = int(os.environ.get("SESSIONS", "4"))
DC = os.environ.get("DC", "ldc2")

if platform.machine() not in ("aarch64", "arm64"):
    raise SystemExit(f"requires native ARM64, got {platform.machine()}")
if min(SAMPLES, SESSIONS) < 1 or WARMUPS < 0:
    raise SystemExit("invalid sample/session counts")
if OUT.exists():
    raise SystemExit(f"output directory already exists: {OUT}")
OUT.mkdir(parents=True)
work = pathlib.Path("/tmp/split-on-steal-arm64-builds")
if work.exists():
    shutil.rmtree(work)
work.mkdir()

baseline_tree = work / "baseline"
archive = subprocess.Popen(["git", "archive", "v0.3.0"], cwd=ROOT,
                           stdout=subprocess.PIPE)
with tarfile.open(fileobj=archive.stdout, mode="r|") as tf:
    tf.extractall(baseline_tree, filter="data")
if archive.wait() != 0:
    raise RuntimeError("git archive v0.3.0 failed")
shutil.copytree(ROOT / "benchmarks/split-on-steal",
                baseline_tree / "benchmarks/split-on-steal")

trees = {"baseline": baseline_tree, "candidate": ROOT}
binaries = {}
for name, tree in trees.items():
    build = subprocess.run(
        ["dub", "build", f"--root={tree / 'benchmarks/split-on-steal'}",
         f"--compiler={DC}", "--build=release", "--force"],
        cwd=tree, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if build.returncode:
        raise RuntimeError(f"{name} build failed:\n{build.stdout}")
    binary = tree / "benchmarks/split-on-steal/concurrency-split-on-steal-benchmark"
    if not binary.is_file():
        raise RuntimeError(f"missing {name} binary: {binary}")
    binaries[name] = binary

workloads = [
    "short_uniform_1024", "medium_uniform_1024", "scattered_1024",
    "heavy_prefix_1024", "heavy_suffix_1024", "short_uniform_16384",
    "medium_uniform_16384", "scattered_16384", "heavy_prefix_16384",
    "heavy_suffix_16384",
]
grains = (1, 4, 16, 64, 256, 512, 1024)
arms = ({f"{kind}_{grain}" for kind in ("fixed", "adaptive") for grain in grains}
        | {f"phobos_{grain}" for grain in grains}
        | {"inline", "serial", "hint_small", "hint_large"})
expected_rows = len(workloads) * (SAMPLES + WARMUPS) * len(arms)
meta = {
    "status": "IN_PROGRESS", "baseline_tag": "v0.3.0",
    "baseline_commit": subprocess.check_output(
        ["git", "rev-parse", "v0.3.0^{commit}"], cwd=ROOT, text=True).strip(),
    "candidate_commit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "variants": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                 for name, path in binaries.items()},
    "protocol": (f"{SESSIONS} sessions; {SAMPLES} measured and {WARMUPS} warmup "
                 "samples; four total participants; 10 workloads (1,024 and "
                 "16,384 items); fixed/adaptive grain and Phobos batch sweeps "
                 "(1,4,16,64,256,512,1024), plus inline, serial, and WorkSize "
                 "controls "
                 "with rotating order; one Executor, one Phobos TaskPool, and "
                 "one output buffer per workload are reused across measured "
                 "samples; eight waves per timed invocation; Phobos uses "
                 "TaskPool(3) plus its calling thread; executor ingress capacity "
                 "is 64; all scheduler grain/batch sizes are swept"),
    "machine": platform.uname()._asdict(),
    "cpuinfo": pathlib.Path("/proc/cpuinfo").read_text(),
    "compiler": subprocess.check_output([DC, "--version"], text=True),
    "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "sessions": [],
}
(OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
all_rows = []

for session in range(1, SESSIONS + 1):
    order = ["baseline", "candidate"] if session % 2 else ["candidate", "baseline"]
    session_meta = {"session": session, "order": order, "variants": []}
    for name in order:
        proc = subprocess.run(
            [str(binaries[name]), str(SAMPLES), str(WARMUPS)],
            cwd=trees[name], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
        if proc.returncode:
            raise RuntimeError(f"{name} session {session} failed:\n{proc.stdout[-4000:]}")
        rows = list(csv.DictReader(io.StringIO(proc.stdout)))
        if len(rows) != expected_rows:
            raise RuntimeError(f"{name}: expected {expected_rows} rows, got {len(rows)}")
        pairs = defaultdict(list)
        for row in rows:
            pairs[(row["phase"], row["sample"], row["workload"],
                   row["workers"], row["item_count"])].append(row)
        if len(pairs) != expected_rows // len(arms):
            raise RuntimeError(f"{name}: malformed row pairs")
        for key, pair in pairs.items():
            if len(pair) != len(arms) or {r["arm"] for r in pair} != arms:
                raise RuntimeError(f"{name}: malformed pair {key}")
            if len({r["checksum"] for r in pair}) != 1:
                raise RuntimeError(f"{name}: checksum mismatch {key}")
        path = OUT / f"{name}-session{session}.csv"
        with path.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=["session", "variant", *rows[0]])
            writer.writeheader()
            for row in rows:
                output = {"session": session, "variant": name, **row}
                writer.writerow(output)
                all_rows.append(output)
        session_meta["variants"].append({"name": name, "rows": len(rows),
                                         "checksum_pairs": len(pairs)})
        print(f"SPLIT_ARM64_PROGRESS session={session}/{SESSIONS} variant={name}",
              flush=True)
    meta["sessions"].append(session_meta)
    (OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")

combined = OUT / "paired-runs.csv"
fields = ["session", "variant", *all_rows[0].keys()]
with combined.open("w", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(dict.fromkeys(fields)))
    writer.writeheader()
    writer.writerows(all_rows)

samples = defaultdict(list)
for row in all_rows:
    if row["phase"] == "measure":
        samples[(row["variant"], row["workload"], row["arm"])].append(
            int(row["elapsed_ns"]))
summary = []
for workload in workloads:
    baseline = samples[("baseline", workload, "adaptive_1")]
    candidate = samples[("candidate", workload, "adaptive_1")]
    percentile = lambda values, p: sorted(values)[max(0, (len(values) * p + 99) // 100 - 1)]
    base_p50 = statistics.median(baseline)
    cand_p50 = statistics.median(candidate)
    base_p95 = percentile(baseline, 95)
    cand_p95 = percentile(candidate, 95)
    phobos_stats = {}
    for batch in grains:
        values = samples[("candidate", workload, f"phobos_{batch}")]
        phobos_stats[str(batch)] = {
            "p50_ns": statistics.median(values), "p95_ns": percentile(values, 95),
            "samples": len(values),
        }
    best_batch = min(phobos_stats, key=lambda batch: phobos_stats[batch]["p50_ns"])
    phobos_p50 = phobos_stats[best_batch]["p50_ns"]
    phobos_p95 = phobos_stats[best_batch]["p95_ns"]
    concurrency_stats = {}
    for kind in ("fixed", "adaptive"):
        for grain in grains:
            arm = f"{kind}_{grain}"
            values = samples[("candidate", workload, arm)]
            concurrency_stats[arm] = {
                "p50_ns": statistics.median(values), "p95_ns": percentile(values, 95),
                "samples": len(values),
            }
    control_stats = {}
    for arm in ("inline", "serial"):
        values = samples[("candidate", workload, arm)]
        control_stats[arm] = {
            "p50_ns": statistics.median(values), "p95_ns": percentile(values, 95),
            "samples": len(values),
        }
    hint_stats = {}
    for arm in ("hint_small", "hint_large"):
        values = samples[("candidate", workload, arm)]
        hint_stats[arm] = {
            "p50_ns": statistics.median(values), "p95_ns": percentile(values, 95),
            "samples": len(values),
        }
    best_concurrency = min(concurrency_stats,
                           key=lambda arm: concurrency_stats[arm]["p50_ns"])
    concurrency_p50 = concurrency_stats[best_concurrency]["p50_ns"]
    concurrency_p95 = concurrency_stats[best_concurrency]["p95_ns"]
    summary.append({
        "workload": workload, "samples_per_variant": len(baseline),
        "baseline_p50_ns": base_p50, "candidate_p50_ns": cand_p50,
        "p50_ratio_candidate_over_baseline": cand_p50 / base_p50,
        "baseline_p95_ns": base_p95, "candidate_p95_ns": cand_p95,
        "p95_ratio_candidate_over_baseline": cand_p95 / base_p95,
        "p95_over_10_percent_screen": cand_p95 > base_p95 * 1.10,
        "best_phobos_batch_by_p50": int(best_batch),
        "phobos_batch_stats": phobos_stats,
        "best_concurrency_arm_by_p50": best_concurrency,
        "concurrency_grain_stats": concurrency_stats,
        "control_stats": control_stats,
        "work_size_hint_stats": hint_stats,
        "best_concurrency_p50_ns": concurrency_p50,
        "best_concurrency_p95_ns": concurrency_p95,
        "best_phobos_p50_ns": phobos_p50,
        "best_concurrency_p50_over_phobos": concurrency_p50 / phobos_p50,
        "best_phobos_p95_ns": phobos_p95,
        "best_concurrency_p95_over_phobos": concurrency_p95 / phobos_p95,
    })
(OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
meta["timing_matrix_status"] = "COMPLETE"
meta["summary"] = "summary.json"
meta["raw_runs"] = combined.name
meta["status"] = "COMPLETE"
meta["ended_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
(OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
print(f"SPLIT_ARM64_CAPTURE_COMPLETE output={OUT}", flush=True)
