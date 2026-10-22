#!/usr/bin/env python3
"""Public-only consumers and targeted compile-negative API boundary fixtures."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'tests/public_api/negative'


def execute(command, marker=None, timeout=120):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout, end='', flush=True)
    if result.returncode != 0 or (marker and marker not in result.stdout):
        raise RuntimeError(f'public API gate failed: {command}, code={result.returncode}, marker={marker}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('compiler')
    args = parser.parse_args()
    execute([args.compiler, '--version'])
    for build in ['debug', 'release']:
        execute(['dub', 'run', '--root=' + str(ROOT / 'tests/public_api'), '--compiler=' + args.compiler,
                 '--build=' + build, '--config=normal', '--force'], marker='PUBLIC_API_PASS')
        execute(['dub', 'run', '--root=' + str(ROOT / 'examples/cpu-executor'), '--compiler=' + args.compiler,
                 '--build=' + build, '--force'], marker='PUBLIC_CPU_PASS')
    if Path(args.compiler).name.startswith('ldc'):
        execute(['dub', 'run', '--root=' + str(ROOT / 'tests/public_api'), '--compiler=' + args.compiler,
                 '--build=debug', '--config=optimized', '--force'], marker='PUBLIC_API_PASS')

    # Each whole-source negative fixture is compiled against the actual library.
    # Matching the intended diagnostic prevents unrelated dependency/link errors
    # from being accepted as an API rejection.
    checks = {
        'safe_submit': [r'@safe', r'@system', r'submit'],
        'move_callable': [r'supportedTask', r'submit'],
        'move_result': [r'supportedTask', r'submit'],
        'assign_result': [r'supportedTask', r'submit'],
        'not_callable': [r'supportedTask', r'submit'],
        'handle_constructor': [r'TaskHandle', r'constructor|this|accessible'],
        'result_cell': [r'ResultCell', r'accessible|package|not visible'],
        'raw_transport': [r'TaskRef', r'accessible|package|not visible'],
        'private_owner': [r'_impl', r'accessible|private|not visible|no property'],
    }
    with tempfile.TemporaryDirectory(prefix='m0-public-negative-') as temporary:
        folder = Path(temporary)
        for name, patterns in checks.items():
            (folder / 'main.d').write_text((FIXTURES / (name + '.d')).read_text())
            (folder / 'dub.json').write_text(json.dumps({
                'name': 'm0-public-negative', 'targetType': 'executable',
                'sourcePaths': [], 'mainSourceFile': 'main.d',
                'dependencies': {'concurrency-d': {'path': str(ROOT)}},
            }))
            command = ['dub', 'build', '--root=' + str(folder), '--compiler=' + args.compiler,
                       '--build=debug', '--force']
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=120)
            if result.returncode == 0 or any(not re.search(pattern, result.stdout, re.I) for pattern in patterns):
                print(result.stdout, end='', flush=True)
                raise RuntimeError('fixture did not reject at intended public boundary: ' + name)
            print('PUBLIC_NEGATIVE_PASS fixture=' + name, flush=True)
    print('M0_PUBLIC_API_GATE_PASS compiler=' + args.compiler, flush=True)


if __name__ == '__main__':
    main()
