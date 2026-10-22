#!/usr/bin/env python3
"""P40 owner routes the source-pinned P39 owner to the P40 worker pool."""
from pathlib import Path
import subprocess,sys
def main():
    root,p23,out=map(Path,sys.argv[1:4])
    tmp=out.with_suffix(".p39.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p39_make_owner.py"),str(root),str(p23),str(tmp)],check=True)
        s=tmp.read_text()
    finally:
        tmp.unlink(missing_ok=True)
    for old,new in (("module concurrency.research.m1_p39_owned;","module concurrency.research.m1_p40_owned;"),("import concurrency.research.m1_p39_pool :","import concurrency.research.m1_p40_pool :")):
        if s.count(old)!=1: raise ValueError("P40 owner drift: "+old)
        s=s.replace(old,new,1)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P40_OWNER_ROUTING_PASS")
if __name__=="__main__": main()
