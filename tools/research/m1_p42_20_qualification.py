#!/usr/bin/env python3
"""Source-pinned isolated P42.20 fixtures. Never modifies production modules."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REVIEW = ROOT / 'research/m1_task_lifetime/prototypes/p42_notification_coalescing'
PINS = {
    'tools/research/m1_p42_make_conditional_pool.py': 'c405e9947877ca6021cfc461b95c908a55efcafa3a5f06eb072f8a79a8baa6d6',
    'source/concurrency/internal/submission_pool.d': 'cdf437dde9046b64943c315f92892326fda45cf83ebfc19d71dd8ae4d0c6753e',
    'source/concurrency/internal/owned_task.d': '11129f5517bca73f6e6f3428d27983e99009381455a8f85df18cdb9b1bea4690',
}

def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('P42.20 source anchor drift: ' + old[:100])
    return text.replace(old, new, 1)


def run(command, *, expected=0, timeout=120):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout, end='', flush=True)
    if result.returncode != expected:
        raise RuntimeError(f'command returned {result.returncode}, expected {expected}: {command}')
    return result.stdout


def generate(folder, arm):
    source = ROOT / 'source/concurrency/internal/submission_pool.d'
    pool = folder / 'concurrency/research/m1_p42_pool.d'
    pool.parent.mkdir(parents=True)
    # Always use the historical minimal overlay measured in P42.18/19.
    run(['python3', str(ROOT / 'tools/research/m1_p42_make_conditional_pool.py'), str(source), str(pool)])
    text = pool.read_text()
    conditional = '''            if (_waiters != 0)
                _changed.notify();'''
    if arm == 'baseline':
        text = once(text, conditional, '            _changed.notify();')
    elif arm == 'silent':
        text = once(text, conditional, '            // Negative control: suppress publication notify.')
    if arm == 'no-local':
        text = once(text, '            ++_generation;\n            _changed.notify();\n        }\n    }\n\n    /**\n     * Atomically compare', '            ++_generation;\n            // Negative control: suppress local-work notify.\n        }\n    }\n\n    /**\n     * Atomically compare')
    # Save an UNINSTRUMENTED pool for the actual owned layer.
    pool.write_text(text)
    owned = (ROOT / 'source/concurrency/internal/owned_task.d').read_text()
    owned = once(owned, 'module concurrency.internal.owned_task;', 'module concurrency.research.p42_owned;')
    owned = once(owned, 'import concurrency.internal.submission_pool :', 'import concurrency.research.m1_p42_pool :')
    (pool.parent / 'p42_owned.d').write_text(owned)
    # Separate barrier-only pool; owned tests never import this module.
    text = once(text, 'module concurrency.research.m1_p42_pool;', 'module concurrency.research.p42_barrier_pool;')
    barrier = '''package(concurrency) final class P42Barrier
{
    import core.sync.mutex : Mutex;
    import core.sync.condition : Condition;
    Mutex mutex;
    Condition changed;
    size_t site;
    bool reached, released;
    this(size_t selected) { site = selected; mutex = new Mutex; changed = new Condition(mutex); }
    void pause(size_t at)
    {
        if (at != site) return;
        synchronized (mutex)
        {
            if (reached) return;
            reached = true;
            changed.notifyAll();
            while (!released) changed.wait();
        }
    }
    void waitReached()
    {
        synchronized (mutex) { while (!reached) changed.wait(); }
    }
    void release()
    {
        synchronized (mutex) { released = true; changed.notifyAll(); }
    }
}
'''
    text = once(text, 'private final class TaskInbox', barrier + '\nprivate final class TaskInbox')
    text = once(text, '    private size_t _started;', '    private size_t _started;\n    private P42Barrier _barrier;')
    text = once(text, '        void function(TaskRef) nothrow afterExecution = null)',
                '        void function(TaskRef) nothrow afterExecution = null, P42Barrier barrier = null, TaskRef[] initial = null)')
    text = once(text, '        _inbox = new TaskInbox(ingressCapacity);',
                '        _barrier = barrier;\n        _inbox = new TaskInbox(ingressCapacity);')
    text = once(text, '        _afterExecution = afterExecution;',
                '        foreach (task; initial) assert(_inbox.trySubmit(task) == SubmissionResult.accepted);\n        _afterExecution = afterExecution;')
    text = once(text, '    size_t acceptedCount()\n    {\n        return _inbox.acceptedCount();\n    }',
                '    void p42CloseInbox() { _inbox.close(); }\n    size_t acceptedCount()\n    {\n        return _inbox.acceptedCount();\n    }')
    text = once(text, '            const observed = _inbox.wakeGeneration();',
                '            if (_barrier !is null) _barrier.pause(1);\n            const observed = _inbox.wakeGeneration();\n            if (_barrier !is null) _barrier.pause(2);')
    text = once(text, '            _inbox.parkUnlessChanged(observed);',
                '            if (_barrier !is null) _barrier.pause(3);\n            _inbox.parkUnlessChanged(observed);')
    text = once(text, '                bool enqueued;',
                '                if (_barrier !is null) _barrier.pause(4);\n                bool enqueued;')
    (pool.parent / 'p42_barrier_pool.d').write_text(text)
    p19 = (ROOT / 'research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p19_owned_graph.d').read_text()
    p19 = once(p19, 'import concurrency.internal.owned_task :', 'import concurrency.research.p42_owned :')
    (folder / 'p19.d').write_text(p19)
    negative = (ROOT / 'research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p19_negative_safe.d').read_text()
    (folder / 'negative.d').write_text(once(negative, 'import concurrency.internal.owned_task :', 'import concurrency.research.p42_owned :'))
    for name in ['races', 'owned', 'handoff']:
        (folder / (name + '.d')).write_text((REVIEW / 'consumer' / (name + '.d')).read_text())
    configs = [{'name': name, 'mainSourceFile': name + '.d'} for name in ['races', 'owned', 'p19', 'handoff', 'negative']]
    (folder / 'dub.json').write_text(json.dumps({
        'name': 'p42-20-qualification', 'targetType': 'executable',
        'sourcePaths': ['concurrency'], 'importPaths': ['.'],
        'dependencies': {'concurrency-d': {'path': str(ROOT)}},
        'configurations': configs,
    }))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('compiler')
    args = parser.parse_args()
    for name, pin in PINS.items():
        digest = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        if digest != pin:
            raise ValueError(f'P42.20 source pin mismatch {name}: {digest}')
    run([args.compiler, '--version'])
    for arm in ['baseline', 'conditional', 'silent', 'no-local']:
        with tempfile.TemporaryDirectory(prefix='p42-20-') as temporary:
            folder = Path(temporary)
            generate(folder, arm)
            cmd = ['dub', 'run', '--root=' + str(folder), '--compiler=' + args.compiler, '--build=debug']
            if arm in ('silent', 'no-local'):
                run(['dub', 'build', '--root=' + str(folder), '--compiler=' + args.compiler,
                     '--build=debug', '--config=races'])
                code = 23 if arm == 'silent' else 24
                output = run([str(folder / 'p42-20-qualification'), arm], expected=code)
                marker = 'P42_20_SILENT_CONTROL_DETECTED' if arm == 'silent' else 'P42_20_LOCAL_CONTROL_DETECTED'
                if marker not in output:
                    raise RuntimeError('negative control exited for an unrelated reason')
                continue
            for config in ['races', 'owned', 'p19', 'handoff']:
                output = run(cmd + ['--config=' + config])
                marker = {'races': 'P42_20_RACES_PASS', 'owned': 'P42_20_OWNED_PASS', 'p19': 'P19_REAL_OWNED_GC_PASS', 'handoff': 'P42_20_HANDOFF_PASS'}[config]
                if marker not in output:
                    raise RuntimeError('missing positive marker: ' + marker)
            result = subprocess.run(['dub', 'build', '--root=' + str(folder), '--compiler=' + args.compiler,
                                     '--build=debug', '--config=negative'], cwd=ROOT, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
            if result.returncode == 0 or '@safe' not in result.stdout or '@system' not in result.stdout or 'submit' not in result.stdout:
                raise RuntimeError('negative capture-safety fixture did not reject as intended:\n' + result.stdout)
            print('P42_20_SAFE_NEGATIVE_PASS arm=' + arm, flush=True)
            if Path(args.compiler).name.startswith('ldc'):
                data = json.loads((folder / 'dub.json').read_text())
                data['dflags'] = ['-O3']
                (folder / 'dub.json').write_text(json.dumps(data))
                for config in ['races', 'owned', 'p19', 'handoff']:
                    output = run(cmd + ['--config=' + config, '--force'])
                    marker = {'races': 'P42_20_RACES_PASS', 'owned': 'P42_20_OWNED_PASS',
                              'p19': 'P19_REAL_OWNED_GC_PASS', 'handoff': 'P42_20_HANDOFF_PASS'}[config]
                    if marker not in output:
                        raise RuntimeError('missing optimized marker: ' + marker)
            print('P42_20_ARM_PASS arm=' + arm, flush=True)
    print('P42_20_QUALIFICATION_PASS compiler=' + args.compiler, flush=True)

if __name__ == '__main__':
    main()
