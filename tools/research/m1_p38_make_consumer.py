#!/usr/bin/env python3
"""P38 runnable P31 fixture reuses pinned P37 consumer telemetry."""
from pathlib import Path
import subprocess
import sys

def main():
    root,original,out=map(Path,sys.argv[1:4])
    temp=out.with_suffix(".p37.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p37_make_consumer.py"),
            str(root),str(original),str(temp)],check=True)
        s=temp.read_text()
    finally:
        temp.unlink(missing_ok=True)
    changes=(
        ("module concurrency.research.p37_generational_owner;",
         "module concurrency.research.p38_generational_owner;"),
        ("import concurrency.research.m1_p37_owned :",
         "import concurrency.research.m1_p38_owned :"),
        ("import concurrency.research.m1_p37_pool :",
         "import concurrency.research.m1_p38_pool :"),
        ("P37_INBOX_BENCHMARK_PASS","P38_WAKE_BENCHMARK_PASS"),
    )
    for old,new in changes:
        if old not in s: raise ValueError("P38 consumer drift: "+old)
        s=s.replace(old,new)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P38_CONSUMER_SOURCE_PIN_PASS")

if __name__=="__main__":
    main()
