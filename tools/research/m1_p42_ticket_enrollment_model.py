#!/usr/bin/env python3
"""P42.2 bounded event-interleaving experiment, not production correctness proof."""
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
import sys

# Phase: 0 capture ticket, 1 inbox search, 2 mutex-held park check,
# 3 actually waiting, 4 executing, 5 exited.
@dataclass(frozen=True)
class State:
    gen:int=0
    published:int=0
    completed:int=0
    inbox:int=0
    closed:bool=False
    phases:tuple=(0,0)
    tickets:tuple=(-1,-1)

def set_worker(s,i,phase,ticket=None):
    a=list(s.phases); a[i]=phase
    b=list(s.tickets)
    if ticket is not None: b[i]=ticket
    return replace(s,phases=tuple(a),tickets=tuple(b))

def events(s, policy):
    # Each of two independent producers publishes at most one task;
    # publication and waiter observation are under the same mutex.
    if s.published<2 and not s.closed:
        waiters=[i for i,x in enumerate(s.phases) if x==3]
        notify=(policy=="always" or (policy=="waiter" and bool(waiters)))
        targets=waiters if notify and waiters else [-1]
        for i in targets:
            t=replace(s,gen=s.gen+1,published=s.published+1,inbox=s.inbox+1)
            if i>=0: t=set_worker(t,i,0)
            yield f"publish_wake_{i}",t
    for i,phase in enumerate(s.phases):
        if phase==0:
            yield f"ticket_{i}",set_worker(s,i,1,s.gen)
        elif phase==1:
            if s.inbox:
                t=set_worker(s,i,4)
                yield f"claim_{i}",replace(t,inbox=s.inbox-1)
            elif s.closed and s.completed==s.published:
                yield f"exit_{i}",set_worker(s,i,5)
            else:
                yield f"search_empty_{i}",set_worker(s,i,2)
        elif phase==2:
            if s.gen!=s.tickets[i] or s.inbox or (s.closed and s.completed==s.published):
                yield f"skip_park_{i}",set_worker(s,i,0)
            else:
                yield f"wait_{i}",set_worker(s,i,3)
        elif phase==4:
            t=set_worker(s,i,0)
            t=replace(t,completed=s.completed+1)
            if t.closed and t.completed==t.published:
                # final completion changes generation, broadcasts.
                a=tuple(0 if x==3 else x for x in t.phases)
                t=replace(t,gen=t.gen+1,phases=a)
            yield f"complete_{i}",t
    if not s.closed:
        a=tuple(0 if x==3 else x for x in s.phases)
        yield "close_all",replace(s,closed=True,gen=s.gen+1,phases=a)

def explore(policy):
    queue=deque([(State(),())]); visited=set()
    stuck=None; ended=0
    while queue:
        s,trace=queue.popleft()
        if s in visited: continue
        visited.add(s)
        assert 0<=s.completed<=s.published<=2
        assert s.inbox<=s.published-s.completed
        # Strong witness: producers finished, both workers blocked, queued work.
        if s.published==2 and s.inbox>0 and s.phases==(3,3) and stuck is None:
            stuck=trace
        if s.closed and s.phases==(5,5):
            assert s.completed==s.published
            ended+=1
        for name,t in events(s,policy):
            queue.append((t,trace+(name,)))
    return len(visited),ended,stuck

def main():
    source=Path(sys.argv[1]).read_text()
    for anchor in ("const observed = _inbox.wakeGeneration();",
                   "const taken = _inbox.takeBatch(batch[]);",
                   "_inbox.parkUnlessChanged(observed);",
                   "++_generation;\n            _changed.notify();",
                   "_changed.notifyAll();"):
        assert anchor in source, "P42.2 source drift: "+anchor
    for policy in ("always","waiter","silent"):
        n,done,stuck=explore(policy)
        assert n>0 and done>0
        if policy=="silent":
            assert stuck is not None
            print("P42_2_LOST_WAKE_WITNESS", " -> ".join(stuck))
        else:
            assert stuck is None,(policy,stuck)
        print("P42_2_MODEL_PASS",policy,"states",n,"terminal",done)
    print("P42_2_LIMIT abstract 2x2, no deque/steals/fairness/OS")
if __name__=="__main__":main()
