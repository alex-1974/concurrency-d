#!/usr/bin/env python3
"""P18 Linux scheduler-trace TASK/ORACLE validation (not timing evidence)."""
import argparse
import csv
from pathlib import Path
from tempfile import TemporaryDirectory

KEY = ("phase","round","order","seed","workers","count","waves",
       "iterations","ingress","checksum")
STAGES = ("prepare_ns","pool_start_ns","waves_ns","join_ns","verify_ns")
REQUIRED = set(KEY+STAGES+("total_ns","retries","park_count"))
CAP = {"sched8":8,"sched2048":2048}

def read(path, profile, rounds, count, waves):
    if profile not in CAP or not 1 <= rounds <= 24:
        raise ValueError("P18 scheduler profile/rounds invalid")
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames is None or not REQUIRED.issubset(reader.fieldnames):
            raise ValueError("P18 scheduler fields missing")
        records = list(reader)
    if len(records) != rounds+2:
        raise ValueError("P18 scheduler trace truncated process")
    seeds = set()
    for i,row in enumerate(records):
        if row["phase"] != ("warmup" if i<2 else "measure") or (
                int(row["round"]) != i or int(row["order"]) != 0):
            raise ValueError("P18 wrong round/phase/order")
        seeds.add(int(row["seed"]))
        if (int(row["workers"]) != 1 or int(row["iterations"]) != 512 or
            int(row["ingress"]) != CAP[profile] or
            int(row["count"]) != count or int(row["waves"]) != waves):
            raise ValueError("P18 scheduler TaskRef workload changed")
        stages=[int(row[k]) for k in STAGES]
        retries=int(row["retries"])
        if (min(stages)<0 or stages[2]<=0 or
            sum(stages)!=int(row["total_ns"]) or
            retries<0 or int(row["park_count"])<0 or
            (CAP[profile]>=count and retries)):
            raise ValueError("P18 scheduler invalid stage or full-inbox retries")
        if not row["checksum"]:
            raise ValueError("P18 scheduler empty checksum")
    if len(seeds)!=1 or min(seeds)<=0:
        raise ValueError("P18 scheduler seed drift")
    return records

def compare(original, candidate=None, profile="sched8", rounds=24,
            count=2048, waves=3):
    if count<1 or waves<1: raise ValueError("invalid size")
    a=read(original,profile,rounds,count,waves)
    if candidate is not None:
        b=read(candidate,profile,rounds,count,waves)
        for i,(x,y) in enumerate(zip(a,b)):
            if any(x[k]!=y[k] for k in KEY):
                raise ValueError(f"P18 scheduler control/grace mismatch row={i}")
    print(f"P18 SCHED WORK PASS profile={profile} rows={len(a)} "
          f"measured={rounds} count={count} waves={waves} "
          f"paired={candidate is not None}; PERF TIMES NOT SPEED EVIDENCE")

def self_test():
    cols=list(KEY)+list(STAGES)+["total_ns","retries","park_count"]
    with TemporaryDirectory() as tmp:
        a,b=Path(tmp)/"a.csv",Path(tmp)/"b.csv"
        records=[]
        for i in range(4):
            row={x:"0" for x in cols}
            row.update(phase="warmup" if i<2 else "measure",round=str(i),
                       order="0",seed="42",workers="1",count="16",waves="2",
                       iterations="512",ingress="2048",checksum="123",
                       prepare_ns="2",pool_start_ns="3",waves_ns="10",
                       join_ns="2",verify_ns="1",total_ns="18",
                       retries="0",park_count="1")
            records.append(row)
        def write(path):
            with path.open("w",newline="") as stream:
                wr=csv.DictWriter(stream,fieldnames=cols)
                wr.writeheader()
                wr.writerows(records)
        write(a);write(b)
        compare(a,b,"sched2048",2,16,2)
        records[2]["retries"]="1";write(b)
        try: compare(a,b,"sched2048",2,16,2)
        except ValueError: pass
        else: raise AssertionError("accepted fabricated full retry")
        records[2]["retries"]="0";records[2]["checksum"]="changed";write(b)
        try: compare(a,b,"sched2048",2,16,2)
        except ValueError: pass
        else: raise AssertionError("accepted different TaskRef result")
    print("P18 SCHED synthetic negative tests PASS")

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("control",type=Path,nargs="?")
    p.add_argument("grace",type=Path,nargs="?")
    p.add_argument("--profile",choices=tuple(CAP),default="sched8")
    p.add_argument("--rounds",type=int,default=24)
    p.add_argument("--count",type=int,default=2048)
    p.add_argument("--waves",type=int,default=3)
    p.add_argument("--self-test",action="store_true")
    opt=p.parse_args()
    if opt.self_test: self_test()
    else:
        if opt.control is None: p.error("control CSV required")
        compare(opt.control,opt.grace,opt.profile,opt.rounds,opt.count,opt.waves)
