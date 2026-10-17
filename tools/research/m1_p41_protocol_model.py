#!/usr/bin/env python3
"""P41: finite-state wake/close protocol model, NOT a runtime scheduler test.

Explore atomic steps taken under inbox mutex; a worker captures generation
before searching, then rechecks under lock before parking. Enumerates short
interleavings, including artificial spurious condition returns.
"""
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
import hashlib, sys

@dataclass(frozen=True)
class S:
    generation:int=0
    used:int=0
    accepted:int=0
    completed:int=0
    closed:bool=False
    observed:int=-1
    worker:int=0 # 0=before ticket; 1=ticket captured; 2=waiting; 3=done
    producer:int=0 # 0=unpublished, 1=published
    closer:int=0 # 0=open, 1=closed
    waits:int=0
    spurious:int=0

def park_predicate(s):
    return s.generation==s.observed and s.used==0 and not (
        s.closed and s.completed==s.accepted)

def transitions(s):
    if s.worker==0:
        yield "capture",replace(s,observed=s.generation,worker=1)
    if s.worker==1:
        if not park_predicate(s):
            yield "park-skip",replace(s,worker=3)
        else:
            yield "wait-enter",replace(s,worker=2,waits=s.waits+1)
    if s.worker==2:
        # Spurious return cannot complete a wait when predicate is unchanged.
        if s.spurious<2 and park_predicate(s):
            yield "spurious-rewait",replace(s,waits=s.waits+1,spurious=s.spurious+1)
        elif not park_predicate(s):
            yield "wait-exit",replace(s,worker=3)
    if s.producer==0 and not s.closed:
        yield "publish",replace(s,producer=1,used=s.used+1,
                                  accepted=s.accepted+1,generation=s.generation+1)
    if s.closer==0:
        yield "close",replace(s,closed=True,closer=1,generation=s.generation+1)
    if s.used and s.completed<s.accepted:
        yield "claim-and-complete",replace(s,used=s.used-1,
                                           completed=s.completed+1,
                                           generation=s.generation+int(s.closed and s.completed+1==s.accepted))

def audit_source(source):
    data=Path(source).read_bytes()
    s=data.decode()
    anchors=[
        "++_generation;\n            _changed.notify();",
        "++_generation;\n            _changed.notifyAll();",
        "++_parkCount;\n                _changed.wait();",
        "while (_generation == observed &&",
        "_used == 0 &&",
        "!(_closed && _completed == _accepted))",
        "const observed = _inbox.wakeGeneration();",
        "_inbox.parkUnlessChanged(observed);",
    ]
    for x in anchors:
        if x not in s: raise AssertionError("P41 source protocol drift: "+x)
    return hashlib.sha256(data).hexdigest()

def main():
    if len(sys.argv)!=2: raise SystemExit("usage: probe SOURCE_POOL_D")
    digest=audit_source(sys.argv[1])
    q=deque([(S(),())])
    seen=set()
    terminal=0
    spurious_cases=0
    close_races=0
    while q:
        s,trace=q.popleft()
        if s in seen: continue
        seen.add(s)
        assert 0<=s.completed<=s.accepted<=1
        assert s.used<=s.accepted-s.completed
        if s.worker==2 and not park_predicate(s):
            # Predicate is false after a publication/close: rechecking
            # must permit a worker to leave the condition loop.
            assert any(k=="wait-exit" for k,_ in transitions(s)),trace
        if s.worker==3:
            terminal+=1
            spurious_cases+=int(s.spurious>0)
            close_races+=int(s.closed)
        for name,nxt in transitions(s):
            assert len(trace)<16,(s,trace)
            q.append((nxt,trace+(name,)))
    assert terminal>0 and spurious_cases>0 and close_races>0
    print("P41_FINITE_STATE_MODEL_PASS",
          "states="+str(len(seen)), "terminal="+str(terminal),
          "spurious_cases="+str(spurious_cases),
          "close_cases="+str(close_races),
          "pool_sha256="+digest)
    print("P41_MODEL_LIMIT one_worker_one_producer_one_task bounded_spurious=2; no OS/GC scheduling proof")

if __name__=="__main__": main()
