#!/usr/bin/env python3
"""P36 timed and null phase conservation checker."""
import argparse
import csv
from pathlib import Path


COLUMNS = ("phase","round","work","producers","mode","count","workers",
           "ingress","retained","accepted","completed","executed","checksum",
           "attempts","producer_alloc_bytes","create_start_ns","submit_ns",
           "join_release_ns","total_ns","owner_calls","capacity_ns",
           "construct_ns","retain_ns","publish_ns")
PHASES=("capacity_ns","construct_ns","retain_ns","publish_ns")

def load(path):
    with path.open(newline="") as stream:
        reader=csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != COLUMNS:
            raise ValueError("P36 CSV schema drift")
        rows={}
        for row in reader:
            for name in COLUMNS:
                if name not in ("phase","work","mode"):
                    row[name]=int(row[name])
                    if row[name]<0: raise ValueError("P36 negative value")
            key=(row["phase"],row["round"],row["work"],row["producers"],row["mode"])
            if key in rows: raise ValueError("P36 duplicate row")
            rows[key]=row
    return rows

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('null',type=Path)
    parser.add_argument('timed',type=Path)
    parser.add_argument('--min-rounds',type=int,default=3)
    args=parser.parse_args()
    a,b=load(args.null),load(args.timed)
    if a.keys()!=b.keys(): raise ValueError('P36 unmatched rows')
    rounds={k[1] for k in a if k[0]=='measure'}
    if len(rounds)<args.min_rounds: raise ValueError('P36 too few rounds')
    for row in a.values():
        if row['accepted']!=row['count'] or row['completed']!=row['count']:
            raise ValueError('P36 missing task')
    for k,y in b.items():
        x=a[k]
        for name in ('count','workers','ingress','retained','accepted','completed','executed','checksum'):
            if x[name]!=y[name]: raise ValueError('P36 mismatched task work')
        if any(x[n] for n in PHASES): raise ValueError('P36 null has clocks')
    for k,y in b.items():
        if y['mode']!='m0' and any(y[name]<=0 for name in PHASES):
            raise ValueError('P36 timed phase missing')
        for arm, record in (('null', a[k]), ('timed', y)):
            expected = 0 if record['mode']=='m0' else record['attempts']
            if record['owner_calls'] != expected:
                raise ValueError('P36 calls: '+str((k,arm,expected,record['owner_calls'])))
    expected={(rid,kind,producers,owner) for rid in rounds
        for kind in ('minimal','shared_atomic','sharded_atomic')
        for producers in (1,2,4) for owner in ('m0','deferred','managed')}
    got={(k[1],k[2],k[3],k[4]) for k in a if k[0]=='measure'}
    if expected!=got: raise ValueError('P36 incomplete profile matrix')
    print('P36_PHASE_MATCH_PASS diagnostic_only=true')

if __name__=='__main__':
    main()
