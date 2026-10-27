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
# Capture process-scoped CPU-clock call graphs for short and heavy callbacks.
# Some hosted kernels restrict perf_event access; preserve the diagnostic status
# and logs in the artifact instead of discarding the completed timing matrix.
profile_dir = OUT / "profiles"
profile_dir.mkdir()
meta["profiles"] = []
perf = shutil.which("perf")
for profile_name, repeats in (("short", 3000), ("heavy", 300)):
    package = variants[8].parent.parent / f"profile-{profile_name}"
    package.mkdir(parents=True, exist_ok=True)
    profile_manifest = {
        "name": f"adaptive-profile-{profile_name}", "targetType": "executable",
        "sourcePaths": [], "mainSourceFile": "main.d",
        "targetName": f"adaptive-profile-{profile_name}",
        "dependencies": {"concurrency-d": {"path": "../.."}}
    }
    (package / "dub.json").write_text(json.dumps(profile_manifest) + "\n")
    shutil.copy2(ROOT / "benchmarks/adaptive-ranges/profiles" / f"{profile_name}.d",
                 package / "main.d")
    build = subprocess.run(
        ["dub", "build", f"--root={package}", f"--compiler={DC}", "--build=release", "--force"],
        cwd=variants[8].parents[2], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT)
    if build.returncode:
        (profile_dir / f"{profile_name}-build.log").write_text(build.stdout)
        meta["profiles"].append({"name": profile_name, "status": "build-failed", "log": f"{profile_name}-build.log"})
        continue
    binary = package / f"adaptive-profile-{profile_name}"
    for mode in ("adaptive", "fixed"):
        data = profile_dir / f"{profile_name}-{mode}.data"
        log = profile_dir / f"{profile_name}-{mode}.log"
        if not perf:
            log.write_text("perf executable not found on runner\n")
            meta["profiles"].append({"name": profile_name, "mode": mode, "status": "perf-unavailable", "log": log.name})
            continue
        record_command = [perf, "record", "-F", "997", "-e", "cpu-clock:u",
                          "--call-graph", "dwarf,8192", "-o", str(data), "--",
                          str(binary), mode, str(repeats)]
        recorded = subprocess.run(record_command, cwd=variants[8].parents[2],
                                  text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        record_log = recorded.stdout
        if recorded.returncode != 0 and "perf_event_paranoid" in record_log:
            # Hosted Linux images can lock perf_event_paranoid at 4. Try the
            # user-space-only event policy on this throwaway CI VM, then rerun
            # perf as the unprivileged workflow user.
            policy = subprocess.run(
                ["sudo", "-n", "sysctl", "-w", "kernel.perf_event_paranoid=0"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            record_log += "\nPERF_POLICY_ADJUSTMENT\n" + policy.stdout
            if policy.returncode == 0:
                recorded = subprocess.run(record_command, cwd=variants[8].parents[2],
                                          text=True, stdout=subprocess.PIPE,
                                          stderr=subprocess.STDOUT)
                record_log += "\nPERF_RETRY\n" + recorded.stdout
        log.write_text(record_log)
        if recorded.returncode != 0 or not data.exists() or data.stat().st_size == 0:
            meta["profiles"].append({"name": profile_name, "mode": mode,
                                      "status": "record-failed", "log": log.name})
            continue
        report = subprocess.run(
            [perf, "report", "--stdio", "--no-children", "-i", str(data),
             "--percent-limit", "1"], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
        report_path = profile_dir / f"{profile_name}-{mode}-report.txt"
        report_path.write_text(report.stdout)
        meta["profiles"].append({"name": profile_name, "mode": mode,
                                  "status": "complete" if report.returncode == 0 else "report-failed",
                                  "repeats": repeats, "data": data.name,
                                  "report": report_path.name, "log": log.name})

meta["status"] = "COMPLETE"
meta["ended_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
(OUT / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
print(f"ARM64_CAPTURE_COMPLETE output={OUT}", flush=True)
