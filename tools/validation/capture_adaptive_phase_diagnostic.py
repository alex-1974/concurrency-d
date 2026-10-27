#!/usr/bin/env python3
"""Run the phase diagnostic in randomized repeated sessions and validate rows."""
import csv
import hashlib
import io
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import time

SESSIONS = int(os.environ.get("SESSIONS", "4"))
SAMPLES = int(os.environ.get("SAMPLES", "20"))
WARMUPS = int(os.environ.get("WARMUPS", "5"))

if len(sys.argv) != 3:
    raise SystemExit("usage: capture_adaptive_phase_diagnostic.py BINARY OUTPUT.csv")
binary = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])
if not binary.is_file():
    raise SystemExit(f"diagnostic binary not found: {binary}")
if SESSIONS < 1 or SAMPLES < 1 or WARMUPS < 0:
    raise SystemExit("invalid session/sample counts")

expected_range_rows = 3 * 3 * (SAMPLES + WARMUPS)
expected_scope_rows = 9 * (SAMPLES + WARMUPS)
combined = []
columns = None
started_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
for session in range(1, SESSIONS + 1):
    run = subprocess.run(
        [str(binary), str(SAMPLES), str(WARMUPS), str(session - 1)],
        check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    rows = list(csv.DictReader(io.StringIO(run.stdout)))
    if not rows:
        raise RuntimeError(f"session {session}: diagnostic emitted no rows")
    if columns is None:
        columns = ["session", *rows[0].keys()]
    if len(rows) != expected_range_rows + expected_scope_rows:
        raise RuntimeError(
            f"session {session}: expected {expected_range_rows + expected_scope_rows} rows, got {len(rows)}")
    range_rows = [row for row in rows if row["arm"] != "scope_spawn_drain"]
    scope_rows = [row for row in rows if row["arm"] == "scope_spawn_drain"]
    if len(range_rows) != expected_range_rows or len(scope_rows) != expected_scope_rows:
        raise RuntimeError(f"session {session}: malformed phase row counts")
    range_keys = [(row["phase"], row["sample"], row["scenario"], row["arm"])
                  for row in range_rows]
    scope_keys = [(row["phase"], row["sample"], row["scenario"])
                  for row in scope_rows]
    if len(set(range_keys)) != len(range_keys) or len(set(scope_keys)) != len(scope_keys):
        raise RuntimeError(f"session {session}: duplicate setting/sample rows")
    for row in rows:
        if int(row["elapsed_ns"]) <= 0 or int(row["checksum"]) <= 0:
            raise RuntimeError(f"session {session}: invalid timing/checksum row {row}")
        if row["phase"] == "warmup" and int(row["sample"]) >= WARMUPS:
            raise RuntimeError(f"session {session}: malformed warmup index")
        if row["phase"] == "measure" and not WARMUPS <= int(row["sample"]) < WARMUPS + SAMPLES:
            raise RuntimeError(f"session {session}: malformed measured index")
        combined.append({"session": session, **row})
    print(f"PHASE_DIAGNOSTIC_PROGRESS session={session}/{SESSIONS} rows={len(rows)}", flush=True)

output.parent.mkdir(parents=True, exist_ok=True)
with output.open("w", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=columns)
    writer.writeheader()
    writer.writerows(combined)
cpuinfo = pathlib.Path("/proc/cpuinfo")
cpu_model = "unknown"
if cpuinfo.exists():
    cpu_lines = cpuinfo.read_text(errors="replace").splitlines()
    for key in ("model name", "hardware", "model"):
        for line in cpu_lines:
            if line.lower().startswith(key) and ":" in line:
                candidate = line.split(":", 1)[1].strip()
                if candidate:
                    cpu_model = candidate
                    break
        if cpu_model != "unknown":
            break
source_commit = subprocess.run(
    ["git", "rev-parse", "HEAD"], text=True, stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL)
baseline_commit = subprocess.run(
    ["git", "rev-parse", "v0.3.0"], text=True, stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL)
metadata = {
    "status": "complete", "baseline_tag": "v0.3.0",
    "baseline_commit": baseline_commit.stdout.strip() if baseline_commit.returncode == 0 else None,
    "source_commit": source_commit.stdout.strip() if source_commit.returncode == 0 else None,
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "compiler": os.environ.get("DC", "not specified"),
    "machine": platform.uname()._asdict(), "cpu_model": cpu_model,
    "protocol": {"sessions": SESSIONS, "measured_samples": SAMPLES,
                 "warmups": WARMUPS, "workers": 4, "items": 1024,
                 "waves": 8, "grain": 1,
                 "costs_lcg_steps": {"noop": 0, "short": 16, "heavy": 1024}},
    "started_utc": started_utc,
    "ended_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
sensors = shutil.which("sensors")
if sensors:
    sensor_read = subprocess.run([sensors], text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT)
    metadata["sensors_after"] = sensor_read.stdout
metadata_path = output.with_suffix(".metadata.json")
metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
print(f"PHASE_DIAGNOSTIC_COMPLETE output={output} rows={len(combined)}")
print(f"PHASE_DIAGNOSTIC_METADATA output={metadata_path}")
