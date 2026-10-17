#!/usr/bin/env python3
"""Generate a P40 research-only post-wait outcome overlay from pinned P39."""
from pathlib import Path
import subprocess
import sys

def once(src,old,new):
    if src.count(old)!=1:
        raise ValueError("P40 source anchor drift: "+old[:75])
    return src.replace(old,new,1)

def main():
    root,source,out=map(Path,sys.argv[1:4])
    tmp=out.with_suffix(".p39.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p39_make_pool.py"),
                        str(root),str(source),str(tmp)],check=True)
        s=tmp.read_text()
    finally:
        tmp.unlink(missing_ok=True)
    s=once(s,"module concurrency.research.m1_p39_pool;",
           "module concurrency.research.m1_p40_pool;")
    s=once(s,"    ulong parkCalls, waitEntries, waitReturns, generationChanges;",
           "    ulong parkCalls, waitEntries, waitReturns, generationChanges;\n"
           "    ulong postLocal, postInbox, postSteal, postRepark, postDrained;")
    start=s.index("    private void workerLoop(size_t self)")
    finish=s.index("\n}\n\nversion (unittest)",start)
    prefix,loop,suffix=s[:start],s[start:finish],s[finish:]
    loop=once(loop,"        for (;;)\n        {",
        """        bool p40Pending;
        for (;;)
        {""")
    loop=once(loop,"            if (local.found)\n            {",
        """            if (local.found)
            {
                if (p40Pending)
                {
                    ++p38ThreadCounters.postLocal;
                    p40Pending = false;
                }""")
    loop=once(loop,"            if (taken != 0)\n            {",
        """            if (taken != 0)
            {
                if (p40Pending)
                {
                    ++p38ThreadCounters.postInbox;
                    p40Pending = false;
                }""")
    loop=once(loop,"            if (foundWork)\n                continue;",
        """            if (foundWork)
            {
                if (p40Pending)
                {
                    ++p38ThreadCounters.postSteal;
                    p40Pending = false;
                }
                continue;
            }""")
    loop=once(loop,"            if (_inbox.isDrained())\n                break;",
        """            if (_inbox.isDrained())
            {
                if (p40Pending)
                {
                    ++p38ThreadCounters.postDrained;
                    p40Pending = false;
                }
                break;
            }""")
    loop=once(loop,"            _inbox.parkUnlessChanged(observed);",
        """            if (p40Pending)
            {
                ++p38ThreadCounters.postRepark;
                p40Pending = false;
            }
            const p40Before = p38ThreadCounters.waitReturns;
            _inbox.parkUnlessChanged(observed);
            const p40Delta = p38ThreadCounters.waitReturns - p40Before;
            if (p40Delta != 0)
            {
                // Earlier returns within the same predicate loop did not
                // transfer control to the worker search. Classify them as
                // internal re-waits; only the final return is pending.
                p38ThreadCounters.postRepark += p40Delta - 1;
                p40Pending = true;
            }""")
    s=prefix+loop+suffix
    s=once(s,"            _p38Workers[workerIndex] = p38ThreadCounters;",
        """            assert(p38ThreadCounters.postLocal +
                p38ThreadCounters.postInbox +
                p38ThreadCounters.postSteal +
                p38ThreadCounters.postRepark +
                p38ThreadCounters.postDrained ==
                p38ThreadCounters.waitReturns);
            _p38Workers[workerIndex] = p38ThreadCounters;""")
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P40_POST_WAIT_GENERATED source_pinned=true")

if __name__=="__main__":
    main()
