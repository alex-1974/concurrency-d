#!/usr/bin/env python3
"""P36 immutable-source phase audit; structural evidence, not sampled timing."""
import hashlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
PINS={
 "source/concurrency/internal/owned_task.d":"e74d6a73f956c562eab176e27687a47249f5815d",
 "source/concurrency/internal/submission_pool.d":"b7d8fafcb3179f00cba7e89e28c6d6b9b676353a",
 "research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d":
  "d19405f2ef0f8d7159978174c1a919ed6d66764f",
}

def read_pin(path,digest):
    raw=(ROOT/path).read_bytes()
    actual=hashlib.sha1(b"blob "+str(len(raw)).encode()+bytes([0])+raw).hexdigest()
    if actual!=digest:
        raise ValueError(f"P36 source changed: {path} {actual}")
    return raw.decode()

def main():
    text={name:read_pin(name,digest) for name,digest in PINS.items()}
    owner=text["source/concurrency/internal/owned_task.d"]
    begin="    auto trySubmit(F)(F callable) @system"
    end="    private void reapCompletedUnderLock()"
    if owner.count(begin)!=1 or owner.count(end)!=1:
        raise ValueError("P36 trySubmit boundaries drifted")
    body=owner.split(begin,1)[1].split(end,1)[0]
    anchors=[
      ("mutex_entry","synchronized (_mutex)"),
      ("budget_initial","if (_retained.length >= _maxRetained)"),
      ("reap","reapCompletedUnderLock();"),
      ("budget_after_reap","if (_retained.length >= _maxRetained)"),
      ("ingress_capacity","if (!_pool.hasIngressCapacity())"),
      ("cell","auto cell = new ResultCell!R();"),
      ("handle","handle = new TaskHandle!R(cell);"),
      ("node","auto node = new OwnedNode!(F, R)(callable, cell);"),
      ("retain","_retained ~= RetainedTask(node, node.returnedFlag());"),
      ("publish","const status = _pool.trySubmit(node.reference());"),
      ("rollback","_retained[$ - 1] = RetainedTask.init;"),
      ("tail_length","_retained.length = _retained.length - 1;"),
    ]
    position=0
    for name,token in anchors:
        at=body.find(token,position)
        if at<0:
            raise ValueError("P36 phase ordering drift: "+name)
        position=at+len(token)
    for token,n in (
        ("synchronized (_mutex)",1),
        ("if (_retained.length >= _maxRetained)",2),
        ("_retained ~= RetainedTask(node, node.returnedFlag());",1),
        ("const status = _pool.trySubmit(node.reference());",1)):
        if body.count(token)!=n:
            raise ValueError("P36 source multiplicity drift: "+token)
    if body.index("_retained ~= RetainedTask")>body.index("_pool.trySubmit(node.reference())"):
        raise ValueError("P36 root must precede ingress publication")
    print("P36_PINNED_CRITICAL_PHASES_PASS source_only=true")
    print("P36_PHASES capacity,reap,construct,retain,publish,rollback")

if __name__=="__main__":
    main()
