#!/usr/bin/env python3
"""P38 exact-source gate for condition-variable wake protocol."""
import hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
PINS={
 "source/concurrency/internal/submission_pool.d":"b7d8fafcb3179f00cba7e89e28c6d6b9b676353a",
 "source/concurrency/internal/owned_task.d":"e74d6a73f956c562eab176e27687a47249f5815d",
}
def source(path,expected):
    raw=(ROOT/path).read_bytes()
    got=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
    if got!=expected: raise ValueError("P38 source drift: "+path+" "+got)
    return raw.decode()
def ordered(s,*tokens):
    pos=0
    for token in tokens:
        i=s.find(token,pos)
        if i<0: raise ValueError("P38 predicate/order drift: "+token)
        pos=i+len(token)
def main():
    pool=source(next(iter(PINS)),PINS["source/concurrency/internal/submission_pool.d"])
    owner=source("source/concurrency/internal/owned_task.d",PINS["source/concurrency/internal/owned_task.d"])
    def section(begin,end):
        start=pool.index(begin)
        return pool[start:pool.index(end,start)]
    ordered(section("    SubmissionResult trySubmit(TaskRef task)","    bool hasCapacity()"),
            "synchronized (_mutex)","++_used;","++_accepted;",
            "++_generation;","_changed.notify();")
    ordered(section("    void parkUnlessChanged(size_t observed)","    size_t parkCount()"),
            "synchronized (_mutex)","_generation == observed &&",
            "_used == 0 &&","!(_closed && _completed == _accepted)",
            "++_parkCount;","_changed.wait();")
    ordered(section("    void announceLocalWork()","    void parkUnlessChanged"),
            "synchronized (_mutex)","++_generation;","_changed.notify();")
    ordered(section("    void close()","    size_t wakeGeneration()"),
            "_closed = true;","++_generation;","_changed.notifyAll();")
    ordered(section("    private void workerLoop(size_t self)","version (unittest)"),
            "const observed = _inbox.wakeGeneration();",
            "const taken = _inbox.takeBatch(batch[]);",
            "if (enqueued)","_inbox.announceLocalWork();",
            "if (_inbox.isDrained())","_inbox.parkUnlessChanged(observed);")
    ordered(owner,"_retained ~= RetainedTask","_pool.trySubmit(node.reference())")
    print("P38_WAKE_SOURCE_PIN_PASS generation_predicate_notify_order=true")
if __name__=="__main__":
    main()
