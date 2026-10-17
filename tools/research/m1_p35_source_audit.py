#!/usr/bin/env python3
"""P35 independent pinned-source gate for owner-lock nesting, not timing proof."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    "source/concurrency/internal/owned_task.d":
        "e74d6a73f956c562eab176e27687a47249f5815d",
    "source/concurrency/internal/submission_pool.d":
        "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a",
    "research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d":
        "d19405f2ef0f8d7159978174c1a919ed6d66764f",
}

def pinned(path, digest):
    raw=(ROOT/path).read_bytes()
    actual=hashlib.sha1(b"blob "+str(len(raw)).encode()+bytes([0])+raw).hexdigest()
    if actual!=digest:
        raise ValueError(f"P35 source drift {path}: {actual}")
    return raw.decode()

def segment(s,start,end):
    if s.count(start)!=1 or s.count(end)<1:
        raise ValueError("P35 source anchor drift: "+start)
    return s.split(start,1)[1].split(end,1)[0]

def main():
    source={name:pinned(name,digest) for name,digest in SOURCES.items()}
    owner=segment(source["source/concurrency/internal/owned_task.d"],
        "    auto trySubmit(F)(F callable) @system",
        "    private void reapCompletedUnderLock()")
    checks=(
        "synchronized (_mutex)",
        "if (_retained.length >= _maxRetained)",
        "reapCompletedUnderLock();",
        "if (!_pool.hasIngressCapacity())",
        "auto cell = new ResultCell!R();",
        "handle = new TaskHandle!R(cell);",
        "auto node = new OwnedNode!(F, R)(callable, cell);",
        "_retained ~= RetainedTask(node, node.returnedFlag());",
        "const status = _pool.trySubmit(node.reference());",
        "if (status != SubmissionResult.accepted)",
    )
    if any(owner.count(x)!=(2 if x=="if (_retained.length >= _maxRetained)" else 1) for x in checks):
        raise ValueError("P35 owner critical section changed")
    if owner.count("if (_retained.length >= _maxRetained)") != 2:
        raise ValueError("P35 retention second capacity gate missing")
    first=owner.index("if (_retained.length >= _maxRetained)")
    second=owner.index("if (_retained.length >= _maxRetained)", first+1)
    if not (first < owner.index("reapCompletedUnderLock();") < second <
            owner.index("if (!_pool.hasIngressCapacity())")):
        raise ValueError("P35 second capacity guard moved relative to reclaim")
    offsets=[owner.index(x) for x in checks]
    if offsets!=sorted(offsets):
        raise ValueError("P35 owner operation order changed")
    manager=segment(
        source["research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d"],
        "    bool publish(F)(OwnerHandle h, F work)",
        "    bool orphan(OwnerHandle h)")
    if manager.count("synchronized (mutex)")!=2:
        raise ValueError("P35 manager guard count changed")
    if not (manager.index("++entries[h.slot].operations;") <
            manager.index("auto result = owner.trySubmit(work);") <
            manager.index("--entries[h.slot].operations;")):
        raise ValueError("P35 manager operation semantics changed")
    print("P35_PINNED_CRITICAL_SECTION_STRUCTURE_PASS")
    print("P35_OBSERVATION source_only=true timing_causality=false")

if __name__=="__main__":
    main()
