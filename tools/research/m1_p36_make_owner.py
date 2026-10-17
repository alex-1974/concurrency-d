#!/usr/bin/env python3
"""P36: generate a source-pinned owned critical-phase probe."""
from pathlib import Path
import subprocess
import sys

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('P36 source anchor drift: ' + old[:64])
    return text.replace(old, new, 1)

def main():
    root, p23, p36 = map(Path, sys.argv[1:4])
    subprocess.run([sys.executable, str(root/'tools/research/m1_p23_make_owned.py'),
                    str(root/'source/concurrency/internal/owned_task.d'),str(p23)],check=True)
    text = p23.read_text()
    text = replace_once(text,'module concurrency.research.m1_p23_owned;',
                       'module concurrency.research.m1_p36_owned;')
    text = replace_once(text, 'import core.sync.semaphore : Semaphore;',
        'import core.sync.semaphore : Semaphore;'+chr(10)+'import core.time : MonoTime;')
    fields = ("calls", "admitted", "budgetCold", "capacityNs",
              "constructNs", "retainNs", "publishNs")
    struct = ("package(concurrency) struct P36Stats"+chr(10)+"{"+chr(10)+
              "".join("    ulong "+field+";"+chr(10) for field in fields)+
              "}"+chr(10)+"private P36Stats p36Local;"+chr(10)+
              "package(concurrency) P36Stats p36Take()"+chr(10)+"{"+chr(10)+
              "    auto result = p36Local;"+chr(10)+
              "    p36Local = P36Stats.init;"+chr(10)+
              "    return result;"+chr(10)+"}"+chr(10))
    text = replace_once(text, 'import core.time : MonoTime;',
                        'import core.time : MonoTime;'+chr(10)+struct)
    begin = '        TaskHandle!R handle;'+chr(10)*2+'        synchronized (_mutex)'
    text = replace_once(text, begin,
        '        TaskHandle!R handle;'+chr(10)+
        '        ++p36Local.calls;'+chr(10)+
        '        synchronized (_mutex)')
    text = replace_once(text, '                reapCompletedUnderLock();',
        '                ++p36Local.budgetCold;'+chr(10)+
        '                reapCompletedUnderLock();')
    text = replace_once(text, '            auto cell = new ResultCell!R();',
        '            version (P36Timed)'+chr(10)+
        '                const p36BuildStart = MonoTime.currTime;'+chr(10)+
        '            auto cell = new ResultCell!R();')
    text = replace_once(text,
        '            auto node = new OwnedNode!(F, R)(callable, cell);',
        '            auto node = new OwnedNode!(F, R)(callable, cell);'+chr(10)+
        '            ++p36Local.admitted;'+chr(10)+
        '            version (P36Timed)'+chr(10)+
        '                p36Local.constructNs += cast(ulong)'+chr(10)+
        '                    (MonoTime.currTime - p36BuildStart).total!"nsecs";')
    text = replace_once(text, '            _retained ~= RetainedTask(node, node.returnedFlag());',
        '            version (P36Timed)'+chr(10)+
        '                const p36RetainStart = MonoTime.currTime;'+chr(10)+
        '            _retained ~= RetainedTask(node, node.returnedFlag());'+chr(10)+
        '            version (P36Timed)'+chr(10)+
        '                p36Local.retainNs += cast(ulong)'+chr(10)+
        '                    (MonoTime.currTime - p36RetainStart).total!"nsecs";')
    text = replace_once(text, '            const status = _pool.trySubmit(node.reference());',
        '            version (P36Timed)'+chr(10)+
        '                const p36PublishStart = MonoTime.currTime;'+chr(10)+
        '            const status = _pool.trySubmit(node.reference());'+chr(10)+
        '            version (P36Timed)'+chr(10)+
        '                p36Local.publishNs += cast(ulong)'+chr(10)+
        '                    (MonoTime.currTime - p36PublishStart).total!"nsecs";')
    text = replace_once(text, '            if (_lifecycle != Lifecycle.running)',
        '            version (P36Timed)'+chr(10)+
        '                const p36CapacityStart = MonoTime.currTime;'+chr(10)+
        '            if (_lifecycle != Lifecycle.running)')
    text = replace_once(text,
        '            version (P36Timed)'+chr(10)+
        '                const p36BuildStart = MonoTime.currTime;',
        '            version (P36Timed)'+chr(10)+
        '                p36Local.capacityNs += cast(ulong)'+chr(10)+
        '                    (MonoTime.currTime - p36CapacityStart).total!"nsecs";'+chr(10)+
        '            version (P36Timed)'+chr(10)+
        '                const p36BuildStart = MonoTime.currTime;')
    p36.parent.mkdir(parents=True,exist_ok=True)
    p36.write_text(text)
    print('P36_OWNER_SOURCE_PIN_PASS')

if __name__ == '__main__':
    main()
