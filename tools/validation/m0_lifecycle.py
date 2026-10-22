#!/usr/bin/env python3
"""Actual M0 lifecycle checks plus isolated source-overlay fault probes.

Synthetic failures exercise fail-stop/cleanup branches; no invalid OS thread
operation is attempted. Production modules contain no fault-injection switches.
"""
import argparse
import json
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
POOL = 'source/concurrency/internal/submission_pool.d'
OWNER = 'source/concurrency/internal/owned_task.d'


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('M0 lifecycle probe anchor drift: ' + old)
    return text.replace(old, new, 1)


def execute(command, expected=0, marker=None, timeout=120):
    def no_core():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout, preexec_fn=no_core)
    print(result.stdout, end='', flush=True)
    if result.returncode != expected or (marker and marker not in result.stdout):
        raise RuntimeError(f'expected code {expected} and {marker}, got {result.returncode}: {command}')
    return result.stdout


def prepare(folder, fault):
    shutil.copytree(ROOT / 'source', folder / 'source')
    shutil.copyfile(ROOT / 'tests/lifecycle/main.d', folder / 'main.d')
    (folder / 'dub.json').write_text(json.dumps({
        'name': 'm0-lifecycle-probe', 'targetType': 'executable',
        'sourcePaths': ['source'], 'importPaths': ['source'], 'mainSourceFile': 'main.d',
        'dependencies': {'containers-d': '0.2.0'},
    }))
    pool = (folder / POOL).read_text()
    owner = (folder / OWNER).read_text()
    if fault == 'start':
        pool = once(pool, '            worker.start();', '''            worker.start();
            // Simulate post-launch failure before caller _started accounting.
            import core.thread : ThreadError;
            throw new ThreadError("M0 injected after launch");''')
    elif fault == 'join':
        pool = once(pool, '                unhandled = _workers[index].join(false);',
                    '            { import core.thread : ThreadException; throw new ThreadException("M0 injected native join uncertainty"); }')
    elif fault == 'close':
        pool = once(pool, '            _inbox.close();', '            throw new Exception("M0 injected close failure");')
    elif fault == 'worker':
        pool = once(pool, '                workerLoop(workerIndex);', '                throw new Error("M0 injected worker failure");')
    elif fault == 'returned-worker-error':
        pool = once(pool, '                unhandled = _workers[index].join(false);', '''            {
                _workers[index].join(false);
                unhandled = new Error("M0 injected returned worker error");
            }''')
    elif fault == 'drain':
        pool = once(pool, '        if (!_inbox.isDrained())', '        if (true) // synthetic failed drain invariant')
    elif fault == 'owner':
        owner = once(owner, '            _pool.closeAndJoin();', '            throw new Exception("M0 injected owner shutdown failure");')
    elif fault == 'owner-setup':
        owner = once(owner, '        _lifecycleChanged = new Condition(_mutex);',
                     '        throw new Exception("M0 injected before launch");')
        pool = once(pool, '            worker.start();', '''            worker.start();
            import core.stdc.stdio : fputs, stderr;
            fputs("M0_PROBE_UNEXPECTED_START\\n", stderr);''')
    elif fault.startswith('construction-'):
        index = int(fault.split('-')[1])
        pool = once(pool, '                _workers[index] = makeWorker(index);',
                    f'                if (index == {index}) throw new Exception("M0 injected before launch");\n'
                    '                _workers[index] = makeWorker(index);')
        pool = once(pool, '                unhandled = _workers[index].join(false);', '''            {
                unhandled = _workers[index].join(false);
                import core.stdc.stdio : fputs, stderr;
                fputs("M0_PROBE_CONFIRMED_JOIN\\n", stderr);
            }''')
    (folder / POOL).write_text(pool)
    (folder / OWNER).write_text(owner)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('compiler')
    args = parser.parse_args()
    execute([args.compiler, '--version'])
    modes = ['debug', 'release']
    if Path(args.compiler).name.startswith('ldc'):
        modes.append('optimized')
    for mode in modes:
        with tempfile.TemporaryDirectory(prefix='m0-lifecycle-') as directory:
            folder = Path(directory)
            prepare(folder, 'normal')
            descriptor = json.loads((folder / 'dub.json').read_text())
            if mode == 'optimized':
                descriptor['dflags'] = ['-O3']
                (folder / 'dub.json').write_text(json.dumps(descriptor))
            build = 'debug' if mode == 'optimized' else mode
            base = ['dub', 'build', '--root=' + str(folder), '--compiler=' + args.compiler, '--build=' + build, '--force']
            execute(base)
            execute([str(folder / 'm0-lifecycle-probe')], marker='M0_LIFECYCLE_PASS', timeout=30)
            print('M0_NORMAL_PASS mode=' + mode, flush=True)
            # Rebuild only the source delta for each fault; all run separately.
            for fault in ['start', 'join', 'close', 'worker', 'returned-worker-error', 'drain', 'owner', 'construction-0', 'construction-1', 'owner-setup']:
                # Restore exact current production sources before each overlay.
                # prepare() also initializes the descriptor, so use a separate
                # pristine temporary fixture then transfer its mutated sources.
                with tempfile.TemporaryDirectory(prefix='m0-fault-source-') as source_dir:
                    source_folder = Path(source_dir)
                    prepare(source_folder, fault)
                    shutil.rmtree(folder / 'source')
                    shutil.copytree(source_folder / 'source', folder / 'source')
                execute(base)
                if fault.startswith('construction-') or fault == 'owner-setup':
                    output = execute([str(folder / 'm0-lifecycle-probe'), 'construction-failure'],
                                     marker='M0_CONSTRUCTION_CLEANUP_PASS', timeout=15)
                    expected_joins = 0 if fault == 'owner-setup' else int(fault.split('-')[1])
                    if 'M0_PROBE_UNEXPECTED_START' in output:
                        raise RuntimeError('owner setup allocated after native worker launch')
                    if output.count('M0_PROBE_CONFIRMED_JOIN') != expected_joins:
                        raise RuntimeError('partial-construction cleanup did not join every confirmed worker')
                else:
                    phase = 'WORKER' if fault == 'returned-worker-error' else fault.upper()
                    execute([str(folder / 'm0-lifecycle-probe'), 'fatal', fault], expected=-signal.SIGABRT,
                            marker='CONCURRENCY_FATAL_' + phase, timeout=15)
                print(f'M0_FAULT_PASS mode={mode} fault={fault}', flush=True)
    print('M0_LIFECYCLE_GATE_PASS compiler=' + args.compiler, flush=True)


if __name__ == '__main__':
    main()
