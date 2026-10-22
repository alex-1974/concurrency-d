#!/usr/bin/env python3
"""Generate a research-only, source-pinned P37 inbox observation copy."""
from pathlib import Path
import hashlib
import sys

PIN="b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def once(text,old,new):
    if text.count(old)!=1:
        raise ValueError("P37 inbox anchor drift: "+old[:70])
    return text.replace(old,new,1)

def main():
    original,out=map(Path,sys.argv[1:3])
    raw=original.read_bytes()
    got=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
    if got!=PIN: raise ValueError("P37 inbox source pin drift: "+got)
    text=raw.decode()
    text=once(text,"module concurrency.internal.submission_pool;",
              "module concurrency.research.m1_p37_pool;")
    stats='''import core.time : MonoTime;
package(concurrency) struct P37InboxStats
{
    ulong calls, waitNs, queueNs, notifyNs, rejects;
}
private P37InboxStats p37Local;
package(concurrency) P37InboxStats p37Take()
{
    auto result=p37Local;
    p37Local=P37InboxStats.init;
    return result;
}
'''
    text=once(text,"import core.sync.condition :",
              stats+"import core.sync.condition :")
    text=once(text,
        '        synchronized (_mutex)'+chr(10)+'        {'+chr(10)+
        '            if (_closed)',
        '        ++p37Local.calls;'+chr(10)+
        '        version (P37Timed)'+chr(10)+
        '            const p37Before = MonoTime.currTime;'+chr(10)+
        '        synchronized (_mutex)'+chr(10)+'        {'+chr(10)+
        '            version (P37Timed)'+chr(10)+
        '                p37Local.waitNs += cast(ulong)'+chr(10)+
        '                    (MonoTime.currTime - p37Before).total!"nsecs";'+chr(10)+
        '            if (_closed)')
    text=once(text,'            const tail = (_head + _used) % _slots.length;', '            version (P37Timed)'+chr(10)+'                const p37QueueStart = MonoTime.currTime;'+chr(10)+'            const tail = (_head + _used) % _slots.length;')
    text=once(text, '            _changed.notify();'+chr(10)+'            return SubmissionResult.accepted;',
        '            version (P37Timed)'+chr(10)+'                p37Local.queueNs += cast(ulong)(MonoTime.currTime - p37QueueStart).total!"nsecs";'+chr(10)+'            version (P37Timed)'+chr(10)+'                const p37NotifyStart = MonoTime.currTime;'+chr(10)+'            _changed.notify();'+chr(10)+'            version (P37Timed)'+chr(10)+'                p37Local.notifyNs += cast(ulong)(MonoTime.currTime - p37NotifyStart).total!"nsecs";'+chr(10)+'            return SubmissionResult.accepted;')
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(text)
    print("P37_POOL_PIN_PASS")

if __name__=="__main__":
    main()
