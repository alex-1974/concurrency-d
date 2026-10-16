#!/usr/bin/env python3
"""Validate complete P35 original lifetime oracles, TLS probe conservation."""
import argparse
import csv
from pathlib import Path

COLUMNS=("phase","round","work","producers","mode","count","workers",
         "ingress","retained","accepted","completed","executed","checksum",
         "attempts","producer_alloc_bytes","create_start_ns","submit_ns",
         "join_release_ns","total_ns","owner_calls","owner_wait_ns","owner_hold_ns")
def load(p):
    with p.open(newline="") as stream:
        reader=csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != COLUMNS:
            raise ValueError("P35 schema drift")
        records={}
        for row in reader:
            for col in COLUMNS:
                if col not in ("phase","work","mode"): row[col]=int(row[col])
            key=(row["phase"],row["round"],row["work"],row["producers"],row["mode"])
            if key in records: raise ValueError("P35 duplicate profile")
            count=row["count"]
            if row["accepted"]!=count or row["completed"]!=count or row["attempts"]<count:
                raise ValueError("P35 completion failure")
            expected=0 if row["work"]=="minimal" else count
            if row["executed"]!=expected or row["checksum"]!=60*expected:
                raise ValueError("P35 execution oracle mismatch")
            if row["owner_calls"]!=(0 if row["mode"]=="m0" else row["attempts"]):
                raise ValueError("P35 owner TLS call mismatch")
            records[key]=row
        return records
def main():
    p=argparse.ArgumentParser();p.add_argument("null",type=Path)
    p.add_argument("timed",type=Path);p.add_argument("--min-rounds",type=int,default=3)
    a=p.parse_args();n,t=load(a.null),load(a.timed)
    if n.keys()!=t.keys():raise ValueError("P35 paired profiles missing")
    rounds={key[1] for key in n if key[0]=="measure"}
    if len(rounds)<a.min_rounds:raise ValueError("P35 insufficient rounds")
    for rid in rounds:
        for work in ("minimal","shared_atomic","sharded_atomic"):
            for prod in (1,2,4):
                for mode in ("m0","deferred","managed"):
                    if ("measure",rid,work,prod,mode) not in n:
                        raise ValueError("P35 missing profile")
    for key in n:
        x,y=n[key],t[key]
        for col in ("count","workers","ingress","retained","accepted",
                    "completed","executed","checksum"):
            if x[col]!=y[col]:raise ValueError("P35 paired work mismatch")
        if x["owner_wait_ns"] or x["owner_hold_ns"]:
            raise ValueError("P35 null timestamps nonzero")
        if y["mode"]!="m0" and y["owner_hold_ns"]<=0:
            raise ValueError("P35 timed timestamps missing")
    print("P35_TLS_OWNER_MATCH_PASS rounds="+str(len(rounds))+" diagnostic_only=true")
if __name__=="__main__":main()
