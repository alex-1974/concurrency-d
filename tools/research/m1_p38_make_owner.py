#!/usr/bin/env python3
"""P38 owned executor uses the exact-source P38 research pool."""
from pathlib import Path
import subprocess
import sys

def main():
    root,p23,out=map(Path,sys.argv[1:4])
    subprocess.run([sys.executable,str(root/"tools/research/m1_p23_make_owned.py"),
                    str(root/"source/concurrency/internal/owned_task.d"),str(p23)],check=True)
    s=p23.read_text()
    for old,new in (
      ("module concurrency.research.m1_p23_owned;",
       "module concurrency.research.m1_p38_owned;"),
      ("import concurrency.internal.submission_pool :",
       "import concurrency.research.m1_p38_pool :")):
        if s.count(old)!=1: raise ValueError("P38 owner source anchor drift: "+old)
        s=s.replace(old,new,1)
    old="    size_t acceptedCount()\n    {"
    if s.count(old)!=1: raise ValueError("P38 owner telemetry hook drift")
    s=s.replace(old,'''    auto researchWorkerCounters()
    {
        if (!isStopped())
            throw new Exception("P38 worker counters require stopped owner");
        return _pool.researchWorkerCounters();
    }

'''+old,1)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P38_OWNER_ROUTING_PASS")

if __name__=="__main__":
    main()
