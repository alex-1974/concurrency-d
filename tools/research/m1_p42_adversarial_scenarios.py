#!/usr/bin/env python3
"""P42.5 scenario oracle over existing finite-state models; bounded research."""
import sys
from pathlib import Path
from m1_p42_ticket_enrollment_model import State, events
from m1_p42_local_handoff_model import S, edges

def step(state, label, policy, fn):
    candidates=[n for k,n in fn(state,policy) if k==label]
    assert len(candidates)==1, (label,state,[k for k,_ in fn(state,policy)])
    return candidates[0]

def trace_ticket(labels, policy="always"):
    s=State()
    for label in labels:
        s=step(s,label,policy,events)
    return s

def main():
    source=Path(sys.argv[1]).read_text()
    for a in ("const observed = _inbox.wakeGeneration();",
              "const taken = _inbox.takeBatch(batch[]);",
              "void announceLocalWork()", "_inbox.isDrained()",
              "_inbox.parkUnlessChanged(observed);"):
        assert a in source, "P42.5 source drift: "+a
    # P42.4 cases 1-3: ticket, external search, predicate and enrolled wait.
    before=trace_ticket(("publish_wake_-1","ticket_0","claim_0"))
    assert before.published==1 and before.phases[0]==4
    after=trace_ticket(("ticket_0","search_empty_0","publish_wake_-1",
                        "skip_park_0","ticket_0","claim_0"))
    assert after.inbox==0 and after.phases[0]==4
    sleeping=trace_ticket(("ticket_0","search_empty_0","wait_0",
                           "ticket_1","search_empty_1","wait_1",
                           "publish_wake_0","publish_wake_1"))
    assert sleeping.published==2 and sleeping.inbox==2 and sleeping.phases==(0,0)
    # P42.4 cases 4 and 5: local work becomes stealable; owner may win.
    s=S()
    for label in ("claim_batch","announce_local","steal","steal_complete",
                  "owner_complete"):
        s=step(s,label,"baseline",edges)
    assert s.completed==2 and s.local==0
    owner=S()
    for label in ("claim_batch","announce_local","owner_pop"):
        owner=step(owner,label,"baseline",edges)
    assert owner.completed==2 and owner.local==0
    # P42.4 case 6: close while worker has outstanding task; final
    # completion forces a wakeup of waiting shutdown observers.
    closed=trace_ticket(("publish_wake_-1","ticket_0","claim_0",
                         "ticket_1","search_empty_1","wait_1",
                         "close_all","complete_0"))
    assert closed.closed and closed.completed==1 and closed.phases[1]==0
    print("P42_5_SCENARIOS_PASS named_cases=6 source_pinned=true")
    print("P42_5_LIMIT abstract schedules only; bounded inbox and no real D threads")

if __name__=="__main__":main()
