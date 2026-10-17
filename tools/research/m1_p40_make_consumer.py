#!/usr/bin/env python3
"""P40 P31 consumer with post-wait outcome conservation."""
from pathlib import Path
import subprocess,sys
def main():
    root,original,out=map(Path,sys.argv[1:4])
    tmp=out.with_suffix(".p39.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p39_make_consumer.py"),str(root),str(original),str(tmp)],check=True)
        s=tmp.read_text()
    finally:
        tmp.unlink(missing_ok=True)
    for old,new in (("module concurrency.research.p39_generational_owner;","module concurrency.research.p40_generational_owner;"),
                    ("import concurrency.research.m1_p39_owned :","import concurrency.research.m1_p40_owned :"),
                    ("import concurrency.research.m1_p39_pool :","import concurrency.research.m1_p40_pool :"),
                    ("P39_NOTIFY_BENCHMARK_PASS","P40_OUTCOME_BENCHMARK_PASS")):
        if old not in s: raise ValueError("P40 consumer marker drift: "+old)
        s=s.replace(old,new)
    needle="        ulong p38ParkCalls, p38WaitEntries, p38WaitReturns;"
    if s.count(needle)!=1: raise ValueError("P40 worker snapshot anchor drift")
    s=s.replace(needle,'''        ulong p40Local, p40Inbox, p40Steal, p40Repark, p40Drained;
'''+needle,1)
    anchor="                p38WaitReturns += worker.waitReturns;"
    if s.count(anchor)!=1: raise ValueError("P40 worker tally anchor drift")
    s=s.replace(anchor,anchor+'''
                p40Local += worker.postLocal;
                p40Inbox += worker.postInbox;
                p40Steal += worker.postSteal;
                p40Repark += worker.postRepark;
                p40Drained += worker.postDrained;''',1)
    anchor='            check(p38WaitEntries == p38WaitReturns,'
    if s.count(anchor)!=1: raise ValueError("P40 conservation anchor drift")
    s=s.replace(anchor,'''            check(p40Local + p40Inbox + p40Steal +
                p40Repark + p40Drained == p38WaitReturns,
                "P40 post-wait outcome conservation");
'''+anchor,1)
    row='p39Publish, ",", p39Local, ",", p39Close, ",", p39Final);'
    if s.count(row)!=1: raise ValueError("P40 CSV output drift")
    s=s.replace(row,'p39Publish, ",", p39Local, ",", p39Close, ",", p39Final, ",",'+chr(10)+
        '            p40Local, ",", p40Inbox, ",", p40Steal, ",", p40Repark, ",", p40Drained);',1)
    header="notify_publish,notify_local,notify_close_all,notify_final_all"
    if s.count(header)!=1: raise ValueError("P40 CSV header drift")
    s=s.replace(header,header+",post_local,post_inbox,post_steal,post_repark,post_drained",1)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P40_CONSUMER_SOURCE_PIN_PASS")
if __name__=="__main__": main()
