#!/usr/bin/env python3
"""R0.5 abstract reserve/construct/commit/cancel lifecycle model.

Research only. Explicit-state BFS of a possible two-phase protocol, NOT
proof for D runtime, GC, memory ordering, lock acquisition, or speed.

Assumes two independent logical budgets (inbox slots and durable
retention roots), and a controller that waits for reservations to resolve
BEFORE closing the inbox or joining workers. No scheduler code is changed.
"""
import argparse
from collections import deque, defaultdict
from dataclasses import dataclass, replace

IDLE, RESERVED, BUILT = "idle", "reserved", "built"


@dataclass(frozen=True)
class State:
    lifecycle: str = "running"
    inbox_closed: bool = False
    producers: tuple = ()
    queued: int = 0
    executing: int = 0
    roots: int = 0
    returned: int = 0
    accepted: int = 0
    completed: int = 0

    @property
    def pending(self):
        return sum(p != IDLE for p in self.producers)


def invariants(s, capacity, retention, workers, max_commits):
    assert s.lifecycle in ("running", "draining", "stopped")
    assert all(x in (IDLE, RESERVED, BUILT) for x in s.producers)
    assert 0 <= s.queued and 0 <= s.executing <= workers
    assert 0 <= s.returned <= s.roots
    assert 0 <= s.completed <= s.accepted <= max_commits
    assert s.queued + s.pending <= capacity, "lost ingress reservation"
    assert s.roots + s.pending <= retention, "lost retention reservation"
    assert s.roots - s.returned == s.queued + s.executing, "GC lifetime violation"
    assert s.accepted - s.completed == s.queued + s.executing, "lost accepted Task"
    assert s.accepted + s.pending <= max_commits
    assert not s.inbox_closed or (s.lifecycle != "running" and s.pending == 0)
    if s.lifecycle == "stopped":
        assert s.inbox_closed and s.pending == 0
        assert s.queued == s.executing == s.roots == s.returned == 0
        assert s.accepted == s.completed


def edges(s, capacity, retention, workers, max_commits):
    for i, status in enumerate(s.producers):
        if status == IDLE and s.lifecycle == "running":
            if (s.queued + s.pending < capacity and
                    s.roots + s.pending < retention and
                    s.accepted + s.pending < max_commits):
                p = list(s.producers)
                p[i] = RESERVED
                yield f"reserve[{i}]", replace(s, producers=tuple(p))
        if status == RESERVED:
            p = list(s.producers)
            p[i] = BUILT
            # Provisional producer-local root: no TaskRef visible yet.
            yield f"construct[{i}]", replace(s, producers=tuple(p))
        if status in (RESERVED, BUILT):
            p = list(s.producers)
            p[i] = IDLE
            # Exception-safe cancellation releases BOTH reservations.
            yield f"cancel[{i}]", replace(s, producers=tuple(p))
        if status == BUILT and not s.inbox_closed:
            p = list(s.producers)
            p[i] = IDLE
            # Atomic abstraction: durable root installed BEFORE
            # borrowed TaskRef visibility. Pre-drain tokens may commit.
            yield f"commit[{i}]", replace(
                s, producers=tuple(p), queued=s.queued + 1,
                roots=s.roots + 1, accepted=s.accepted + 1)
    if s.queued and s.executing < workers:
        yield "claim", replace(s, queued=s.queued - 1,
                               executing=s.executing + 1)
    if s.executing:
        yield "finish/post_return", replace(
            s, executing=s.executing - 1, completed=s.completed + 1,
            returned=s.returned + 1)
    if s.returned:
        yield "reap_after_acquire", replace(
            s, roots=s.roots - 1, returned=s.returned - 1)
    if s.lifecycle == "running":
        yield "close_begin", replace(s, lifecycle="draining")
    elif s.lifecycle == "draining":
        if not s.inbox_closed and s.pending == 0:
            yield "close_inbox", replace(s, inbox_closed=True)
        if (s.inbox_closed and s.pending == 0 and
                s.queued == s.executing == 0 and
                s.completed == s.accepted):
            yield "close_join_clear_roots", replace(
                s, lifecycle="stopped", roots=0, returned=0)


def explore(producers=2, capacity=2, retention=2, workers=2,
            max_commits=3):
    initial = State(producers=(IDLE,) * producers)
    q = deque([initial])
    prev = {initial: None}
    arcs = defaultdict(set)
    seen_actions = set()
    while q:
        state = q.popleft()
        invariants(state, capacity, retention, workers, max_commits)
        for action, child in edges(state, capacity, retention,
                                   workers, max_commits):
            seen_actions.add(action.split("[")[0])
            arcs[state].add(child)
            if child not in prev:
                prev[child] = (state, action)
                q.append(child)
    # Every reachable state has SOME route to a stopped state. This
    # is not scheduling fairness or wait-freedom in the real system.
    parents = defaultdict(set)
    for src, targets in arcs.items():
        for dst in targets:
            parents[dst].add(src)
    terminal = deque(s for s in prev if s.lifecycle == "stopped")
    can_finish = set(terminal)
    while terminal:
        target = terminal.popleft()
        for parent in parents[target]:
            if parent not in can_finish:
                can_finish.add(parent)
                terminal.append(parent)
    assert can_finish == set(prev), "a reachable state cannot eventually drain"
    assert any(s.pending and s.lifecycle == "draining" for s in prev)
    assert any(s.lifecycle == "stopped" and s.accepted > 0 for s in prev)
    assert {"reserve", "construct", "cancel", "commit", "claim",
            "finish/post_return", "close_begin", "close_inbox",
            "close_join_clear_roots", "reap_after_acquire"} <= seen_actions
    return len(prev), sum(map(len, arcs.values()))


def naive_counterexamples():
    # Two producers both snapshot one free slot, then both insert:
    # an advisory hasCapacity() without reservation is inadequate.
    inbox_capacity = 1
    independently_observed_free = 1
    published = 2 if independently_observed_free else 0
    assert published > inbox_capacity

    # Closing the inbox while a constructed token exists strands that
    # producer. The correct transition cannot close with pending>0.
    s = State(lifecycle="draining", producers=(BUILT,))
    assert s.pending and all(action != "close_inbox" for action, _ in
                             edges(s, 1, 1, 1, 1))

    # Publishing a borrowed pointer without its durable GC root is
    # forbidden by the model's root-vs-outstanding-work invariant.
    unrooted = replace(State(producers=(IDLE,)), queued=1, accepted=1)
    try:
        invariants(unrooted, 1, 1, 1, 1)
    except AssertionError:
        pass
    else:
        raise AssertionError("unrooted TaskRef was silently accepted")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--max-commits", type=int, default=3)
    args = p.parse_args()
    if not 1 <= args.max_commits <= 5:
        p.error("bounded exploration requires max-commits in 1..5")
    naive_counterexamples()
    for producers, slots, retained, workers in (
        (2, 1, 1, 1), (2, 2, 1, 1), (2, 1, 2, 1),
        (2, 2, 2, 2), (3, 2, 2, 1), (3, 2, 3, 2),
    ):
        states, transitions = explore(producers, slots, retained,
                                      workers, args.max_commits)
        print(f"PASS: producers={producers} slots={slots} "
              f"retention={retained} workers={workers} "
              f"states={states} transitions={transitions}")
    print("PASS: bounded abstract invariants and three naive counterexamples")


if __name__ == "__main__":
    main()
