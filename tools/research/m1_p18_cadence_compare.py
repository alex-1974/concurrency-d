#!/usr/bin/env python3
"""Strict exact-work P18 producer-success-cadence factorial validator.

A cadence change is a DIFFERENT producer workload. Only M0/P18 comparisons
WITHIN the same cadence/mask qualify as paired scheduler speed observations.
No fixed CI speed acceptance thresholds.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median
from tempfile import TemporaryDirectory

PATTERNS = {"cadence0":0, "cadence8":8, "cadence64":64}
CPUS = (1,4)
ITERATIONS = (128,512,1024)
INGRESS = (8,2048)
CELLS = {(1,it,cap) for it in ITERATIONS for cap in INGRESS}
FIELDS = ("phase","round","order","seed","workers","count","waves",
          "iterations","ingress","checksum")
STAGES = ("prepare_ns","pool_start_ns","waves_ns","join_ns","verify_ns")
REQUIRED = set(FIELDS+STAGES+("total_ns","retries","park_count","cadence_yields"))

def load(path, expected_stride, warmup, rounds, count, waves):
    with path.open(newline="") as stream:
        reader=csv.DictReader(stream)
        if not reader.fieldnames or not REQUIRED.issubset(reader.fieldnames):
            raise ValueError(f"P18 cadence required columns absent {path}")
        records=list(reader)
    if len(records)!=len(CELLS)*(warmup+rounds):
        raise ValueError(f"P18 cadence incomplete case matrix {path}")
    seeds=set()
    for r in range(warmup+rounds):
        items=records[r*len(CELLS):(r+1)*len(CELLS)]
        seen=set()
        for j,item in enumerate(items):
            try:
                it,cap,worker=(int(item["iterations"]),int(item["ingress"]),
                               int(item["workers"]))
                n=int(item["count"]); w=int(item["waves"])
                retry=int(item["retries"]); parks=int(item["park_count"])
                stages=[int(item[k]) for k in STAGES]
                reported=int(item["cadence_yields"])
                expected=w*((n-1)//expected_stride) if expected_stride else 0
                seed=int(item["seed"])
            except (ValueError,KeyError) as err:
                raise ValueError(f"P18 cadence malformed number in {path}") from err
            case=(worker,it,cap)
            if (case not in CELLS or case in seen or
                item["phase"]!=("warmup" if r<warmup else "measure") or
                int(item["round"])!=r or int(item["order"])!=j or
                n!=count or w!=waves or seed<1 or
                not item["checksum"] or retry<0 or parks<0 or
                min(stages)<0 or stages[2]<=0 or
                sum(stages)!=int(item["total_ns"]) or
                reported!=expected or (cap>=n and retry!=0)):
                raise ValueError(f"P18 cadence invariant failed {path}: round {r} position {j}")
            seen.add(case);seeds.add(seed)
        if seen != CELLS:
            raise ValueError("P18 cadence missing or duplicate cases")
    if len(seeds)!=1:
        raise ValueError("P18 cadence seed changed")
    return records

def audit(folder, sessions=6, warmup=2, rounds=5, count=2048, waves=3):
    if sessions!=6 or warmup<0 or rounds<1 or count<1 or waves<1:
        raise ValueError("P18 cadence fixed matrix contract invalid")
    required={
        f"session{s}-cpu{cpu}-{pattern}-{arm}{half}.csv"
        for s in range(1,sessions+1)
        for cpu in CPUS for pattern in PATTERNS
        for arm in ("control","grace") for half in (1,2)
    }
    actual={f.name for f in folder.glob("*.csv")}
    if actual!=required:
        raise ValueError(f"P18 cadence files missing={sorted(required-actual)} extra={sorted(actual-required)}")
    bycell=defaultdict(list)
    task_checksum={}
    matched=0
    warmups=0
    for session in range(1,sessions+1):
        session_base=None
        for cpu in CPUS:
            for pattern, stride in PATTERNS.items():
                for half in (1,2):
                    paths=[
                        folder/f"session{session}-cpu{cpu}-{pattern}-{arm}{half}.csv"
                        for arm in ("control","grace")
                    ]
                    a,b=[load(p,stride,warmup,rounds,count,waves) for p in paths]
                    if len(a)!=len(b):
                        raise ValueError("P18 cadence paired row mismatch")
                    for i,(m0,p18) in enumerate(zip(a,b)):
                        if any(m0[x]!=p18[x] for x in FIELDS):
                            raise ValueError(f"P18 cadence arm work mismatch: {paths[0]} row{i}")
                        # The experiment uses the same seeded case ordering across
                        # ALL process masks, patterns, halves, and compiler versions.
                        signature=tuple(m0[f] for f in FIELDS)
                        key=(session,i)
                        if session_base is None:
                            session_base={}
                        if key in session_base and session_base[key]!=signature:
                            raise ValueError("P18 cadence cross-pattern/CPU seed/order/TaskRef drift")
                        session_base[key]=signature
                        it=int(m0["iterations"]); cap=int(m0["ingress"])
                        cs=m0["checksum"]
                        if it in task_checksum and cs!=task_checksum[it]:
                            raise ValueError("P18 cadence checksum drift across cases")
                        task_checksum[it]=cs
                        if m0["phase"]=="measure":
                            bycell[(cpu,pattern,it,cap)].append(
                                (session,half,int(p18["waves_ns"])/int(m0["waves_ns"]),
                                 int(m0["park_count"]),int(p18["park_count"]),
                                 int(m0["retries"]),int(p18["retries"])))
                            matched+=1
                        else:
                            warmups+=1
    expected_pairs=sessions*len(CPUS)*len(PATTERNS)*2*len(CELLS)*rounds
    expected_warmups=sessions*len(CPUS)*len(PATTERNS)*2*len(CELLS)*warmup
    if matched!=expected_pairs or warmups!=expected_warmups or len(bycell)!=len(CPUS)*len(PATTERNS)*len(CELLS):
        raise ValueError("P18 cadence matrix incomplete after pairing")
    print(f"P18 CADENCE PASS processes={len(required)} matched_measured={matched} "
          f"matched_warmups={warmups} checksums={task_checksum}; "
          "no CI speed thresholds")
    for cpu in CPUS:
        for pattern in PATTERNS:
            for iteration in ITERATIONS:
                for ingress in INGRESS:
                    pairs=bycell[(cpu,pattern,iteration,ingress)]
                    values=[r[2] for r in pairs]
                    session_medians=[
                        median(x[2] for x in pairs if x[0]==session)
                        for session in range(1,sessions+1)]
                    print(f"P18 CADENCE source-pinned cpu={cpu} cadence={pattern} "
                          f"iterations={iteration} ingress={ingress} "
                          f"median_paired_P18_div_M0={median(values):.6f} "
                          f"median_park_M0_P18={median(x[3] for x in pairs):.1f}/"
                          f"{median(x[4] for x in pairs):.1f} "
                          f"median_full_M0_P18={median(x[5] for x in pairs):.1f}/"
                          f"{median(x[6] for x in pairs):.1f} "
                          f"n={len(values)} sessions="
                          + ",".join(f"{x:.4f}" for x in session_medians))
    print("CAUTION: cadence0/8/64 are INTENTIONALLY DIFFERENT PRODUCER WORKLOADS; "
          "compare P18/M0 only within the same cadence and affinity. "
          "Even a cadence0 recompiled module is not the historic binary.")

def self_test():
    with TemporaryDirectory() as tmp:
        p=Path(tmp)
        columns=list(FIELDS+STAGES+("total_ns","retries","park_count","cadence_yields"))
        for session in range(1,7):
            for cpu in CPUS:
                for pattern,stride in PATTERNS.items():
                    for arm in ("control","grace"):
                        for half in (1,2):
                            file=p/f"session{session}-cpu{cpu}-{pattern}-{arm}{half}.csv"
                            with file.open("w",newline="") as stream:
                                writer=csv.DictWriter(stream,fieldnames=columns)
                                writer.writeheader()
                                for trial in (0,1):
                                    for j,(it,cap) in enumerate((a,b) for a in ITERATIONS for b in INGRESS):
                                        row={k:"0" for k in columns}
                                        row.update(phase="warmup" if trial==0 else "measure",
                                            round=str(trial),order=str(j),seed=str(100+session),
                                            workers="1",count="128",waves="2",iterations=str(it),
                                            ingress=str(cap),checksum=str(it+567),
                                            prepare_ns="1",pool_start_ns="1",waves_ns="10",
                                            join_ns="1",verify_ns="1",total_ns="14",
                                            cadence_yields=str(2*((128-1)//stride) if stride else 0))
                                        writer.writerow(row)
        audit(p,warmup=1,rounds=1,count=128,waves=2)
        broken=p/"session1-cpu1-cadence64-grace2.csv"
        text=broken.read_text()
        head,*rows=text.splitlines()
        cols=head.split(",");cells=rows[0].split(",")
        cells[cols.index("cadence_yields")]="999"
        rows[0]=",".join(cells)
        broken.write_text("\n".join([head]+rows)+"\n")
        try: audit(p,warmup=1,rounds=1,count=128,waves=2)
        except ValueError: pass
        else: raise AssertionError("P18 cadence accepted fabricated yield count")
    print("P18 CADENCE synthetic negative test PASS")

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("directory",type=Path,nargs="?")
    p.add_argument("--sessions",type=int,default=6)
    p.add_argument("--warmup",type=int,default=2)
    p.add_argument("--rounds",type=int,default=5)
    p.add_argument("--count",type=int,default=2048)
    p.add_argument("--waves",type=int,default=3)
    p.add_argument("--self-test",action="store_true")
    a=p.parse_args()
    if a.self_test:self_test()
    else:
        if a.directory is None:p.error("directory required")
        audit(a.directory,a.sessions,a.warmup,a.rounds,a.count,a.waves)
