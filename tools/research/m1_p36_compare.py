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
    print('P36_COMPARE_PENDING')

if __name__=='__main__':
    main()
