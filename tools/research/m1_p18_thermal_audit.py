#!/usr/bin/env python3
"""P18 observational thermal audit; temperature is a flag, not a speed verdict.

Never infer stable clocks from 500-ms sysfs samples. P17's original strict
preflight and reviewer remain unchanged for historical reproducibility.
"""
import argparse
import csv
from pathlib import Path
from statistics import median
import sys

import m1_p17_telemetry as telemetry


def snapshot(cpus_text, mode, alert):
    cpus = telemetry.cpus_csv(cpus_text)
    row = telemetry.sample(cpus, telemetry.discover_package_sensor())
    raw = row['package_mC']
    temp = None if raw in ('', None) else int(raw) / 1000
    label = 'unknown' if temp is None else f'{temp:.3f}'
    flag = ('SENSOR_MISSING' if temp is None else
            'HIGH_SAMPLE' if temp >= alert else 'OBSERVED_BELOW_ALERT')
    print(f'P18 preflight utc={row["utc"]} package_c={label} '
          f'alert_c={alert:g} flag={flag} policy={mode}')
    if mode == 'strict' and flag != 'OBSERVED_BELOW_ALERT':
        print('P18 strict-only preflight refused; observation mode does not '
              'apply a temperature admission gate.', file=sys.stderr)
        return 4
    return 0


def analyze(directory, output, alert):
    paths = sorted(directory.glob('session*-*.csv'))
    if not paths:
        raise ValueError('no P18 thermal traces')
    fields = ('file', 'samples', 'temperature_samples', 'min_temp_c',
              'median_temp_c', 'max_temp_c', 'min_reported_khz',
              'max_reported_khz', 'max_throttle_delta', 'flags')
    results = []
    for path in paths:
        with path.open(newline='') as stream:
            data = list(csv.DictReader(stream))
        if not data:
            raise ValueError(f'empty thermal trace: {path}')
        temps = [int(r['package_mC']) / 1000 for r in data
                 if r['package_mC'] not in ('', None)]
        fkeys = [k for k in data[0] if k.endswith('_reported_khz')]
        freqs = [int(r[k]) for r in data for k in fkeys
                 if r[k] not in ('', None)]
        tkeys = [k for k in data[0] if k.endswith('_pkg_throttle_count')]
        deltas = []
        for key in tkeys:
            values = [int(r[key]) for r in data if r[key] not in ('', None)]
            if len(values) >= 2:
                deltas.append(max(0, values[-1] - values[0]))
        flags = []
        if not temps:
            flags.append('SENSOR_MISSING')
        elif max(temps) >= alert:
            flags.append('HIGH_SAMPLE')
        if not deltas:
            flags.append('THROTTLE_COUNTER_UNAVAILABLE')
        elif max(deltas) > 0:
            flags.append('THROTTLE_INCREMENT')
        if len(data) < 2 or len(temps) < 2:
            flags.append('SPARSE_SAMPLES')
        if not flags:
            flags.append('OBSERVED_ONLY')
        results.append(dict(file=path.name, samples=len(data),
                            temperature_samples=len(temps),
                            min_temp_c=min(temps) if temps else '',
                            median_temp_c=median(temps) if temps else '',
                            max_temp_c=max(temps) if temps else '',
                            min_reported_khz=min(freqs) if freqs else '',
                            max_reported_khz=max(freqs) if freqs else '',
                            max_throttle_delta=max(deltas) if deltas else '',
                            flags=';'.join(flags)))
    with output.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(results)
    flagged = sum(r['flags'] != 'OBSERVED_ONLY' for r in results)
    print(f'P18 observational thermal audit: {len(results)} process traces; '
          f'{flagged} with recorded attention/missing-data flags.')
    print('No temperature flag alone decides performance. Paired workload '
          'directions, frequency drift, throttling and noise need review.')
    print('500-ms samples cannot rule out transient throttling or prove '
          'constant per-worker execution frequency.')
    return results


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        header = ('package_mC,cpu0_reported_khz,cpu0_pkg_throttle_count\n')
        (folder / 'session1-control.csv').write_text(
            header + '72000,4000000,1\n73000,4200000,1\n')
        (folder / 'session1-grace.csv').write_text(
            header + '94000,4000000,1\n97000,3600000,3\n')
        (folder / 'session2-control.csv').write_text(
            header + ',,\n,,\n')
        rows = analyze(folder, folder / 'out.csv', 95)
        assert rows[0]['flags'] == 'OBSERVED_ONLY'
        assert rows[1]['flags'] == 'HIGH_SAMPLE;THROTTLE_INCREMENT'
        assert rows[1]['max_throttle_delta'] == 2
        assert rows[2]['flags'] == 'SENSOR_MISSING;THROTTLE_COUNTER_UNAVAILABLE;SPARSE_SAMPLES'
        assert len(list(csv.DictReader((folder / 'out.csv').open()))) == 3
    original_sample = telemetry.sample
    original_sensor = telemetry.discover_package_sensor
    try:
        telemetry.discover_package_sensor = lambda: None
        for raw, strict_rc in (('', 4), (94999, 0), (95000, 4)):
            telemetry.sample = lambda cpus, sensor, value=raw: {
                'utc': '2026-10-14T00:00:00Z', 'package_mC': value}
            assert snapshot('0', 'observe', 95) == 0
            assert snapshot('0', 'strict', 95) == strict_rc
    finally:
        telemetry.sample = original_sample
        telemetry.discover_package_sensor = original_sensor
    print('P18 thermal audit synthetic self-test PASS')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('snapshot', 'review', 'self-test'))
    parser.add_argument('directory', nargs='?', type=Path)
    parser.add_argument('output', nargs='?', type=Path)
    parser.add_argument('--cpus', default='0,1,2,3')
    parser.add_argument('--mode', choices=('observe', 'strict'), default='observe')
    parser.add_argument('--alert-package-c', type=float, default=95)
    args = parser.parse_args()
    if not 0 < args.alert_package_c <= 200:
        parser.error('invalid --alert-package-c')
    if args.action == 'self-test':
        self_test()
    elif args.action == 'snapshot':
        return snapshot(args.cpus, args.mode, args.alert_package_c)
    else:
        if args.directory is None or args.output is None:
            parser.error('review requires directory and output')
        analyze(args.directory, args.output, args.alert_package_c)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
