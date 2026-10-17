#!/usr/bin/env python3
"""Validate P34 original P31 / null / timed profiles; timing diagnostic only."""
import argparse
import csv
from pathlib import Path
from statistics import median

KEYS=("phase","round","work","producers","mode")
WORK=("minimal","shared_atomic","sharded_atomic")
OWNERS=("m0","deferred","managed")
BASE=("count","workers","ingress","retained","accepted","completed",
      "executed","checksum")
METRICS=("submit_ns","producer_alloc_bytes")

def load(path):
    with path.open(newline="") as handle:
        records=list(csv.DictReader(handle))
    if not records or any(not set(KEYS+BASE+METRICS).issubset(row) for row in records):
        raise ValueError("P34 missing original or diagnostic CSV fields")
    out={}
    for row in records:
        key=(row["phase"],int(row["round"]),row["work"],
             int(row["producers"]),row["mode"])
        if key in out: raise ValueError("P34 duplicate arm")
        out[key]=row
    return out

def main():
    p=argparse.ArgumentParser()
    p.add_argument("original",type=Path)
    p.add_argument("null",type=Path)
    p.add_argument("timed",type=Path)
    p.add_argument("--min-rounds",type=int,default=9)
    args=p.parse_args()
    original,null,timed=(load(x) for x in (args.original,args.null,args.timed))
    if original.keys()!=null.keys() or null.keys()!=timed.keys():
        raise ValueError("P34 unequal profile keys")
    rounds={k[1] for k in original if k[0]=="measure"}
    if len(rounds)<args.min_rounds: raise ValueError("P34 insufficient rounds")
    for round_id in rounds:
        for work in WORK:
            for producers in (1,2,4):
                for owner in OWNERS:
                    if ("measure",round_id,work,producers,owner) not in original:
                        raise ValueError("P34 missing measured profile")
    summaries={}
    for key in original:
        triple=(original[key],null[key],timed[key])
        for field in BASE:
            if len({int(row[field]) for row in triple})!=1:
                raise ValueError("P34 task semantics differ: "+field)
        if any(int(row["submit_ns"])<=0 for row in triple):
            raise ValueError("P34 nonpositive interval")
        if key[0]=="measure":
            name=(key[2],key[3],key[4])
            summaries.setdefault(name,[]).append((
                int(triple[1]["submit_ns"])/int(triple[0]["submit_ns"]),
                int(triple[2]["submit_ns"])/int(triple[1]["submit_ns"])))
    for key,values in sorted(summaries.items()):
        print("P34_THREE_ARM_DIAGNOSTIC",
              "work="+key[0],"producers="+str(key[1]),"owner="+key[2],
              "null/original="+f"{median(v[0] for v in values):.4f}",
              "timed/null="+f"{median(v[1] for v in values):.4f}")
    print("P34_THREE_ARM_VALIDATED rounds="+str(len(rounds))+" diagnostic_only=true")

if __name__=="__main__":main()
