#!/usr/bin/env python3
"""P37 source-pinned nested inbox lock structure gate (research only)."""
import hashlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
PINS={
    "source/concurrency/internal/submission_pool.d":
        "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a",
    "source/concurrency/internal/owned_task.d":
        "e74d6a73f956c562eab176e27687a47249f5815d",
}

def pinned(path, expected):
    data=(ROOT/path).read_bytes()
    digest=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
    if digest!=expected:
        raise ValueError("P37 source pin drift: "+path+" "+digest)
    return data.decode()

def main():
    source={key:pinned(key,value) for key,value in PINS.items()}
    pool=source["source/concurrency/internal/submission_pool.d"]
    owner=source["source/concurrency/internal/owned_task.d"]
    start=pool.index("private final class TaskInbox")
    end=pool.index("package(concurrency) final class SubmissionWorkerPool")
    inbox=pool[start:end]
    begin=inbox.index("    SubmissionResult trySubmit(TaskRef task)")
    stop=inbox.index("    bool hasCapacity()", begin)
    path=inbox[begin:stop]
    tokens=[
        "if (task.ptr is null)",
        "synchronized (_mutex)",
        "if (_closed)",
        "if (_used == _slots.length)",
        "const tail = (_head + _used) % _slots.length;",
        "_slots[tail] = task;",
        "++_used;",
        "++_accepted;",
        "++_generation;",
        "_changed.notify();",
        "return SubmissionResult.accepted;",
    ]
    position=0
    for token in tokens:
        found=path.find(token,position)
        if found<0: raise ValueError("P37 inbox order drift: "+token)
        position=found+len(token)
    capacity=inbox[stop:inbox.index("    size_t takeBatch(",stop)]
    if "synchronized (_mutex)" not in capacity:
        raise ValueError("P37 capacity mutex drift")
    first=owner.index("auto trySubmit(F)(F callable)")
    second=owner.index("private void reapCompletedUnderLock()",first)
    submit=owner[first:second]
    if submit.index("_pool.hasIngressCapacity()")>submit.index("new ResultCell!R()"):
        raise ValueError("P37 preallocation capacity gate drift")
    if submit.index("_retained ~= RetainedTask")>submit.index("_pool.trySubmit(node.reference())"):
        raise ValueError("P37 root publication order drift")
    if "return _inbox.trySubmit(task);" not in pool:
        raise ValueError("P37 pool delegation drift")
    print("P37_INBOX_SOURCE_ORDER_PASS precheck_two_locks=true")
    print("P37_INBOX_PHASES validation,ring_publish,notify")

if __name__=="__main__":
    main()
