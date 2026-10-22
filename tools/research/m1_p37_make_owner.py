#!/usr/bin/env python3
"""Generate research P37 owner routed to the source-pinned inbox pool."""
from pathlib import Path
import subprocess
import sys

def main():
    root,p23,out=map(Path,sys.argv[1:4])
    subprocess.run([sys.executable,str(root/"tools/research/m1_p23_make_owned.py"),
                    str(root/"source/concurrency/internal/owned_task.d"),str(p23)],check=True)
    text=p23.read_text()
    replacements=[
        ("module concurrency.research.m1_p23_owned;",
         "module concurrency.research.m1_p37_owned;"),
        ("import concurrency.internal.submission_pool :",
         "import concurrency.research.m1_p37_pool :")
    ]
    for old,new in replacements:
        if text.count(old)!=1: raise ValueError("P37 owner anchor drift: "+old)
        text=text.replace(old,new,1)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(text)
    print("P37_OWNER_ROUTING_PASS")

if __name__=="__main__":
    main()
