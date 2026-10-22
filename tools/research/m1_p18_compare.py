#!/usr/bin/env python3
"""Strict P18 exact-work control/grace CSV checker; NO CI speed threshold."""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

KEY = ("phase","round","order","seed","workers","count","waves",
       "iterations","ingress","checksum")
STAGES = ("prepare_ns","pool_start_ns","waves_ns","join_ns","verify_ns")

def rows(path):
    with path.open(newline="") as f:
        records = list(csv.DictReader(f))
    if not records or not set(KEY+STAGES+("total_ns","retries","park_count")).issubset(records[0]):
        raise ValueError(f"bad P18 source data {path}")
    return records

def compare(control, candidate, minimum):
    a,b = rows(control),rows(candidate)
    if len(a)!=len(b) or len(a)<minimum:
        raise ValueError("P18 original/grace row count mismatch")
    ratios=defaultdict(list)
    parks=defaultdict(lambda: {"control":[],"grace":[]})
    for i,(left,right) in enumerate(zip(a,b)):
        for field in KEY:
            if left[field]!=right[field]:
                raise ValueError(f"P18 row {i}: different {field}")
        for record in (left,right):
            phases=[int(record[s]) for s in STAGES]
            if (min(phases)<0 or sum(phases)!=int(record["total_ns"]) or
                int(record["waves_ns"])<=0 or
                int(record["retries"])<0 or int(record["park_count"])<0):
                raise ValueError(f"P18 row {i}: impossible timing or scheduler count")
        if left["phase"]=="measure":
            key=(int(left["workers"]),int(left["iterations"]),int(left["ingress"]))
            ratios[key].append(int(right["waves_ns"])/int(left["waves_ns"]))
            parks[key]["control"].append(int(left["park_count"]))
            parks[key]["grace"].append(int(right["park_count"]))
    if not ratios:
        raise ValueError("P18 no measured rows")
    for key,values in sorted(ratios.items()):
        print(f"P18 CI DIAGNOSTIC workers={key[0]} iterations={key[1]} "
              f"ingress={key[2]} grace/original={median(values):.3f} "
              f"original/grace_parks={median(parks[key]['control']):.1f}/"
              f"{median(parks[key]['grace']):.1f} n={len(values)}")
    print(f"P18 PASS same oracle/seed/shuffle/work count rows={len(a)} "
          f"profiles={len(ratios)}")

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("control",type=Path)
    p.add_argument("grace",type=Path)
    p.add_argument("--min-rows",type=int,default=12)
    o=p.parse_args()
    compare(o.control,o.grace,o.min_rows)
