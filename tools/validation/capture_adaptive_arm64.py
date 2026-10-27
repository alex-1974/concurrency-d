#!/usr/bin/env python3
"""Build and checksum-validate divisor 4/8/16 adaptive range runs on ARM64."""
import csv
import hashlib
import io
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tarfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(os.environ.get("ADAPTIVE_CAPTURE_DIR", "/tmp/adaptive-arm64-capture"))
SAMPLES = int(os.environ.get("SAMPLES", "20"))
WARMUPS = int(os.environ.get("WARMUPS", "5"))
SESSIONS = int(os.environ.get("SESSIONS", "4"))
WORKERS = os.environ.get("WORKERS", "1,4")
GRAINS = os.environ.get("GRAINS", "1,64")
DC = os.environ.get("DC", "ldc2")

if platform.machine() not in ("aarch64", "arm64"):
    raise SystemExit(f"requires native ARM64, got {platform.machine()}")
if min(SAMPLES, SESSIONS) < 1 or WARMUPS < 0:
    raise SystemExit("invalid sample/session counts")
if OUT.exists():
    raise SystemExit(f"output directory already exists: {OUT}")
OUT.mkdir(parents=True)
work = pathlib.Path("/tmp/adaptive-arm64-builds")
if work.exists():
    shutil.rmtree(work)
work.mkdir()

archive = subprocess.Popen(["git", "archive", "v0.3.0"], cwd=ROOT, stdout=subprocess.PIPE)
with tarfile.open(fileobj=archive.stdout, mode="r|") as tf:
    tf.extractall(work / "divisor8", filter="data")
if archive.wait() != 0:
    raise RuntimeError("git archive v0.3.0 failed")

variants = {}
for divisor in (8, 4, 16):
    tree = work / f"divisor{divisor}"
    if divisor != 8:
        shutil.copytree(work / "divisor8", tree)
    harness_dir = tree / "benchmarks/adaptive-ranges"
    harness_dir.mkdir(parents=True, exist_ok=True)
    # The focused benchmark was added after v0.3.0. Reuse the current harness
    # and manifest while keeping each variant's library source at the tag.
    for filename in ("main.d", "dub.json"):
        shutil.copy2(ROOT / "benchmarks/adaptive-ranges" / filename,
                     harness_dir / filename)
    harness = harness_dir / "main.d"
    source = tree / "source/concurrency/executor.d"
    text = source.read_text()
    if divisor != 8:
        old = "remaining / _workerCount / 8;"
        if text.count(old) != 1:
            raise RuntimeError(f"expected one guided divisor in {source}")
        source.write_text(text.replace(old, f"remaining / _workerCount / {divisor};"))
    build = subprocess.run(
        ["dub", "build", f"--root={tree / 'benchmarks/adaptive-ranges'}",
         f"--compiler={DC}", "--build=release", "--force"],
        cwd=tree, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if build.returncode:
        raise RuntimeError(f"build divisor {divisor} failed:\n{build.stdout}")
    binary = tree / "benchmarks/adaptive-ranges/concurrency-adaptive-ranges-benchmark"
    if not binary.is_file():
        raise RuntimeError(f"missing benchmark binary: {binary}")
    variants[divisor] = binary

expected_rows = 6 * len(WORKERS.split(",")) * len(GRAINS.split(",")) * (SAMPLES + WARMUPS) * 2
meta = {
    "status": "INCOMPLETE", "baseline_tag": "v0.3.0",
    "baseline_commit": subprocess.check_output(["git", "rev-parse", "v0.3.0"], cwd=ROOT, text=True).strip(),
    "variants": {str(d): hashlib.sha256(p.read_bytes()).hexdigest() for d, p in variants.items()},
    "protocol": f"{SESSIONS} sessions; {SAMPLES} measured and {WARMUPS} warmup samples per setting; 6 workloads x workers={WORKERS} x grains={GRAINS}; fixed/adaptive pairs; alternating variant order",
    "machine": platform.uname()._asdict(),
    "cpuinfo": pathlib.Path("/proc/cpuinfo").read_text(),
    "compiler": subprocess.check_output([DC, "--version"], text=True),
    "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "sessions": []
}
(OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")

for session in range(1, SESSIONS + 1):
    order = [8, 4, 16] if session % 2 else [16, 4, 8]
    session_meta = {"session": session, "order": order, "variants": []}
    for divisor in order:
        proc = subprocess.run([str(variants[divisor]), str(SAMPLES), str(WARMUPS), WORKERS, GRAINS],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode:
            raise RuntimeError(f"divisor {divisor} session {session} failed:\n{proc.stdout[-4000:]}")
        rows = list(csv.DictReader(io.StringIO(proc.stdout)))
        if len(rows) != expected_rows:
            raise RuntimeError(f"divisor {divisor}: expected {expected_rows} rows, got {len(rows)}")
        pairs = {}
        for row in rows:
            key = (row["phase"], row["sample"], row["workload"], row["workers"], row["batch_size"])
            pairs.setdefault(key, []).append(row)
        if len(pairs) != expected_rows // 2:
            raise RuntimeError(f"divisor {divisor}: malformed paired rows")
        for key, pair in pairs.items():
            if len(pair) != 2 or {r["arm"] for r in pair} != {"parallelForReused", "parallelForAdaptiveReused"}:
                raise RuntimeError(f"divisor {divisor}: malformed pair {key}")
            if pair[0]["checksum"] != pair[1]["checksum"]:
                raise RuntimeError(f"divisor {divisor}: checksum mismatch {key}")
        path = OUT / f"divisor{divisor}-session{session}.csv"
        with path.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["session", "divisor", *rows[0].keys()])
            writer.writeheader()
            for row in rows:
                writer.writerow({"session": session, "divisor": divisor, **row})
        session_meta["variants"].append({"divisor": divisor, "rows": len(rows), "checksum_pairs": len(pairs)})
        print(f"ARM64_PROGRESS session={session}/{SESSIONS} divisor={divisor} rows={len(rows)}", flush=True)
    meta["sessions"].append(session_meta)
    (OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
meta["status"] = "COMPLETE"
meta["ended_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
(OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
print(f"ARM64_CAPTURE_COMPLETE output={OUT}", flush=True)
