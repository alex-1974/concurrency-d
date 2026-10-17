#!/usr/bin/env python3
"""P42.1 bounded 2-worker/2-producer notify-policy model; research-only.

One outstanding task per producer; FIFO inbox capacity 2, single-task worker
claim, epoch capture, wakeups. This abstraction omits local deque, stealing,
task lifetime, mutex timing, and notifyAll scheduling effects.
"""
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
import sys

@dataclass(frozen=True)
class State:
    generation: int = 0
    published: int = 0
    completed: int = 0
    inbox: int = 0
    # worker states: 0 = search, 1 = parked, 2 = running, 3 = exited
    workers: tuple = (0, 0)
    tickets: tuple = (-1, -1)
    closed: bool = False
    notify_calls: int = 0

def choices(s, policy):
    if s.published < 2 and not s.closed and s.inbox < 2:
        waiting = [i for i, w in enumerate(s.workers) if w == 1]
        n = policy == "baseline" or (
            policy == "waiter" and bool(waiting))
        wakes = waiting if n else []
        # notify wakes AT MOST one condition waiter; select every possible one
        targets = wakes if wakes else [-1]
        for target in targets:
            workers = list(s.workers)
            if target >= 0:
                workers[target] = 0
            yield "publish" + str(target), replace(
                s, published=s.published + 1, inbox=s.inbox + 1,
                generation=s.generation + 1, workers=tuple(workers),
                notify_calls=s.notify_calls + int(n))
    for i, phase in enumerate(s.workers):
        if phase == 0:
            if s.inbox:
                a=list(s.workers); a[i]=2
                yield "claim" + str(i), replace(s, workers=tuple(a), inbox=s.inbox-1)
            elif s.closed and s.completed == s.published:
                a=list(s.workers); a[i]=3
                yield "exit" + str(i), replace(s, workers=tuple(a))
            else:
                # model captures a ticket and checks the predicate under lock;
                # since search and park are conflated here, no stale ticket.
                a=list(s.workers); a[i]=1
                yield "park" + str(i), replace(s, workers=tuple(a))
        elif phase == 2:
            a=list(s.workers); a[i]=0
            yield "complete" + str(i), replace(s, workers=tuple(a), completed=s.completed+1)
    if not s.closed:
        a=list(s.workers)
        # close broadcasts all sleeping workers
        a=[0 if w==1 else w for w in a]
        yield "close",replace(s, closed=True, generation=s.generation+1, workers=tuple(a))

def search(policy):
    initial=State()
    queue=deque([(initial, ())])
    seen=set()
    stuck=[]
    terminal=0
    while queue:
        s,trace=queue.popleft()
        if s in seen: continue
        seen.add(s)
        assert 0<=s.completed<=s.published<=2
        assert s.inbox <= s.published - s.completed
        assert len(trace)<32, (s,trace)
        if s.closed and s.workers==(3,3):
            assert s.completed==s.published, (policy,trace,s)
            terminal+=1
        # Quiescent lost-work witness before close: all workers parked, work
        # exists, and no other runnable producer publication is required.
        if s.inbox and s.workers==(1,1) and s.published==2:
            stuck.append((trace,s))
        for label,nxt in choices(s,policy):
            queue.append((nxt,trace+(label,)))
    return len(seen),terminal,stuck

def source_audit(path):
    s=Path(path).read_text()
    for anchor in ("++_generation;\n            _changed.notify();",
                   "const observed = _inbox.wakeGeneration();",
                   "_inbox.parkUnlessChanged(observed);",
                   "_changed.notifyAll();"):
        assert anchor in s, "P42 source drift: "+anchor[:50]

def main():
    source_audit(sys.argv[1])
    for policy in ("baseline","waiter","silent"):
        states,terminations,stuck=search(policy)
        assert states and terminations
        if policy=="silent":
            assert stuck, "silent policy expected to exhibit lost wakeup"
            print("P42_COUNTEREXAMPLE silent", " -> ".join(stuck[0][0]))
        else:
            assert not stuck, (policy,stuck[:1])
        print("P42_BOUND_MODEL_PASS",policy,"states",states,
              "terminal",terminations,"quiescent_lost_work",len(stuck))
    print("P42_MODEL_LIMIT no local-deque/steal, no per-wait enrollment race, no GC/OS proof")

if __name__=="__main__":main()
