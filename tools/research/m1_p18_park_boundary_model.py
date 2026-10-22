#!/usr/bin/env python3
"""BOUNDED abstract interleaving model of the source-pinned Inbox park guard.

This does NOT model D/OS scheduling, condition blocking duration, queue memory
ordering, exact notification delivery, or a complete worker lifecycle.
In particular, the mutex is represented as one indivisible guard operation.
It tests the invariant that no stale ticket/ready work/drained state enters
Condition.wait under the actual original source-pinned guard. A deliberately
broken generation predicate MUST produce a counterexample.
"""
import argparse
import hashlib
from dataclasses import dataclass, replace
from pathlib import Path

BLOB = "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"
GUARD = """            while (_generation == observed &&
                   _used == 0 &&
                   !(_closed && _completed == _accepted))
            {
                ++_parkCount;
                _changed.wait();
            }"""
EVENTS = ("publish", "foreign_take", "finish", "announce", "local_claim", "close")


def source_gate(file):
    raw = file.read_bytes()
    digest = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if digest != BLOB:
        raise ValueError(f"M0 source drift: {digest}")
    if raw.decode("utf-8").count(GUARD) != 1:
        raise ValueError("original generation/condition guard changed")
    return digest


@dataclass(frozen=True)
class State:
    generation: int = 0
    inbox: int = 0
    accepted: int = 0
    completed: int = 0
    announced_local: int = 0
    claimed_not_announced: int = 0
    closed: bool = False


def event(st, name):
    if name == "publish":
        if st.closed or st.inbox >= 2:
            return None
        return replace(st, generation=st.generation+1, inbox=st.inbox+1,
                       accepted=st.accepted+1)
    if name == "foreign_take":
        if st.inbox == 0:
            return None
        return replace(st, inbox=st.inbox-1,
                       claimed_not_announced=st.claimed_not_announced+1)
    if name == "finish":
        # A task cannot finish before removal from the inbox.
        if st.accepted - st.completed - st.inbox <= 0:
            return None
        completed = st.completed+1
        should_broadcast = st.closed and completed == st.accepted
        return replace(st, completed=completed,
                       generation=st.generation+int(should_broadcast))
    if name == "announce":
        # Announced owner-deque work requires a previously claimed inbox
        # TaskRef: a bare notify with no owned task is NOT a valid worker step.
        if st.claimed_not_announced == 0:
            return None
        return replace(st,generation=st.generation+1,
                       claimed_not_announced=st.claimed_not_announced-1,
                       announced_local=st.announced_local+1)
    if name == "local_claim":
        if st.announced_local == 0:
            return None
        return replace(st,announced_local=st.announced_local-1)
    if name == "close":
        if st.closed:
            return None
        return replace(st,closed=True,generation=st.generation+1)
    raise AssertionError(name)


def park_guard(st, observed, mutant=False):
    return ((mutant or st.generation == observed)
            and st.inbox == 0
            and not (st.closed and st.completed == st.accepted))


def explore(second_search=False, mutant=False, max_external=3):
    steps=("ticket","search","ticket","search","guard") if second_search else (
        "ticket","search","guard")
    visited=set()
    terminated=0
    waits=0
    sleeps_with_stale_ticket=0
    witness=None

    def dfs(stage,used,st,observed,trace):
        nonlocal terminated, waits, sleeps_with_stale_ticket,witness
        key=(stage,used,st,observed)
        if key in visited:
            return
        visited.add(key)
        if stage < len(steps):
            action=steps[stage]
            if action=="ticket":
                dfs(stage+1,used,st,st.generation,trace+("capture",))
            elif action=="search":
                # A worker that observes available inbox/local work executes it
                # instead of taking the park transition in THIS bounded model.
                if st.inbox != 0 or st.announced_local != 0:
                    terminated+=1
                    return
                else:
                    dfs(stage+1,used,st,observed,trace+("empty-scan",))
            else:
                terminated+=1
                if park_guard(st,observed,mutant):
                    waits+=1
                    if st.generation!=observed or st.inbox or (
                            st.closed and st.completed==st.accepted):
                        sleeps_with_stale_ticket+=1
                        if witness is None:
                            witness=trace+("BUG:park-on-stale-state",)
                # The guard decision is terminal in this bounded model:
                # external events AFTER sleep are NOT equivalent to events
                # between search and the atomic locked guard.
                return
        if used < max_external:
            for name in EVENTS:
                new=event(st,name)
                if new is not None:
                    dfs(stage,used+1,new,observed,trace+(name,))
    dfs(0,0,State(),-1,())
    return dict(states=len(visited),terminals=terminated,
                permissible_wait_states=waits,
                stale_wait_states=sleeps_with_stale_ticket,
                counterexample=witness)


def self_test(original):
    gate=source_gate(original)
    for retry in (False,True):
        ok=explore(retry)
        if ok["stale_wait_states"]!=0 or ok["permissible_wait_states"]==0:
            raise AssertionError(f"source-pinned guard modeled incorrectly: {ok}")
        bad=explore(retry,mutant=True)
        if bad["stale_wait_states"]==0 or not bad["counterexample"]:
            raise AssertionError("negative control failed to detect deleted generation gate")
        print(f"P18_PARK_MODEL_PASS arm={'P18_second_search' if retry else 'M0'} "
              f"source={gate} states={ok['states']} "
              f"legal_park_states={ok['permissible_wait_states']} "
              f"mutated_unsafe_states={bad['stale_wait_states']} "
              f"negative_witness={'/'.join(bad['counterexample'])}")
    print("P18_PARK_MODEL_BOUND: abstract guard atomically holds mutex; "
          "NOT a proof of wakeup latency, lock fairness or real thread liveness")


if __name__ == "__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument("--source",required=True,type=Path)
    ap.add_argument("--self-test",action="store_true")
    x=ap.parse_args()
    if x.self_test:
        self_test(x.source)
    else:
        print(explore(False))
        print(explore(True))
