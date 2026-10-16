#!/usr/bin/env python3
"""Generate a P35-only observation copy from the exact P23 owner."""
from pathlib import Path
import subprocess
import sys

def main():
    root, p23, p35 = map(Path, sys.argv[1:4])
    subprocess.run([sys.executable, str(root / 'tools/research/m1_p23_make_owned.py'),
                    str(root / 'source/concurrency/internal/owned_task.d'), str(p23)],check=True)
    text = p23.read_text()
    text = text.replace('module concurrency.research.m1_p23_owned;',
                        'module concurrency.research.m1_p35_owned;')
    if text.count('module concurrency.research.m1_p35_owned;') != 1:
        raise ValueError('P35 module drift')
    point = 'import core.sync.semaphore : Semaphore;'
    if text.count(point) != 1:
        raise ValueError('P35 stats import drift')
    stats = '''
import core.time : MonoTime;

package(concurrency) struct P35Stats
{
    ulong calls, constructed, rejected, waitNs, holdNs;
}
private P35Stats p35ThreadStats;
package(concurrency) P35Stats p35Take()
{
    auto data = p35ThreadStats;
    p35ThreadStats = P35Stats.init;
    return data;
}
'''
    text = text.replace(point, point + stats)
    start = '        TaskHandle!R handle;' + chr(10)*2 + '        synchronized (_mutex)' + chr(10) + '        {'
    if text.count(start) != 1:
        raise ValueError('P35 submission start drift')
    timed = '''        TaskHandle!R handle;
        ++p35ThreadStats.calls;
        version (P35Timed)
            const p35Before = MonoTime.currTime;
        synchronized (_mutex)
        {
            MonoTime p35Entered;
            version (P35Timed)
            {
                p35Entered = MonoTime.currTime;
                p35ThreadStats.waitNs += cast(ulong)
                    (p35Entered - p35Before).total!"nsecs";
            }
            // Must be in the synchronized block, not the version block:
            // its exit corresponds to releasing the executor mutex.
            scope (exit)
            {
                version (P35Timed)
                {
                    const p35Exit = MonoTime.currTime;
                    p35ThreadStats.holdNs += cast(ulong)
                        (p35Exit - p35Entered).total!"nsecs";
                }
            }'''
    text = text.replace(start, timed)
    p35.parent.mkdir(parents=True,exist_ok=True)
    p35.write_text(text)
    print('P35_OWNER_OVERLAY_PIN_PASS')

if __name__ == '__main__':
    main()
