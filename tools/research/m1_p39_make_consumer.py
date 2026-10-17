#!/usr/bin/env python3
"""P39 P31 fixture: preserve P38 worker counters and add per-site notify counts."""
from pathlib import Path
import subprocess
import sys
def main():
    root,original,out=map(Path,sys.argv[1:4])
    temp=out.with_suffix(".p38.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p38_make_consumer.py"),str(root),str(original),str(temp)],check=True)
        s=temp.read_text()
    finally:
        temp.unlink(missing_ok=True)
    for old,new in (("module concurrency.research.p38_generational_owner;","module concurrency.research.p39_generational_owner;"),
                    ("import concurrency.research.m1_p38_owned :","import concurrency.research.m1_p39_owned :"),
                    ("import concurrency.research.m1_p38_pool :","import concurrency.research.m1_p39_pool :"),
                    ("P38_WAKE_BENCHMARK_PASS","P39_NOTIFY_BENCHMARK_PASS")):
        if old not in s: raise ValueError("P39 consumer import/marker drift: "+old)
        s=s.replace(old,new)
    anchor="        ulong p38ParkCalls, p38WaitEntries, p38WaitReturns;"
    if s.count(anchor)!=1: raise ValueError("P39 counter anchor drift")
    s=s.replace(anchor,'''        ulong p39Publish, p39Local, p39Close, p39Final;
        if (mode != P31Mode.m0)
        {
            const sites = owned.researchNotificationStats();
            p39Publish = sites.publish;
            p39Local = sites.localWork;
            p39Close = sites.closeAll;
            p39Final = sites.finalCompletionAll;
            check(p39Publish == taskCount && p39Close == 1 &&
                p39Final <= 1, "P39 notification site accounting");
        }
'''+anchor,1)
    row='p38ParkCalls, ",", p38WaitEntries, ",", p38WaitReturns);'
    if s.count(row)!=1: raise ValueError("P39 CSV output drift")
    s=s.replace(row,'p38ParkCalls, ",", p38WaitEntries, ",", p38WaitReturns, ",",'+chr(10)+
        '            p39Publish, ",", p39Local, ",", p39Close, ",", p39Final);',1)
    header="inbox_notify_ns,park_calls,wait_entries,wait_returns"
    if s.count(header)!=1: raise ValueError("P39 CSV header drift")
    s=s.replace(header,header+",notify_publish,notify_local,notify_close_all,notify_final_all",1)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P39_CONSUMER_SOURCE_PIN_PASS")
if __name__=="__main__": main()
