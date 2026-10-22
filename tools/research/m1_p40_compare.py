#!/usr/bin/env python3
"""Check P40 five-way post-wait conservation and inherit P39 validation."""
import argparse,csv,subprocess,sys,tempfile
from pathlib import Path
EXTRA=("post_local","post_inbox","post_steal","post_repark","post_drained")
def project(src,dst):
    with src.open(newline="") as inp,dst.open("w",newline="") as out:
        reader=csv.DictReader(inp)
        if tuple(reader.fieldnames or ())[-5:]!=EXTRA:
            raise ValueError("P40 CSV schema drift")
        fields=reader.fieldnames[:-5]
        writer=csv.DictWriter(out,fieldnames=fields)
        writer.writeheader()
        count=0
        for row in reader:
            values=[int(row[k]) for k in EXTRA]
            if any(x<0 for x in values): raise ValueError("P40 negative outcome")
            if sum(values)!=int(row["wait_returns"]): raise ValueError("P40 wait-return conservation")
            if row["mode"]=="m0" and any(values): raise ValueError("P40 m0 outcome")
            writer.writerow({k:row[k] for k in fields})
            count+=1
    return count
def main():
    p=argparse.ArgumentParser()
    p.add_argument("null",type=Path)
    p.add_argument("timed",type=Path)
    p.add_argument("--min-rounds",type=int,default=3)
    a=p.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        x,y=Path(tmp)/"null.csv",Path(tmp)/"timed.csv"
        n=project(a.null,x)
        if project(a.timed,y)!=n: raise ValueError("P40 arm row mismatch")
        subprocess.run([sys.executable,str(Path(__file__).with_name("m1_p39_compare.py")),str(x),str(y),"--min-rounds",str(a.min_rounds)],check=True)
    print("P40_OUTCOME_MATCH_PASS",n)
if __name__=="__main__": main()
