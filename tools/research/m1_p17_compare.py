#!/usr/bin/env python3
"""P17 verify exact input/order/checksum across four execution/trace variants.

No timing ratios in the trace arms are actionable production performance
evidence: trace changes scheduling. Use uninstrumented control vs atomic.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median

KEYS=("phase","round","order","seed","workers","count",
      "waves","iterations","ingress","checksum")
EVENTS=("steal_attempts","steal_successes","park_attempts",
        "park_waits","park_no_outstanding","park_with_outstanding",
        "batch_claims","batch_tasks","local_hits","local_misses",
        "min_worker_tasks","max_worker_tasks")
STAGES=("prepare_ns","pool_start_ns","waves_ns","join_ns","verify_ns")

def read(path):
    with path.open(newline="") as f:
        rows=list(csv.DictReader(f))
    if not rows or not set(KEYS+EVENTS+STAGES+("total_ns",)).issubset(rows[0]):
        raise ValueError(f"P17 CSV invalid: {path}")
    return rows

def compare(paths,minimum):
    data=[read(path) for path in paths]
    n=len(data[0])
    if n<minimum or any(len(d)!=n for d in data):
        raise ValueError("P17 mismatch in mode row counts")
    samples=defaultdict(lambda:defaultdict(list))
    for ix, group in enumerate(zip(*data)):
        base,atomic,trace_base,trace_atomic=group
        for arm in group:
            for name in KEYS:
                if arm[name]!=base[name]:
                    raise ValueError(f"P17 row={ix} mismatched {name}")
            lengths=[int(arm[k]) for k in STAGES]
            if min(lengths)<0 or sum(lengths)!=int(arm["total_ns"]):
                raise ValueError(f"P17 row={ix} non-conserving timing stages")
            if int(arm["waves_ns"])<=0:
                raise ValueError(f"P17 row={ix} nonpositive wave time")
        if any(int(x[key]) for x in (base,atomic) for key in EVENTS):
            raise ValueError(f"P17 row={ix} control/atomic collected diagnostic counters")
        tasks=int(base["count"])*int(base["waves"])
        for arm in (trace_base,trace_atomic):
            a={k:int(arm[k]) for k in EVENTS}
            w=int(arm["workers"])
            if (a["steal_attempts"]<a["steal_successes"] or
                a["park_waits"] != int(arm["park_count"]) or
                a["park_no_outstanding"]+a["park_with_outstanding"] != a["park_waits"] or
                a["park_attempts"]<a["park_waits"] or
                a["batch_tasks"]!=tasks or
                not 0<=a["batch_claims"]<=tasks or
                not 0<=a["min_worker_tasks"]<=a["max_worker_tasks"]<=tasks or
                a["min_worker_tasks"]*w>tasks or
                a["max_worker_tasks"]*w<tasks):
                raise ValueError(f"P17 row={ix} invalid trace event invariants")
        if base["phase"]=="measure":
            key=(int(base["workers"]),int(base["iterations"]),int(base["ingress"]))
            samples[key]["native_ratio"].append(
                int(atomic["waves_ns"])/int(base["waves_ns"]))
            for tag,arm in (("original",trace_base),("atomic",trace_atomic)):
                samples[key][tag+"_failed_steals"].append(
                    int(arm["steal_attempts"])-int(arm["steal_successes"]))
                samples[key][tag+"_park_no_outstanding"].append(
                    int(arm["park_no_outstanding"]))
                samples[key][tag+"_park_with_outstanding"].append(
                    int(arm["park_with_outstanding"]))
    for key,group in sorted(samples.items()):
        print(f"P17 DIAGNOSTIC workers={key[0]} iterations={key[1]} ingress={key[2]} "
              f"UNINSTRUMENTED atomic/original={median(group['native_ratio']):.3f} "
              f"failed_steals original/atomic={median(group['original_failed_steals']):.0f}/"
              f"{median(group['atomic_failed_steals']):.0f} "
              f"park_with_work original/atomic={median(group['original_park_with_outstanding']):.0f}/"
              f"{median(group['atomic_park_with_outstanding']):.0f} "
              f"park_no_work original/atomic={median(group['original_park_no_outstanding']):.0f}/"
              f"{median(group['atomic_park_no_outstanding']):.0f} "
              f"n={len(group['native_ratio'])}")
    if not samples:
        raise ValueError("P17 no measured data")
    print(f"P17 PASS four equal-work modes: {n} rows, {len(samples)} cases")

def main():
    ap=argparse.ArgumentParser()
    for name in ("control","atomic","trace_control","trace_atomic"):
        ap.add_argument(name,type=Path)
    ap.add_argument("--min-rows",type=int,default=12)
    a=ap.parse_args()
    compare([a.control,a.atomic,a.trace_control,a.trace_atomic],a.min_rows)

if __name__=="__main__":
    main()
