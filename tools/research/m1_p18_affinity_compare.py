#!/usr/bin/env python3
"""Fail-closed P18 native CPU-affinity factorial experiment CSV audit.

Exactly identical M0/P18 source kernels, tasks, rounds and checksums under
process-affinity masks 1/2/4 distinct physical cores.  Balanced ABBA/BAAB
observations; native wall times may compare variants *within each mask*, but
differences between masks conflate CPU concurrency, turbo, interrupts, etc.
No automatic performance gate or causal scheduler verdict.
"""
import argparse
import csv
import math
from pathlib import Path
from collections import defaultdict
from statistics import median
from tempfile import TemporaryDirectory

CAPACITY = (8, 64, 256, 2048)
ITERATIONS = (128, 512, 1024)
CORES = (1, 2, 4)
SCENARIOS = {(1, it, cap) for it in ITERATIONS for cap in CAPACITY}
FIELDS = ("phase", "round", "order", "seed", "workers", "count",
          "waves", "iterations", "ingress", "checksum")
TIMINGS = ("prepare_ns", "pool_start_ns", "waves_ns",
           "join_ns", "verify_ns")

def load(path, warmups, rounds, count, waves):
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        required = set(FIELDS + TIMINGS + ("total_ns","retries","park_count"))
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            raise ValueError(f"P18 affinity missing fields: {path}")
        rows = list(reader)
    if len(rows) != len(SCENARIOS) * (warmups+rounds):
        raise ValueError(f"P18 affinity missing/unexpected rows: {path}")
    seen_seeds=set()
    for round_index in range(warmups+rounds):
        current = rows[round_index*len(SCENARIOS):(round_index+1)*len(SCENARIOS)]
        visited=set()
        for order, row in enumerate(current):
            try:
                it,cap,worker=(int(row["iterations"]),
                               int(row["ingress"]),int(row["workers"]))
                seed=int(row["seed"])
                retries=int(row["retries"])
                stages=[int(row[k]) for k in TIMINGS]
                total=int(row["total_ns"])
                parks=int(row["park_count"])
            except (ValueError,KeyError) as exc:
                raise ValueError(f"P18 affinity invalid numerical row: {path}") from exc
            if (row["phase"] != ("warmup" if round_index < warmups else "measure")
                or int(row["round"]) != round_index or int(row["order"])!=order
                or int(row["count"])!=count or int(row["waves"])!=waves
                or (worker,it,cap) not in SCENARIOS
                or (worker,it,cap) in visited
                or min(stages)<0 or stages[2]<=0
                or sum(stages)!=total or retries<0 or parks<0
                or (cap>=count and retries)
                or not row["checksum"]):
                raise ValueError(f"P18 affinity invalid case/invariant: {path}, round {round_index}")
            seen_seeds.add(seed)
            visited.add((worker,it,cap))
        if visited != SCENARIOS:
            raise ValueError(f"P18 affinity missing cases: {path}")
    if len(seen_seeds)!=1 or min(seen_seeds)<=0:
        raise ValueError(f"P18 affinity seed inconsistent: {path}")
    return rows

def audit(folder, sessions=6, warmups=2, rounds=5, count=2048, waves=3):
    if not 1<=sessions<=6 or warmups<0 or rounds<1 or count<1 or waves<1:
        raise ValueError("P18 affinity invalid scenario parameters")
    expected = {
        f"session{s}-cpu{cpu}-{arm}{half}.csv"
        for s in range(1,sessions+1)
        for cpu in CORES for arm in ("control","grace") for half in (1,2)
    }
    observed={p.name for p in folder.glob("*.csv")}
    if observed!=expected:
        raise ValueError(f"P18 affinity files mismatch: missing={sorted(expected-observed)}, extra={sorted(observed-expected)}")
    checksums={}
    medians=defaultdict(list)
    control_contrasts=defaultdict(list)
    total_pairs=0
    for session in range(1,sessions+1):
        for cpu in CORES:
            for half in (1,2):
                left=load(folder/f"session{session}-cpu{cpu}-control{half}.csv",warmups,rounds,count,waves)
                right=load(folder/f"session{session}-cpu{cpu}-grace{half}.csv",warmups,rounds,count,waves)
                by_iteration={}
                for index,(m0,p18) in enumerate(zip(left,right)):
                    if any(m0[key]!=p18[key] for key in FIELDS):
                        raise ValueError(f"P18 affinity unmatched TaskRefs in s{session}/cpu{cpu}/half{half}/row{index}")
                    # All tasks/kernels are identical across masks and rounds;
                    # checksum must only depend on iteration count here.
                    it=int(m0["iterations"])
                    for row in (m0,p18):
                        checksum=row["checksum"]
                        if it in checksums and checksums[it]!=checksum:
                            raise ValueError("P18 affinity cross-CPU/task iteration checksum drift")
                        checksums[it]=checksum
                    if m0["phase"]=="measure":
                        cap=int(m0["ingress"])
                        rnd=int(m0["round"])
                        ratio=int(p18["waves_ns"])/int(m0["waves_ns"])
                        medians[(cpu,it,cap)].append((session,half,rnd,ratio))
                        by_iteration[(rnd,cap,it)]=ratio
                        total_pairs+=1
                for rnd in range(warmups,warmups+rounds):
                    for cap in CAPACITY:
                        key=lambda it: by_iteration[(rnd,cap,it)]
                        control_contrasts[(cpu,cap)].append(
                            key(512)/math.sqrt(key(128)*key(1024)))
    expected_pairs=sessions*len(CORES)*2*len(SCENARIOS)*rounds
    if total_pairs!=expected_pairs or len(medians)!=len(CORES)*len(SCENARIOS):
        raise ValueError("P18 affinity measured pair cardinality mismatch")
    print(f"P18 AFFINITY ORACLE PASS sessions={sessions} processes={len(expected)} "
          f"same-work-pairs={total_pairs} warmup-pairs={sessions*len(CORES)*2*len(SCENARIOS)*warmups} "
          f"checksums={checksums}; no speed thresholds")
    for cpu in CORES:
        print(f"=== CPU affinity count {cpu}: source-pinned uninstrumented P18/M0 ===")
        for it in ITERATIONS:
            for cap in CAPACITY:
                values=medians[(cpu,it,cap)]
                ratio=median(t[3] for t in values)
                session_medians=[median(x[3] for x in values if x[0]==s)
                                 for s in range(1,sessions+1)]
                print(f"P18 AFFINITY cpu={cpu} iterations={it} ingress={cap} "
                      f"ratio={ratio:.6f} n={len(values)} "
                      f"session_medians=" + ",".join(f"{v:.5f}" for v in session_medians))
        for cap in CAPACITY:
            print(f"P18 AFFINITY CONTROL-DIAGNOSTIC cpu={cpu} ingress={cap} "
                  f"R512/sqrt(R128*R1024)="
                  f"{median(control_contrasts[(cpu,cap)]):.6f} "
                  "not a replacement for actual absolute ratios")
    print("P18 AFFINITY: CPU-mask contrast changes concurrent-core availability, "
          "clocking/migrations and producer-worker placement together.")

def self_test():
    cols=FIELDS+TIMINGS+("total_ns","retries","park_count")
    with TemporaryDirectory() as temp:
        folder=Path(temp)
        for cpu in CORES:
            for arm in ("control","grace"):
                for half in (1,2):
                    with (folder/f"session1-cpu{cpu}-{arm}{half}.csv").open("w",newline="") as f:
                        writer=csv.DictWriter(f,fieldnames=cols);writer.writeheader()
                        for trial in (0,1):
                            order=0
                            for it in ITERATIONS:
                                for cap in CAPACITY:
                                    row={k:"0" for k in cols}
                                    row.update(phase="warmup" if trial==0 else "measure",
                                        round=str(trial),order=str(order),seed="42",
                                        workers="1",count="16",waves="2",
                                        iterations=str(it),ingress=str(cap),
                                        checksum=str(999+it),
                                        prepare_ns="2",pool_start_ns="2",waves_ns="100",
                                        join_ns="2",verify_ns="2",total_ns="108",
                                        retries="0",park_count="1")
                                    writer.writerow(row)
                                    order+=1
        audit(folder,sessions=1,warmups=1,rounds=1,count=16,waves=2)
        invalid=folder/"session1-cpu2-grace2.csv"
        content=invalid.read_text()
        lines=content.splitlines()
        ix=lines[0].split(",").index("checksum")
        cells=lines[1].split(","); cells[ix]="WRONG"; lines[1]=",".join(cells)
        invalid.write_text("\n".join(lines)+"\n")
        try: audit(folder,sessions=1,warmups=1,rounds=1,count=16,waves=2)
        except ValueError: pass
        else: raise AssertionError("P18 affinity accepted checksum drift")
    print("P18 AFFINITY synthetic checksum-negative PASS")

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("csv_dir",type=Path,nargs="?")
    p.add_argument("--sessions",type=int,default=6)
    p.add_argument("--warmups",type=int,default=2)
    p.add_argument("--rounds",type=int,default=5)
    p.add_argument("--count",type=int,default=2048)
    p.add_argument("--waves",type=int,default=3)
    p.add_argument("--self-test",action="store_true")
    a=p.parse_args()
    if a.self_test: self_test()
    else:
        if a.csv_dir is None: p.error("CSV directory required")
        audit(a.csv_dir,a.sessions,a.warmups,a.rounds,a.count,a.waves)
