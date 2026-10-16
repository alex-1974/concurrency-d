#!/usr/bin/env python3
"""P37 consumer from pinned P31 via validated P35 telemetry scaffold."""
from pathlib import Path
import subprocess
import sys

def once(s,old,new):
    if s.count(old)!=1: raise ValueError("P37 consumer anchor drift: "+old[:72])
    return s.replace(old,new,1)

def main():
    root,original,out=map(Path,sys.argv[1:4])
    tmp=out.with_suffix(".p35.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p35_make_consumer.py"),
                        str(original),str(tmp)],check=True)
        s=tmp.read_text()
    finally:
        tmp.unlink(missing_ok=True)
    s=once(s,"module concurrency.research.p35_generational_owner;",
           "module concurrency.research.p37_generational_owner;")
    s=once(s,"import concurrency.research.m1_p35_owned : OwnedTaskExecutor, p35Take;",
           "import concurrency.research.m1_p37_owned : OwnedTaskExecutor;\n"
           "import concurrency.research.m1_p37_pool : p37Take;")
    for old,new in (("p35Take","p37Take"),("p35Calls","p37Calls"),("p35WaitNs","p37WaitNs"),("p35HoldNs","p37QueueNs"),("observed.holdNs","observed.queueNs"),("owner_wait_ns","inbox_wait_ns"),("owner_hold_ns","inbox_queue_ns"),("P35_OWNER_MUTEX_BENCHMARK_PASS","P37_INBOX_BENCHMARK_PASS")):
        if old not in s: raise ValueError("P37 field drift: "+old)
        s=s.replace(old,new)
    s=once(s,'            const startBytes = GC.allocatedInCurrentThread();',
       '            auto p37Prior = p37Take();'+chr(10)+'            const startBytes = GC.allocatedInCurrentThread();')
    s=once(s,'            stats.p37Calls = observed.calls;',
       '            stats.p37Calls = observed.calls;'+chr(10)+
       '            check(stats.p37Calls == (mode == P31Mode.m0 ? 0 : stats.accepted), "P37 inbox calls differ from producer admissions");')
    s=once(s,'check(p37Calls == (mode == P31Mode.m0 ? 0 : attempts),','check(p37Calls == (mode == P31Mode.m0 ? 0 : acknowledged),')
    decl='ulong p37Calls, p37WaitNs, p37QueueNs;'
    if s.count(decl)!=2: raise ValueError('P37 declarations drift')
    s=s.replace(decl,'ulong p37Calls, p37WaitNs, p37QueueNs, p37NotifyNs;')
    s=once(s,'            stats.p37QueueNs = observed.queueNs;',
      '            stats.p37QueueNs = observed.queueNs;'+chr(10)+
      '            stats.p37NotifyNs = observed.notifyNs;')
    s=once(s,'            p37QueueNs += stat.p37QueueNs;','            p37QueueNs += stat.p37QueueNs;'+chr(10)+'            p37NotifyNs += stat.p37NotifyNs;')
    s=once(s,'p37Calls, ",", p37WaitNs, ",", p37QueueNs);','p37Calls, ",", p37WaitNs, ",", p37QueueNs, ",", p37NotifyNs);')
    s=once(s,'inbox_wait_ns,inbox_queue_ns','inbox_wait_ns,inbox_queue_ns,inbox_notify_ns')
    s=once(s,'    if (!correct)'+chr(10)+'        throw new Exception("P29: " ~ reason);','    if (!correct)'+chr(10)+'    {'+chr(10)+'        import std.string : toStringz;'+chr(10)+'        fprintf(stderr, "P37_CHECK_FAILURE: %s\\n", reason.toStringz);'+chr(10)+'        fflush(stderr);'+chr(10)+'        throw new Exception("P29: " ~ reason);'+chr(10)+'    }')
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P37_CONSUMER_SOURCE_PIN_PASS")

if __name__=="__main__":
    main()
