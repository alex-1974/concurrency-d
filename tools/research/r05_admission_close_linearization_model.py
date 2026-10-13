#!/usr/bin/env python3
"""R0.5 research: revocable admission tokens and fixed close/commit points.

Abstract bounded-state exploration, NOT a D memory model, GC proof, fairness,
real-time linearizability checker or performance benchmark. Uses EXISTENTIAL
drain reachability only. No scheduler code is modified.
"""
from collections import deque, defaultdict
from dataclasses import dataclass, replace
from itertools import product

NEW, INVOKED, RESERVED, BUILT = "new", "invoked", "reserved", "built"
REVOKED, PUBLISHED, OK = "revoked", "published", "ok"
CLOSED, FAILED, FULL = "closed", "construction_failed", "full"
TERMINAL = (OK, CLOSED, FAILED, FULL)
PENDING = (RESERVED, BUILT, REVOKED)


@dataclass(frozen=True)
class State:
    lifecycle: str
    producers: tuple
    queued: int = 0
    executing: int = 0
    rooted: int = 0
    returned: int = 0
    accepted: int = 0
    completed: int = 0
    close_returned: bool = False
    query_count: int = -1
    revoked_after_build: int = 0

    @property
    def pending(self):
        return sum(p in PENDING for p in self.producers)


def steps(s, capacity, retention, workers):
    for i, status in enumerate(s.producers):
        def change(new):
            p = list(s.producers)
            p[i] = new
            return tuple(p)

        if status == NEW:
            yield "invoke", replace(s, producers=change(INVOKED))
        elif status == INVOKED:
            if s.lifecycle == "running":
                if (s.queued + s.pending < capacity and
                        s.rooted + s.pending < retention):
                    yield "reserve", replace(s, producers=change(RESERVED))
                else:
                    yield "reject_full", replace(s, producers=change(FULL))
            else:
                yield "reject_closed", replace(s, producers=change(CLOSED))
        elif status == RESERVED:
            yield "construct", replace(s, producers=change(BUILT))
            yield "construction_error", replace(s, producers=change(FAILED))
        elif status == BUILT:
            yield "construction_error", replace(s, producers=change(FAILED))
            if s.lifecycle == "running":
                # Model's ATOMIC root-install+visible publication is an
                # explicit unproven simplification of the real D sequence.
                yield "commit", replace(
                    s, producers=change(PUBLISHED), queued=s.queued+1,
                    rooted=s.rooted+1, accepted=s.accepted+1)
        elif status == REVOKED:
            # A constructor may have been active; the owning producer must
            # acknowledge cancellation and release provisional resources.
            yield "ack_close", replace(s, producers=change(CLOSED))
        elif status == PUBLISHED:
            yield "return_handle", replace(s, producers=change(OK))
    if s.queued and s.executing < workers:
        yield "claim", replace(s, queued=s.queued-1,
                               executing=s.executing+1)
    if s.executing:
        yield "finish_post_dispatch", replace(
            s, executing=s.executing-1, completed=s.completed+1,
            returned=s.returned+1)
    if s.returned:
        yield "reclaim_after_acquire", replace(
            s, rooted=s.rooted-1, returned=s.returned-1)
    if s.lifecycle == "running":
        # Close's proposed fixed linearization: every UNCOMMITTED token
        # is revoked, even if its producer finished construction.
        p = tuple(REVOKED if x in (RESERVED, BUILT) else x
                  for x in s.producers)
        yield "close_begin", replace(
            s, lifecycle="draining", producers=p,
            revoked_after_build=s.revoked_after_build +
            sum(x == BUILT for x in s.producers))
    if (s.lifecycle == "draining" and s.pending == 0 and
            s.queued == s.executing == 0 and s.completed == s.accepted):
        # Abstract inbox-close + worker join + GC-root clearing.
        yield "close_drained", replace(s, lifecycle="stopped",
                                       rooted=0, returned=0)
    if s.lifecycle == "stopped" and not s.close_returned:
        yield "close_return", replace(s, close_returned=True)
    if s.query_count == -1:
        # acceptedCount() reads real committed inbox count, not reservations.
        yield "acceptedCount", replace(s, query_count=s.accepted)


def check(s, capacity, retention, workers):
    assert s.lifecycle in ("running", "draining", "stopped")
    assert s.queued >= 0 and 0 <= s.executing <= workers
    assert 0 <= s.returned <= s.rooted
    assert 0 <= s.completed <= s.accepted
    assert s.queued + s.pending <= capacity
    assert s.rooted + s.pending <= retention
    assert s.rooted - s.returned == s.queued + s.executing
    assert s.accepted - s.completed == s.queued + s.executing
    assert 0 <= s.revoked_after_build <= len(s.producers)
    if s.lifecycle != "running":
        assert not any(p in (RESERVED, BUILT) for p in s.producers)
    if s.lifecycle == "stopped":
        assert s.pending == s.queued == s.executing == 0
        assert s.completed == s.accepted
        assert s.rooted == s.returned == 0
    if s.close_returned:
        assert s.lifecycle == "stopped"


def explore(producers, capacity, retention, workers):
    initial = State("running", (NEW,) * producers)
    q = deque([initial])
    visited = {initial}
    back = defaultdict(set)
    seen_actions = set()
    while q:
        state = q.popleft()
        check(state, capacity, retention, workers)
        for action, nxt in steps(state, capacity, retention, workers):
            seen_actions.add(action)
            back[nxt].add(state)
            if nxt not in visited:
                visited.add(nxt)
                q.append(nxt)
    terminal = deque(s for s in visited
                     if s.close_returned and
                     all(p in TERMINAL for p in s.producers))
    may_exit = set(terminal)
    while terminal:
        for prev in back[terminal.popleft()]:
            if prev not in may_exit:
                may_exit.add(prev)
                terminal.append(prev)
    assert visited == may_exit, "abstract reservation could not drain"
    assert {"reserve", "construct", "commit", "ack_close",
            "close_begin", "acceptedCount", "return_handle"} <= seen_actions
    assert any(s.revoked_after_build for s in visited), (
        "missed allocation-before-closed-rejection semantic change")
    return len(visited), sum(map(len, back.values()))


def counterexamples():
    # Fixed LP at COMMIT fails when the close LP preceded publication.
    late = ("invoke", "reserve", "close_begin", "commit", "return_ok")
    assert late.index("close_begin") < late.index("commit")
    # Fixed LP at RESERVE is irrecoverable on construction failure, and
    # contradicts observable acceptedCount()==0 before publication.
    fail = ("invoke", "reserve", "construction_error")
    count = ("invoke", "reserve", "acceptedCount->0", "commit")
    assert fail.index("construction_error") > fail.index("reserve")
    assert count.index("reserve") < count.index("acceptedCount->0") < count.index("commit")
    # Revocable tokens eliminate LATE commit, but a built task can now be
    # rejected for close. This may violate strict no-task-allocation on
    # rejected work; preserve as explicit NO-GO without contract review.
    s = State("running", (BUILT,))
    after = dict(steps(s, 1, 1, 1))["close_begin"]
    assert after.producers == (REVOKED,)
    assert after.revoked_after_build == 1
    assert "commit" not in dict(steps(after, 1, 1, 1))
    assert "ack_close" in dict(steps(after, 1, 1, 1))


def main():
    counterexamples()
    for producers, capacity, retention, workers in product(
            (1, 2, 3), (1, 2), (1, 2), (1, 2)):
        states, edges = explore(producers, capacity, retention, workers)
        print(f"PASS P={producers} I={capacity} R={retention} "
              f"W={workers} states={states} transitions={edges}")
    print("PASS: 24 bounded configurations and 3 fixed-LP counterexamples; "
          "built-but-revoked counterexample remains")


if __name__ == "__main__":
    main()
