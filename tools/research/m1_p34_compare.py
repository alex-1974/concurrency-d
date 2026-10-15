#!/usr/bin/env python3
"""P34 null/timed same-work correctness. The timed probe is invasive."""
import argparse
import csv
import io
from pathlib import Path

BASE = ("phase","round","work","producers","mode","count","workers","ingress",
        "retained","accepted","completed","executed","checksum","attempts",
        "producer_alloc_bytes","create_start_ns","submit_ns","join_release_ns",
        "total_ns")
FIELDS = BASE + ("probe_calls","probe_ns")

def parse(handle):
        reader=csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("P34 CSV schema mismatch")
        result={}
        for row in reader:
            key=(row["phase"],int(row["round"]),row["work"],
                 int(row["producers"]),row["mode"])
            if key in result:
                raise ValueError("P34 duplicate arm")
            for field in FIELDS:
                if field not in ("phase","work","mode"):
                    row[field]=int(row[field])
                    if row[field]<0:
                        raise ValueError("P34 negative metric")
            if row["count"] != row["accepted"] or row["count"] != row["completed"]:
                raise ValueError("P34 incomplete tasks")
            if row["probe_calls"] != row["attempts"]:
                raise ValueError("P34 missed probe calls")
            expected=0 if row["work"]=="minimal" else row["count"]
            if row["executed"]!=expected or row["checksum"]!=60*expected:
                raise ValueError("P34 task oracle mismatch")
            result[key]=row
        return result

def read(path):
    with path.open(newline="") as handle:
        return parse(handle)

def self_test():
    header=",".join(FIELDS)
    data={k:"0" for k in FIELDS}
    data.update(phase="measure",round="3",work="minimal",producers="2",
                mode="managed",count="8",accepted="8",completed="8",
                attempts="8",probe_calls="8",probe_ns="0")
    row=",".join(data[k] for k in FIELDS)
    parsed=parse(io.StringIO(chr(10).join((header, row, ""))))
    if ("measure",3,"minimal",2,"managed") not in parsed:
        raise ValueError("P34 numeric profile key normalization failed")
    print("P34_PROFILE_KEY_SELFTEST_PASS")

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--self-test",action="store_true")
    parser.add_argument("control",type=Path,nargs="?")
    parser.add_argument("timed",type=Path,nargs="?")
    parser.add_argument("--min-rounds",type=int,default=3)
    a=parser.parse_args()
    if a.self_test:
        self_test()
        if a.control is None and a.timed is None:
            return
    if a.control is None or a.timed is None:
        parser.error("control and timed CSV paths are required")
    left,right=read(a.control),read(a.timed)
    if left.keys()!=right.keys():
        raise ValueError("P34 missing paired row")
    rounds={k[1] for k in left if k[0]=="measure"}
    if len(rounds)<a.min_rounds:
        raise ValueError("P34 insufficient measurement rounds")
    for round_id in rounds:
        for kind in ("minimal","shared_atomic","sharded_atomic"):
            for prod in (1,2,4):
                for owner in ("m0","deferred","managed"):
                    key=("measure",round_id,kind,prod,owner)
                    if key not in left:
                        raise ValueError("P34 incomplete profile grid")
    for key in left:
        x,y=left[key],right[key]
        for field in ("count","workers","ingress","retained","accepted",
                      "completed","executed","checksum"):
            if x[field]!=y[field]:
                raise ValueError("P34 mismatched work")
        if x["probe_ns"]!=0:
            raise ValueError("P34 null probe recorded time")
        if y["probe_ns"]<=0:
            raise ValueError("P34 timed probe missing time")
    print("P34_MATCHED_NULL_TIMED_PASS rounds="+str(len(rounds))+
          " diagnostic_only=true")

if __name__=="__main__":
    main()
