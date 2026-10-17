#!/usr/bin/env python3
"""P41 deterministic event-order regression over bounded protocol model."""
from m1_p41_protocol_model import S, transitions, park_predicate

def step(state,name):
    matches=[next_state for label,next_state in transitions(state) if label==name]
    if len(matches)!=1:
        raise AssertionError(f"unavailable {name} at {state}; choices={[n for n,_ in transitions(state)]}")
    return matches[0]

def run_case(name,events,expect):
    state=S()
    for event in events:
        state=step(state,event)
    assert state.worker==3,(name,state)
    assert expect(state),(name,state)
    return state

def main():
    # A close before ticket must cause generation snapshot to bypass sleep.
    run_case("close_before_ticket",("close","capture","park-skip"),
             lambda s:s.closed and s.waits==0)
    # Race after generation ticket and before the mutex-held wait check.
    run_case("close_between_ticket_and_wait",("capture","close","park-skip"),
             lambda s:s.closed and s.waits==0)
    # Worker is sleeping: closing changes generation and allows exit.
    run_case("close_while_waiting",("capture","wait-enter","close","wait-exit"),
             lambda s:s.closed and s.waits==1)
    # Spurious return does not consume a generation ticket; predicate loops.
    run_case("spurious_then_close",("capture","wait-enter","spurious-rewait",
              "spurious-rewait","close","wait-exit"),
             lambda s:s.closed and s.waits==3 and s.spurious==2)
    # Publishing between observing and parking invalidates the ticket.
    run_case("publish_before_park",("capture","publish","park-skip"),
             lambda s:s.accepted==1 and s.waits==0)
    # A post-publish close+completion must let a parked worker leave.
    run_case("publish_after_wait",("capture","wait-enter","publish",
              "close","claim-and-complete","wait-exit"),
             lambda s:s.closed and s.completed==1 and s.accepted==1)
    print("P41_ORDERED_RACE_SCENARIOS_PASS cases=6")
    print("P41_SCENARIO_LIMIT abstract states only; no native Condition/Thread calls")

if __name__=="__main__":main()
