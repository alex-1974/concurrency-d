#!/usr/bin/env python3
"""Route P39 owned task fixture to notification-counted pool."""
from pathlib import Path
import subprocess
import sys
def main():
    root,p23,out=map(Path,sys.argv[1:4])
    temp=out.with_suffix(".p38.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p38_make_owner.py"),str(root),str(p23),str(temp)],check=True)
        s=temp.read_text()
    finally:
        temp.unlink(missing_ok=True)
    for old,new in (("module concurrency.research.m1_p38_owned;","module concurrency.research.m1_p39_owned;"),
                    ("import concurrency.research.m1_p38_pool :","import concurrency.research.m1_p39_pool :")):
        if s.count(old)!=1: raise ValueError("P39 owner anchor drift")
        s=s.replace(old,new,1)
    marker="    auto researchWorkerCounters()"
    if s.count(marker)!=1: raise ValueError("P39 owner accessor drift")
    s=s.replace(marker,'''    auto researchNotificationStats()
    {
        if (!isStopped())
            throw new Exception("P39 notification stats require stopped owner");
        return _pool.researchNotificationStats();
    }

'''+marker,1)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P39_OWNER_ROUTING_PASS")
if __name__=="__main__": main()
