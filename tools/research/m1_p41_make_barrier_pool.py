#!/usr/bin/env python3
"""P41 source-pinned pool overlay: halt worker after wakeGeneration, before search."""
from pathlib import Path
import sys,subprocess

def once(s,a,z):
    if s.count(a)!=1: raise ValueError("P41 pool anchor drift: "+a[:80])
    return s.replace(a,z,1)

def main():
    root,source,out=map(Path,sys.argv[1:4])
    tmp=out.with_suffix(".p38.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p38_make_pool.py"),
                        str(root),str(source),str(tmp)],check=True)
        s=tmp.read_text()
    finally:
        tmp.unlink(missing_ok=True)
    s=once(s,"module concurrency.research.m1_p38_pool;",
           "module concurrency.research.m1_p41_pool;")
    anchor="private final class TaskInbox"
    insertion="""package(concurrency) final class P41Barrier
{
    private import core.sync.mutex : Mutex;
    private import core.sync.condition : Condition;
    private Mutex mutex;
    private Condition changed;
    private bool reached;
    private bool released;
    this()
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
    }
    void waitForReached()
    {
        synchronized (mutex)
        {
            while (!reached)
                changed.wait();
        }
    }
    void release()
    {
        synchronized (mutex)
        {
            released = true;
            changed.notifyAll();
        }
    }
    void pause()
    {
        synchronized (mutex)
        {
            if (!reached)
            {
                reached = true;
                changed.notifyAll();
                while (!released)
                    changed.wait();
            }
        }
    }
}
"""
    s=once(s,anchor,insertion+anchor)
    s=once(s,"    private size_t _started;",
           "    private size_t _started;\n    private P41Barrier _p41Barrier;")
    s=once(s,"        void function(TaskRef) nothrow afterExecution = null)",
           "        void function(TaskRef) nothrow afterExecution = null,\n        P41Barrier p41Barrier = null)")
    s=once(s,"        _inbox = new TaskInbox(ingressCapacity);",
           "        _p41Barrier = p41Barrier;\n        _inbox = new TaskInbox(ingressCapacity);")
    s=once(s,"            const observed = _inbox.wakeGeneration();",
           """            const observed = _inbox.wakeGeneration();
            if (_p41Barrier !is null)
                _p41Barrier.pause();""")
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P41_POOL_BARRIER_GENERATED source_pinned=true")
if __name__=="__main__":main()
