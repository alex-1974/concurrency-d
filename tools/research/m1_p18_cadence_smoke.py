#!/usr/bin/env python3
"""Small DMD/LDC smoke of exact six-case cadence workloads."""
import argparse
from pathlib import Path

from m1_p18_cadence_compare import FIELDS, PATTERNS, CELLS, load


def check(directory, build, count, waves):
    for cadence, stride in PATTERNS.items():
        arms=[]
        for arm in ("control","grace"):
            p=directory/f"{build}{cadence}-{arm}.csv"
            rows=load(p,stride,1,1,count,waves)
            arms.append(rows)
            assert len(rows)==len(CELLS)*2
        if any(x[k]!=y[k] for x,y in zip(*arms) for k in FIELDS):
            raise ValueError(f"source-pinned cadence {cadence} M0/P18 work differs")
    print(f"P18 CADENCE {build} DMD/LDC exact-source 0/8/64 PASS")


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("csv_dir",type=Path)
    p.add_argument("--prefix",default="")
    p.add_argument("--count",type=int,default=128)
    p.add_argument("--waves",type=int,default=2)
    args=p.parse_args()
    check(args.csv_dir,args.prefix,args.count,args.waves)
