#!/usr/bin/env python3
"""Validate P39 notification-site conservation then run P38/P37 paired gates."""
import argparse,csv,subprocess,sys,tempfile
from pathlib import Path
EXT=("notify_publish","notify_local","notify_close_all","notify_final_all")
def project(source,out):
    with source.open(newline="") as stream,out.open("w",newline="") as target:
        reader=csv.DictReader(stream)
        if tuple(reader.fieldnames or ())[-4:]!=EXT: raise ValueError("P39 column schema drift")
        writer=csv.DictWriter(target,fieldnames=reader.fieldnames[:-4])
        writer.writeheader()
        n=0
        for row in reader:
            publish,local,close,final=(int(row[k]) for k in EXT)
            if min(publish,local,close,final)<0: raise ValueError("P39 negative counts")
            expected=int(row["accepted"])
            if row["mode"]=="m0":
                if any((publish,local,close,final)): raise ValueError("P39 m0 site counters")
            else:
                if publish!=expected or close!=1 or final>1:
                    raise ValueError("P39 publish / close / final accounting")
            writer.writerow({k:row[k] for k in reader.fieldnames[:-4]})
            n+=1
    return n
def main():
    p=argparse.ArgumentParser()
    p.add_argument("null",type=Path)
    p.add_argument("timed",type=Path)
    p.add_argument("--min-rounds",type=int,default=3)
    a=p.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        x,y=Path(tmp)/"null.csv",Path(tmp)/"timed.csv"
        n=project(a.null,x)
        if n!=project(a.timed,y): raise ValueError("P39 arm rows differ")
        subprocess.run([sys.executable,str(Path(__file__).with_name("m1_p38_compare.py")),
            str(x),str(y),"--min-rounds",str(a.min_rounds)],check=True)
    print("P39_NOTIFICATION_SITE_MATCH_PASS",n)
if __name__=="__main__": main()
