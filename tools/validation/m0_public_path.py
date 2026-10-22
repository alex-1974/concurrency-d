#!/usr/bin/env python3
"""Preserved, same-work LDC public/internal diagnostic; NOT release acceptance."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path, help='new result directory; never overwrite')
    parser.add_argument('--compiler', default='ldc2')
    parser.add_argument('--pairs', type=int, default=8)
    parser.add_argument('--tasks', type=int, default=16384)
    args = parser.parse_args()
    if not Path(args.compiler).name.startswith('ldc') or args.pairs < 1 or not 4 <= args.tasks <= 2**32 - 1:
        parser.error('requires LDC, positive pair count, and 4..uint.max tasks')
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output.resolve()
    (out / 'run_state.txt').write_text('INCOMPLETE\n')
    def capture(command):
        return subprocess.check_output(command, cwd=ROOT, text=True, stderr=subprocess.STDOUT, timeout=120)
    metadata = {
        'status': 'LOCAL_DIAGNOSTIC_ONLY_NOT_RELEASE_ACCEPTANCE',
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'head': capture(['git', 'rev-parse', 'HEAD']).strip(),
        'worktree': capture(['git', 'status', '--porcelain=v1', '-uno']),
        'compiler': capture([args.compiler, '--version']), 'dub': capture(['dub', '--version']),
        'platform': platform.platform(), 'pairs_per_scenario': args.pairs,
        'tasks_per_process': args.tasks,
        'limits': ['single session; no thermal/frequency qualification',
                   'one same-work binary; owner startup/submission/results/join timed',
                   'no timing threshold; not a public release or speedup claim'],
    }
    sources = sorted((ROOT / 'source').rglob('*.d')) + [ROOT / 'benchmarks/executor/main.d', ROOT / 'dub.sdl', Path(__file__).resolve()]
    metadata['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (out / 'build.log').write_text(capture(['dub', 'build', '--config=executor-benchmark',
        '--compiler=' + args.compiler, '--build=release', '--force']))
    binary = ROOT / 'concurrency-executor-benchmark'
    metadata['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    rows, summaries = [], []
    with (out / 'raw.log').open('x') as raw, (out / 'warmups.log').open('x') as warm:
        for producers, workers in [(1, 1), (4, 4)]:
            for arm in ['internal', 'public']:
                warm.write(capture([str(binary), arm, str(producers), str(workers), str(args.tasks)]))
                warm.flush()
            ratios = []
            for pair in range(1, args.pairs + 1):
                values, checksums = {}, []
                for arm in (['internal', 'public'] if pair % 2 else ['public', 'internal']):
                    line = capture([str(binary), arm, str(producers), str(workers), str(args.tasks)]).strip()
                    raw.write(line + '\n'); raw.flush()
                    match = re.fullmatch(r'PUBLIC_PATH_DIAGNOSTIC arm=(\w+) producers=(\d+) workers=(\d+) tasks=(\d+) elapsed_ns=(\d+) checksum=(\d+)', line)
                    if not match or (match[1], int(match[2]), int(match[3]), int(match[4])) != (arm, producers, workers, args.tasks):
                        raise RuntimeError('invalid diagnostic row: ' + line)
                    elapsed, checksum = int(match[5]), int(match[6])
                    if elapsed <= 0: raise RuntimeError('invalid timing')
                    values[arm] = elapsed; checksums.append(checksum)
                    rows.append(dict(producers=producers, workers=workers, tasks=args.tasks,
                                     pair=pair, arm=arm, elapsed_ns=elapsed, checksum=checksum))
                if checksums[0] != checksums[1]: raise RuntimeError('arm checksum mismatch')
                ratios.append(values['public'] / values['internal'])
            summaries.append(dict(producers=producers, workers=workers,
                median_public_internal=statistics.median(ratios), min_ratio=min(ratios), max_ratio=max(ratios)))
    metadata['ended_utc'] = datetime.now(timezone.utc).isoformat()
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (out / 'results.json').write_text(json.dumps(dict(rows=rows, summary=summaries), indent=2) + '\n')
    (out / 'run_state.txt').write_text('COMPLETE\n')
    print(json.dumps(summaries))


if __name__ == '__main__':
    main()
