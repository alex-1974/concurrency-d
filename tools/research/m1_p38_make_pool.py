#!/usr/bin/env python3
"""P38 research-only worker wake-accounting overlay from source-pinned P37."""
from pathlib import Path
import subprocess
import sys

def once(s,old,new):
    if s.count(old)!=1:
        raise ValueError("P38 source-anchor drift: "+old[:75])
    return s.replace(old,new,1)

def main():
    root,source,out=map(Path,sys.argv[1:4])
    intermediate=out.with_suffix(".p37.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p37_make_pool.py"),
            str(source),str(intermediate)],check=True)
        s=intermediate.read_text()
    finally:
        intermediate.unlink(missing_ok=True)
    s=once(s,"module concurrency.research.m1_p37_pool;",
           "module concurrency.research.m1_p38_pool;")
    s=once(s,"private final class TaskInbox",
        """package(concurrency) struct P38WorkerCounters
{
    ulong parkCalls, waitEntries, waitReturns, generationChanges;
}
private P38WorkerCounters p38ThreadCounters;
private final class TaskInbox""")
    s=once(s,"    void parkUnlessChanged(size_t observed)\n    {",
        """    void parkUnlessChanged(size_t observed)
    {
        ++p38ThreadCounters.parkCalls;""")
    s=once(s,"                ++_parkCount;\n                _changed.wait();",
        """                ++_parkCount;
                ++p38ThreadCounters.waitEntries;
                _changed.wait();
                ++p38ThreadCounters.waitReturns;""")
    s=once(s,"    private size_t _started;",
        """    private size_t _started;
    private P38WorkerCounters[] _p38Workers;
    private bool _p38Joined;""")
    s=once(s,"        _workers = new Thread[workerCount];",
        """        _workers = new Thread[workerCount];
        _p38Workers = new P38WorkerCounters[workerCount];""")
    s=once(s,"            workerLoop(workerIndex);",
        """            p38ThreadCounters = P38WorkerCounters.init;
            workerLoop(workerIndex);
            _p38Workers[workerIndex] = p38ThreadCounters;""")
    shutdown=s.index("    void closeAndJoin()")
    leading, trailing = s[:shutdown], s[shutdown:]
    trailing=once(trailing,"        foreach (index; 0 .. _started)\n            _workers[index].join();",
        "        foreach (index; 0 .. _started)"+chr(10)+
        "            _workers[index].join();"+chr(10)+
        "        _p38Joined = true;")
    s=leading+trailing
    pool_start=s.index("package(concurrency) final class SubmissionWorkerPool")
    prefix,body=s[:pool_start],s[pool_start:]
    body=once(body,"    size_t acceptedCount()\n    {",
        """    P38WorkerCounters[] researchWorkerCounters()
    {
        if (!_p38Joined)
            throw new Exception("P38 counters require closeAndJoin");
        return _p38Workers.dup;
    }

    size_t acceptedCount()
    {""")
    s=prefix+body
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P38_WORKER_OVERLAY_GENERATED source_pinned=true")

if __name__=="__main__":
    main()
