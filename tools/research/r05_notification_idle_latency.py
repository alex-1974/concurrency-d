#!/usr/bin/env python3
"""Research-only process-isolated notification wake latency and idle CPU.

Each run starts fresh worker threads, observes low-load idle CPU, and
records typed-result latency for repeated 1-task idle->wake transitions.
A two-policy alternating-pair design guards against fixed run-order bias.
This is not a high-throughput test or an OS real-time latency guarantee.
"""
import argparse
import csv
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


HEADERS = ("metric", "notification_policy", "workers",
           "idle_ms", "samples", "gap_ms", "idle_cpu_us",
           "idle_wall_ns", "p50_ns", "p95_ns", "p99_ns",
           "max_ns", "completed")


def run(binary, root, mode, workers, idle_ms, samples, gap_ms, round_id):
    command = [str(binary), str(workers), mode, str(idle_ms),
               str(samples), str(gap_ms)]
    with tempfile.TemporaryFile(mode="w+t") as fd:
        child = subprocess.Popen(
            command, cwd=root, stdout=fd, stderr=subprocess.STDOUT)
        _, status, resource = os.wait4(child.pid, 0)
        fd.seek(0)
        output = fd.read()

    code = os.waitstatus_to_exitcode(status)
    if code != 0:
        raise RuntimeError(
            f"{mode} run {round_id} exit {code}:\n" + output[-5000:])
    lines = [l for l in output.splitlines() if l.startswith("latency,")]
    if len(lines) != 1:
        raise RuntimeError("missing latency line:\n" + output[-5000:])
    values = next(csv.reader(lines))
    if len(values) != len(HEADERS):
        raise RuntimeError("D latency schema mismatch: " + lines[0])
    row = dict(zip(HEADERS, values))
    if (row["notification_policy"] != mode or
        int(row["workers"]) != workers or
        int(row["completed"]) != samples or
        int(row["samples"]) != samples or
        int(row["idle_ms"]) != idle_ms):
        raise RuntimeError("incomplete/invalid latency task count")
    if int(row["idle_wall_ns"]) < 1 or int(row["p99_ns"]) < int(row["p95_ns"]):
        raise RuntimeError("inconsistent timer measurements")
    row["round"] = round_id
    row["process_voluntary"] = resource.ru_nvcsw
    row["process_involuntary"] = resource.ru_nivcsw
    row["peak_rss_kib"] = resource.ru_maxrss
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--compiler", default="ldc2")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--idle-ms", type=int, default=100)
    ap.add_argument("--samples", type=int, default=128)
    ap.add_argument("--gap-ms", type=int, default=1)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--output", type=Path,
                    default=Path("evidence/r05-notify-idle-latency"))
    args = ap.parse_args()
    if (platform.system() != "Linux" or
        not 1 <= args.workers <= 64 or
        not 1 <= args.idle_ms <= 10000 or
        not 1 <= args.samples <= 10000 or
        not 1 <= args.gap_ms <= 100 or
        not 1 <= args.rounds <= 20):
        ap.error("invalid or non-Linux experiment configuration")

    root = Path(__file__).resolve().parents[2]
    subprocess.run(
        ["dub", "build", "--config=notification-latency-benchmark",
         "--build=release", "--compiler=" + args.compiler, "--force"],
        cwd=root, check=True)
    binary = root / "concurrency-notification-latency"
    if not binary.is_file():
        raise RuntimeError("notification-latency executable missing")

    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for rnd in range(args.rounds):
        order = ("always", "waiter") if rnd % 2 == 0 else (
            "waiter", "always")
        for mode in order:
            row = run(binary, root, mode, args.workers,
                      args.idle_ms, args.samples, args.gap_ms, rnd)
            rows.append(row)
            print(f"R05 idle-latency mode={mode} round={rnd} "
                  f"idle_cpu_us={row['idle_cpu_us']} "
                  f"p95_ns={row['p95_ns']} p99_ns={row['p99_ns']}",
                  flush=True)

    with (args.output / "raw.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    paired = {}
    for row in rows:
        paired.setdefault(row["round"], {})[row["notification_policy"]] = row
    if len(paired) != args.rounds or any(
            set(p) != {"always", "waiter"} for p in paired.values()):
        raise RuntimeError("incomplete latency pairs")

    def median(key, mode):
        return statistics.median(float(
            p[mode][key]) for p in paired.values())

    def diff(key):
        return statistics.median(
            float(p["waiter"][key]) - float(p["always"][key])
            for p in paired.values())

    summary = [{
        "rounds": args.rounds,
        "workers": args.workers,
        "idle_ms": args.idle_ms,
        "samples": args.samples,
        "gap_ms": args.gap_ms,
        "baseline_median_idle_cpu_us": median("idle_cpu_us", "always"),
        "waiter_median_idle_cpu_us": median("idle_cpu_us", "waiter"),
        "paired_idle_cpu_us_delta": diff("idle_cpu_us"),
        "baseline_median_p95_ns": median("p95_ns", "always"),
        "waiter_median_p95_ns": median("p95_ns", "waiter"),
        "paired_p95_ns_delta": diff("p95_ns"),
        "baseline_median_p99_ns": median("p99_ns", "always"),
        "waiter_median_p99_ns": median("p99_ns", "waiter"),
        "paired_p99_ns_delta": diff("p99_ns"),
    }]
    with (args.output / "summary.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)

    with (args.output / "environment.txt").open("w") as f:
        f.write(f"compiler={args.compiler}\nplatform={platform.platform()}\n"
                f"workers={args.workers} idle_ms={args.idle_ms}\n"
                f"samples={args.samples} gap_ms={args.gap_ms}\n"
                f"rounds={args.rounds}\n")
        for cmd in (["git", "rev-parse", "HEAD"], [args.compiler, "--version"],
                    ["lscpu"], ["cat",
                     "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"]):
            try:
                f.write("$ " + " ".join(cmd) + "\n")
                f.write(subprocess.run(cmd, cwd=root, check=True,
                        text=True, capture_output=True).stdout)
            except (OSError, subprocess.CalledProcessError):
                f.write("unavailable\n")

    print("R05 NOTIFY IDLE / LATENCY: differences are not performance gates")
    print(summary[0])
    print("evidence: " + str(args.output))


if __name__ == "__main__":
    main()
