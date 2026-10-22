#!/usr/bin/env python3
"""P18 exact-work PI event-only 1CPU vs 4CPU contrast, NEVER rank speed.

The existing M0/P18 PI validator proves TaskRef/ingress/grace conservation.
This wrapper requires exactly all process arms/masks, checks cross-mask
source/work/seed parity, and prints event counts without using any timings.
"""
import argparse
import csv
from pathlib import Path
from statistics import median
from collections import defaultdict
import tempfile

from m1_p18_pi_compare import audit as original_pi_audit
from m1_p18_512_trace_compare import WORK, EVENTS

CPUS = (1, 4)
ITERATIONS = (128, 512, 1024)
CAPACITIES = (8, 64, 256, 2048)
CELLS = {(1, it, cap) for it in ITERATIONS for cap in CAPACITIES}
NEEDED = ("submitCalls", "submitAccepted", "submitFull", "submitClosed",
          "takeCalls", "takeEmpty", "takenTasks", "peakUsed",
          "completeCalls", "wakeReads", "drainReads", "announceCalls",
          "pollYields", "park_count", "park_attempts", "park_waits",
          "park_no_outstanding", "park_with_outstanding", "batch_claims",
          "batch_tasks", "grace_searches", "grace_recovered_inbox",
          "grace_fallbacks", "grace_drain_exits", "retries")
FIELDS = ("phase", "round", "order", "seed", "workers", "count",
          "waves", "iterations", "ingress", "checksum")

def load(path, warmups, rounds, count, waves):
    with path.open(newline="") as source:
        reader = csv.DictReader(source)
        if not reader.fieldnames or not set(FIELDS+NEEDED).issubset(reader.fieldnames):
            raise ValueError(f"P18 PI affinity missing required fields: {path}")
        rows = list(reader)
    if len(rows) != (warmups+rounds)*len(CELLS):
        raise ValueError(f"P18 PI affinity wrong row count: {path}")
    for trial in range(warmups+rounds):
        subset = rows[trial*len(CELLS):(trial+1)*len(CELLS)]
        seen = set()
        seeds = set()
        for order, row in enumerate(subset):
            it = int(row["iterations"]); cap = int(row["ingress"])
            wk = int(row["workers"]); case = (wk, it, cap)
            if (row["phase"] != ("warmup" if trial<warmups else "measure") or
                int(row["round"]) != trial or int(row["order"]) != order or
                int(row["count"]) != count or int(row["waves"]) != waves or
                case not in CELLS or case in seen or
                not row["checksum"]):
                raise ValueError(f"P18 PI affinity case/order drift: {path}, round {trial}")
            values = {name: int(row[name]) for name in NEEDED}
            if (min(values.values()) < 0 or
                values["park_count"] != values["park_waits"] or
                values["park_waits"] !=
                   values["park_no_outstanding"]+values["park_with_outstanding"] or
                values["batch_tasks"] != count*waves or
                values["submitAccepted"] != count*waves or
                values["submitFull"] != values["retries"] or
                (cap>=count and values["retries"])):
                raise ValueError(f"P18 PI affinity event failure: {path}, round {trial}")
            seen.add(case)
            seeds.add(int(row["seed"]))
        if seen != CELLS or len(seeds) != 1 or min(seeds) <= 0:
            raise ValueError(f"P18 PI affinity seed/scenario drift: {path}")
    return rows

def analyze(folder, sessions=4, warmups=2, rounds=5,
            count=2048, waves=3, verify_pair=True):
    if sessions != 4 or warmups < 0 or rounds < 1 or count < 1 or waves < 1:
        raise ValueError("P18 PI affinity fixed research matrix required")
    expected = {
        f"session{s}-cpu{cpu}-{arm}.csv"
        for s in range(1,sessions+1) for cpu in CPUS
        for arm in ("pi-control", "pi-grace")
    }
    observed = {p.name for p in folder.glob("*.csv")}
    if observed != expected:
        raise ValueError(f"P18 PI affinity missing/unexpected CSV: "
                         f"missing={sorted(expected-observed)} extra={sorted(observed-expected)}")
    metrics = defaultdict(lambda: defaultdict(list))
    canonical_checksums = {}
    pairs = 0
    for s in range(1, sessions+1):
        per_cpu = {}
        for cpu in CPUS:
            paths = {
                arm: folder/f"session{s}-cpu{cpu}-{arm}.csv"
                for arm in ("pi-control","pi-grace")
            }
            if verify_pair:
                original_pi_audit(paths["pi-control"], paths["pi-grace"],
                                  len(CELLS)*(warmups+rounds),count,waves)
            l = load(paths["pi-control"],warmups,rounds,count,waves)
            r = load(paths["pi-grace"],warmups,rounds,count,waves)
            for i,(left,right) in enumerate(zip(l,r)):
                if any(left[key]!=right[key] for key in FIELDS):
                    raise ValueError(f"P18 PI different work/seed: s{s}, cpu{cpu}, row{i}")
                it = int(left["iterations"]); cap = int(left["ingress"])
                if it in canonical_checksums and canonical_checksums[it]!=left["checksum"]:
                    raise ValueError("P18 PI cross-affinity checksum mismatch")
                canonical_checksums[it] = left["checksum"]
                if left["phase"]=="measure":
                    pairs+=1
                    for arm,row in (("M0",left),("P18",right)):
                        cell=(cpu,it,cap)
                        for name in NEEDED:
                            metrics[cell][arm+"_"+name].append(int(row[name]))
            per_cpu[cpu]=(l,r)
        # An identical session uses the same seed + source-pinned shuffle
        # across masks, including all warmup phases, not just checksums.
        for (a,b) in zip(per_cpu[1][0], per_cpu[4][0]):
            if any(a[k]!=b[k] for k in FIELDS):
                raise ValueError(f"P18 PI source/seed/shuffle mismatch across CPU masks: session{s}")
    if pairs!=sessions*len(CPUS)*len(CELLS)*rounds:
        raise ValueError("P18 PI affinity measured pair count mismatch")
    print(f"P18 PI AFFINITY PASS process_csv={len(expected)} "
          f"measured_exact_pairs={pairs} warmup_exact_pairs="
          f"{sessions*len(CPUS)*len(CELLS)*warmups} checksum={canonical_checksums}")
    for cpu in CPUS:
        for it in ITERATIONS:
            for cap in CAPACITIES:
                cell=(cpu,it,cap)
                vals=metrics[cell]
                def m(arm,name): return median(vals[arm+"_"+name])
                print(
                    f"PI EVENT ONLY cpus={cpu} iterations={it} ingress={cap} "
                    f"M0/P18 Condition.wait_calls="
                    f"{m('M0','park_waits'):.1f}/{m('P18','park_waits'):.1f} "
                    f"M0/P18 park_without_outstanding="
                    f"{m('M0','park_no_outstanding'):.1f}/{m('P18','park_no_outstanding'):.1f} "
                    f"M0/P18 park_with_outstanding="
                    f"{m('M0','park_with_outstanding'):.1f}/{m('P18','park_with_outstanding'):.1f} "
                    f"M0/P18 batch_claims="
                    f"{m('M0','batch_claims'):.1f}/{m('P18','batch_claims'):.1f} "
                    f"M0/P18 inbox_take_calls="
                    f"{m('M0','takeCalls'):.1f}/{m('P18','takeCalls'):.1f} "
                    f"M0/P18 producer_full="
                    f"{m('M0','submitFull'):.1f}/{m('P18','submitFull'):.1f} "
                    f"M0/P18 poll_yields="
                    f"{m('M0','pollYields'):.1f}/{m('P18','pollYields'):.1f} "
                    f"P18 grace_search/recovered_inbox/fallback/drained="
                    f"{m('P18','grace_searches'):.1f}/"
                    f"{m('P18','grace_recovered_inbox'):.1f}/"
                    f"{m('P18','grace_fallbacks'):.1f}/"
                    f"{m('P18','grace_drain_exits'):.1f} "
                    f"n={len(vals['M0_park_waits'])}")
    print("NOT SPEED EVIDENCE: mutex-owned event counters perturb scheduling; "
          "Condition.wait count does not measure kernel blocking time.")

def self_test():
    from m1_p18_512_trace_compare import STAGES
    from m1_p18_pi_compare import FIELDS as PI_FIELDS
    columns=list(FIELDS)+list(STAGES)+["total_ns"]+list(EVENTS)+list(PI_FIELDS)+["pollYields","retries","park_count"]
    columns=list(dict.fromkeys(columns))
    with tempfile.TemporaryDirectory() as root:
        folder=Path(root)
        for s in range(1,5):
            for cpu in CPUS:
                for arm in ("pi-control","pi-grace"):
                    with (folder/f"session{s}-cpu{cpu}-{arm}.csv").open("w",newline="") as dest:
                        wr=csv.DictWriter(dest,fieldnames=columns);wr.writeheader()
                        for round_index in (0,1):
                            for order,(it,cap) in enumerate((i,c) for i in ITERATIONS for c in CAPACITIES):
                                row={c:"0" for c in columns}
                                row.update(phase="warmup" if round_index==0 else "measure",
                                    round=str(round_index),order=str(order),seed=str(s),
                                    workers="1",count="16",waves="2",iterations=str(it),
                                    ingress=str(cap),checksum=str(it+42),
                                    prepare_ns="5",pool_start_ns="5",waves_ns="100",
                                    join_ns="5",verify_ns="5",total_ns="120",
                                    submitCalls="32",submitAccepted="32",takenTasks="32",
                                    completeCalls="32",batch_tasks="32",batch_claims="4",
                                    takeCalls="4",wakeReads="4",peakUsed="1",
                                    acceptOccupancy1to8="32",min_worker_tasks="32",
                                    max_worker_tasks="32",park_count="0",park_waits="0")
                                wr.writerow(row)
        analyze(folder, sessions=4,warmups=1,rounds=1,count=16,waves=2)
        sample=folder/"session1-cpu1-pi-control.csv"
        t=sample.read_text()
        header, *lines=t.splitlines()
        order=header.split(",")
        field=order.index("park_count")
        x=lines[0].split(",");x[field]="1";lines[0]=",".join(x)
        sample.write_text("\n".join([header]+lines)+"\n")
        try:
            analyze(folder,sessions=4,warmups=1,rounds=1,count=16,waves=2)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted false Condition.wait mismatch")
    print("P18 PI AFFINITY negative conservation regression PASS")

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("csv_dir",type=Path,nargs="?")
    parser.add_argument("--sessions",type=int,default=4)
    parser.add_argument("--warmups",type=int,default=2)
    parser.add_argument("--rounds",type=int,default=5)
    parser.add_argument("--count",type=int,default=2048)
    parser.add_argument("--waves",type=int,default=3)
    parser.add_argument("--self-test",action="store_true")
    args=parser.parse_args()
    if args.self_test: self_test()
    else:
        if args.csv_dir is None: parser.error("CSV directory required")
        analyze(args.csv_dir,args.sessions,args.warmups,args.rounds,
                args.count,args.waves)
