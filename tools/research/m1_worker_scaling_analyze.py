#!/usr/bin/env python3
"""P13 exact-output and paired worker-scaling analysis, no CI speed gate.

Analyzes emitted CSV only; makes no claim about CPU frequency, thermal
stability, actual work-steal count or native join-error safety.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median


def analyze(path: Path, required_rounds: int, expected_profile: str) -> list[dict]:
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise ValueError(f"{path}: no benchmark rows")

    kernels = {0, 128} if expected_profile == "smoke" else {0, 8, 32, 128, 512}
    ingresses = {64} if expected_profile == "smoke" else {8, 64, 256}
    expected_cases = {
        (it, ingress, workers)
        for it in kernels for ingress in ingresses for workers in (1, 2, 4)
    }
    rounds = defaultdict(dict)
    checksums = defaultdict(set)
    total_count = set()
    seed_values = set()
    measured_groups = defaultdict(list)

    for row in rows:
        phase = row["phase"]
        if phase not in ("warmup", "measure"):
            raise ValueError(f"{path}: invalid phase {phase}")
        run = int(row["round"])
        position = int(row["order"])
        config = tuple(int(row[field]) for field in ("iterations", "ingress", "workers"))
        if config not in expected_cases:
            raise ValueError(f"{path}: invalid configuration {config}")

        key = (phase, run)
        if config in rounds[key]:
            raise ValueError(f"{path}: duplicate configuration in {key}: {config}")
        rounds[key][config] = position

        tasks = int(row["count"])
        waves = int(row["waves"])
        total_count.add((tasks, waves))
        if tasks < 1 or waves < 1:
            raise ValueError(f"{path}: invalid submitted count")
        seed_values.add(int(row["seed"]))
        checksums[int(row["iterations"])].add(int(row["checksum"]))

        durations = [
            int(row[field]) for field in
            ("prepare_ns", "pool_start_ns", "waves_ns", "join_ns",
             "verify_ns", "total_ns")
        ]
        if min(durations) < 0 or abs(sum(durations[:-1]) - durations[-1]) > 20:
            raise ValueError(f"{path}: invalid monotonic interval partition: {row}")
        if int(row["retries"]) < 0 or int(row["park_count"]) < 0:
            raise ValueError(f"{path}: invalid counter")
        if phase == "measure":
            measured_groups[config].append((run, row))

    if len(total_count) != 1 or len(seed_values) != 1:
        raise ValueError(f"{path}: inconsistent work or RNG seed")
    if any(len(checksums[it]) != 1 for it in kernels):
        raise ValueError(f"{path}: worker/ingress checksum mismatch")

    for key, slots in rounds.items():
        if set(slots) != expected_cases:
            raise ValueError(f"{path}: missing configurations in {key}")
        if set(slots.values()) != set(range(len(expected_cases))):
            raise ValueError(f"{path}: duplicate/missing execution order in {key}")

    measured_runs = sorted({run for phase, run in rounds if phase == "measure"})
    if len(measured_runs) < required_rounds:
        raise ValueError(f"{path}: fewer than {required_rounds} measured sweeps")

    summary = []
    for (iterations, ingress, workers), values in sorted(measured_groups.items()):
        if len(values) != len(measured_runs):
            raise ValueError(f"{path}: incomplete measured series")
        work = sorted(int(x["waves_ns"]) for _, x in values)
        startup = sorted(int(x["pool_start_ns"]) for _, x in values)
        parked = sorted(int(x["park_count"]) for _, x in values)
        retries = sorted(int(x["retries"]) for _, x in values)
        tasks, waves = next(iter(total_count))
        summary.append({
            "source": path.stem, "iterations": iterations, "ingress": ingress,
            "workers": workers, "samples": len(values),
            "median_wave_ns": int(median(work)),
            "minimum_wave_ns": work[0], "maximum_wave_ns": work[-1],
            "median_pool_start_ns": int(median(startup)),
            "median_park_count": int(median(parked)),
            "median_retries": int(median(retries)),
            "tasks": tasks, "waves": waves,
            "checksum": next(iter(checksums[iterations])),
        })

    by_round = {
        (it, ingress, workers, run): int(row["waves_ns"])
        for (it, ingress, workers), values in measured_groups.items()
        for run, row in values
    }
    for it in sorted(kernels):
        for ingress in sorted(ingresses):
            ratios = sorted(
                by_round[(it, ingress, 4, run)] /
                by_round[(it, ingress, 2, run)]
                for run in measured_runs
            )
            print(f"P13 DIAGNOSTIC {path.name} iterations={it} ingress={ingress} "
                  f"4w/2w within-sweep median={median(ratios):.3f} "
                  f"min={ratios[0]:.3f} max={ratios[-1]:.3f} "
                  f"samples={len(ratios)}")
    print(f"P13 correctness PASS {path.name}: "
          f"cases={len(expected_cases)}, measured_sweeps={len(measured_runs)}, "
          f"tasks_per_wave={tasks}, waves={waves}")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum-rounds", type=int, default=2)
    parser.add_argument("--require-profile", choices=("smoke", "native"),
                        default="smoke")
    parser.add_argument("--output", type=Path)
    parser.add_argument("csv_files", type=Path, nargs="+")
    args = parser.parse_args()
    summary = []
    for path in args.csv_files:
        summary.extend(analyze(path, args.minimum_rounds, args.require_profile))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(summary[0]))
            writer.writeheader()
            writer.writerows(summary)
        print(f"P13 aggregate diagnostic written to: {args.output}")


if __name__ == "__main__":
    main()
