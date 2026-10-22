#!/usr/bin/env python3
"""P36 research-only consumer derived from source-pinned P35 consumer."""
from pathlib import Path
import subprocess
import sys


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('P36 consumer drift: ' + before[:64])
    return text.replace(before, after, 1)


def main():
    root, source, target = map(Path, sys.argv[1:4])
    intermediate = target.with_suffix('.p35.tmp')
    try:
        subprocess.run([sys.executable, str(root/'tools/research/m1_p35_make_consumer.py'),
                        str(source), str(intermediate)], check=True)
        text = intermediate.read_text()
    finally:
        intermediate.unlink(missing_ok=True)
    text = once(text, 'module concurrency.research.p35_generational_owner;',
                'module concurrency.research.p36_generational_owner;')
    mapping = {
        'm1_p35_owned': 'm1_p36_owned',
        'p35Take': 'p36Take',
        'p35Calls': 'p36Calls',
        'p35WaitNs': 'p36CapacityNs',
        'p35HoldNs': 'p36ConstructNs',
        'observed.waitNs': 'observed.capacityNs',
        'observed.holdNs': 'observed.constructNs',
        'owner_wait_ns': 'capacity_ns',
        'owner_hold_ns': 'construct_ns',
        'P35_OWNER_MUTEX_BENCHMARK_PASS': 'P36_PHASE_BENCHMARK_PASS',
    }
    for before, after in mapping.items():
        if before not in text:
            raise ValueError('P36 missing consumer mapping '+before)
        text = text.replace(before, after)
    header = 'ulong p36Calls, p36CapacityNs, p36ConstructNs;'
    if text.count(header) != 2:
        raise ValueError('P36 two telemetry declarations missing')
    text = text.replace(header,
        'ulong p36Calls, p36CapacityNs, p36ConstructNs, p36RetainNs, p36PublishNs;')
    text = once(text,
        '            stats.p36ConstructNs = observed.constructNs;',
        '            stats.p36ConstructNs = observed.constructNs;'+chr(10)+
        '            stats.p36RetainNs = observed.retainNs;'+chr(10)+
        '            stats.p36PublishNs = observed.publishNs;')
    text = once(text,
        '            p36ConstructNs += stat.p36ConstructNs;',
        '            p36ConstructNs += stat.p36ConstructNs;'+chr(10)+
        '            p36RetainNs += stat.p36RetainNs;'+chr(10)+
        '            p36PublishNs += stat.p36PublishNs;')
    text = once(text,
        'p36Calls, ",", p36CapacityNs, ",", p36ConstructNs);',
        'p36Calls, ",", p36CapacityNs, ",", p36ConstructNs, ",",'+chr(10)+
        '            p36RetainNs, ",", p36PublishNs);')
    text = once(text, 'capacity_ns,construct_ns',
                     'capacity_ns,construct_ns,retain_ns,publish_ns')
    text = once(text,
        '            const startBytes = GC.allocatedInCurrentThread();',
        '            // Reset TLS at the start of this measured producer scope.'+chr(10)+
        '            auto p36Prior = p36Take();'+chr(10)+
        '            const startBytes = GC.allocatedInCurrentThread();')
    text = once(text, '            stats.p36Calls = observed.calls;',
                '            stats.p36Calls = observed.calls;'+chr(10)+
                '            assert(stats.p36Calls == (mode == P31Mode.m0 ? 0 : stats.attempts));')
    text = once(text,
        '            assert(stats.p36Calls == (mode == P31Mode.m0 ? 0 : stats.attempts));',
        '            check(stats.p36Calls == (mode == P31Mode.m0 ? 0 : stats.attempts),'+chr(10)+
        '                  "P36 thread-local owner-call mismatch");')
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(text)
    print('P36_CONSUMER_PIN_PASS')

if __name__ == '__main__':
    main()
