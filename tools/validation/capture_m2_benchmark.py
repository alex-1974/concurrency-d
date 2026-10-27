#!/usr/bin/env python3
"""Capture repeatable, metadata-rich M2 end-to-end benchmark sessions."""
import argparse
import csv
import datetime as dt
import json
import os
import platform
import subprocess
from pathlib import Path


def command_output(command):
    try:
        return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return f"unavailable: {error}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--warmups", type=int, default=5)
    parser.add_argument("--base-iterations", type=int, default=1024)
    parser.add_argument("--sessions", type=int, default=4)
    args = parser.parse_args()
    if min(args.workers, args.samples, args.sessions, args.base_iterations) < 1 or args.warmups < 0:
        parser.error("workers, samples, sessions and base iterations must be positive; warmups cannot be negative")
    args.output.mkdir(parents=True, exist_ok=True)
    command = [str(args.executable.resolve()), str(args.workers), str(args.samples), str(args.warmups), str(args.base_iterations)]
    rows = []
    for session in range(args.sessions):
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        parsed = list(csv.DictReader(result.stdout.splitlines()))
        if not parsed:
            raise RuntimeError(f"session {session} returned no benchmark rows")
        rows.extend({"session": session, **row} for row in parsed)
    csv_path = args.output / "end-to-end.csv"
    with csv_path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["session", *parsed[0].keys()])
        writer.writeheader()
        writer.writerows(rows)
    metadata = {
        "captured_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "git_revision": os.environ.get("GITHUB_SHA") or command_output(["git", "rev-parse", "HEAD"]),
        "git_ref": os.environ.get("GITHUB_REF_NAME") or command_output(["git", "branch", "--show-current"]),
        "git_worktree_dirty": bool(command_output(["git", "status", "--porcelain"])),
        "command": command,
        "sessions": args.sessions,
        "samples_per_arm_per_session": args.samples,
        "warmups_per_arm_per_session": args.warmups,
        "base_iterations": args.base_iterations,
        "python": platform.python_version(),
        "platform": platform.platform(),
        "uname": command_output(["uname", "-a"]),
        "lscpu": command_output(["lscpu"]),
        "compiler": command_output(["ldc2", "--version"]),
        "dub": command_output(["dub", "--version"]),
        "platform_profile": command_output(["cat", "/sys/firmware/acpi/platform_profile"]),
        "sensors_before_capture": command_output(["sensors"]),
        "row_count": len(rows),
        "checksum_validation": "benchmark exits nonzero on any arm mismatch; all sessions completed",
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"wrote {len(rows)} rows to {csv_path}")


if __name__ == "__main__":
    main()
