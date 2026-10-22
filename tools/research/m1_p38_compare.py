#!/usr/bin/env python3
"""Validate P38 worker counters while reusing strict P37 paired invariants."""
import argparse
import csv
import subprocess
import sys
import tempfile
from pathlib import Path

EXT=("park_calls","wait_entries","wait_returns")

def project(source,out):
    with source.open(newline="") as inp, out.open("w",newline="") as dst:
        reader=csv.DictReader(inp)
        if tuple(reader.fieldnames or ())[-3:]!=EXT:
            raise ValueError("P38 worker CSV columns absent")
        keep=reader.fieldnames[:-3]
        writer=csv.DictWriter(dst,fieldnames=keep)
        writer.writeheader()
        observed=0
        for row in reader:
            park,entries,returns=(int(row[n]) for n in EXT)
            if min(park,entries,returns)<0 or entries!=returns or entries>park:
                raise ValueError("P38 worker wait conservation")
            if row["mode"]=="m0" and (park or entries or returns):
                raise ValueError("P38 baseline reported instrumented workers")
            writer.writerow({key:row[key] for key in keep})
            observed+=1
    return observed

def main():
    p=argparse.ArgumentParser()
    p.add_argument("null",type=Path)
    p.add_argument("timed",type=Path)
    p.add_argument("--min-rounds",type=int,default=3)
    args=p.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        null=Path(directory)/"null.csv"
        timed=Path(directory)/"timed.csv"
        n=project(args.null,null)
        if project(args.timed,timed)!=n: raise ValueError("P38 row count mismatch")
        script=Path(__file__).with_name("m1_p37_compare.py")
        subprocess.run([sys.executable,str(script),str(null),str(timed),
                        "--min-rounds",str(args.min_rounds)],check=True)
    print("P38_WORKER_COUNTER_MATCH_PASS",n)

if __name__=="__main__":
    main()
