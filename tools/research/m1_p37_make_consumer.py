#!/usr/bin/env python3
"""P37 consumer from pinned P31 via validated P35 telemetry scaffold."""
from pathlib import Path
import subprocess
import sys

def once(s,old,new):
    if s.count(old)!=1: raise ValueError("P37 consumer anchor drift: "+old[:72])
    return s.replace(old,new,1)

def main():
    root,original,out=map(Path,sys.argv[1:4])
    tmp=out.with_suffix(".p35.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p35_make_consumer.py"),
                        str(original),str(tmp)],check=True)
        s=tmp.read_text()
    finally:
        tmp.unlink(missing_ok=True)
    s=once(s,"module concurrency.research.p35_generational_owner;",
           "module concurrency.research.p37_generational_owner;")
    s=once(s,"import concurrency.research.m1_p35_owned : OwnedTaskExecutor, p35Take;",
           "import concurrency.research.m1_p37_owned : OwnedTaskExecutor;\n"
           "import concurrency.research.m1_p37_pool : p37Take;")
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P37_CONSUMER_SOURCE_PIN_PASS")

if __name__=="__main__":
    main()
