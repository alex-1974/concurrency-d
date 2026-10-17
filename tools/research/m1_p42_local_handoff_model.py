#!/usr/bin/env python3
"""P42.3 bounded local deque handoff exploration; source-pinned research only."""
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
import sys

@dataclass(frozen=True)
class S:
    inbox:int=2
    local:int=0
    working:int=0
    thief:int=1 # 1 waiting, 0 searching, 2 executing
    announced:bool=False
    completed:int=0

def edges(s,policy):
    if s.inbox==2 and not s.working:
        # Worker 0 claims a batch, executes one, places one in its deque.
        yield "claim_batch",replace(s,inbox=0,local=1,working=1)
    if s.working and not s.announced:
        # Production announceLocalWork increments generation and notify().
        wake=policy=="baseline"
        yield "announce_local",replace(s,announced=True,thief=0 if wake else s.thief)
    if s.local and s.thief==0:
        yield "steal",replace(s,local=0,thief=2)
    if s.thief==2:
        yield "steal_complete",replace(s,completed=s.completed+1,thief=0)
    if s.working and s.announced:
        # Owner drains its own deque if thief did not claim it.
        if s.local:
            yield "owner_pop",replace(s,local=0,working=0,completed=s.completed+2)
        else:
            yield "owner_complete",replace(s,working=0,completed=s.completed+1)

def check(policy):
    q=deque([(S(),())]);seen=set();bad=None;fin=0
    while q:
        s,path=q.popleft()
        if s in seen:continue
        seen.add(s)
        if s.completed==2:fin+=1
        if s.announced and s.local and s.thief==1 and bad is None:
            bad=path
        for label,n in edges(s,policy):
            assert 0<=n.completed<=2
            q.append((n,path+(label,)))
    return len(seen),fin,bad

def main():
    source=Path(sys.argv[1]).read_text()
    for anchor in ("void announceLocalWork()", "_inbox.announceLocalWork();",
                   "_queues[victim].steal();", "_queues[self].pop();"):
        assert anchor in source,("P42.3 source drift",anchor)
    for policy in ("baseline","drop_local_notify"):
        states,finished,stuck=check(policy)
        assert states and finished
        if policy=="drop_local_notify":
            assert stuck is not None
            print("P42_3_COUNTEREXAMPLE", " -> ".join(stuck))
        else:assert stuck is None
        print("P42_3_MODEL_PASS",policy,"states",states,"completed_states",finished)
    print("P42_3_LIMIT owner may eventually drain local deque; witness is delayed stealing, not global deadlock")

if __name__=="__main__":main()
