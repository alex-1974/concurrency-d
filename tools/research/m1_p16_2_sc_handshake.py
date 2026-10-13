#!/usr/bin/env python3
"""A bounded check of the *specific* P16.2 seq-cst close/final-wake handshake.

C  final completion atomic fetch_add
LC completion load of closedFast
S  close seq-cst closedFast store
LS close seq-cst completedAtomic load

For every total SC order respecting each thread's program order, either
close sees C (C before LS) or the completion sees S (S before LC).

This checks the narrow two-atomic ordering argument, NOT the entire M0
scheduler/GC/Condition/native join safety. Runtime adversarial tests and
full native joins remain independent qualifications.
"""
from itertools import permutations

def main():
    events = ("C", "LC", "S", "LS")
    valid = []
    for sequence in permutations(events):
        order = {x: sequence.index(x) for x in events}
        if order["C"] > order["LC"] or order["S"] > order["LS"]:
            continue
        close_sees_final = order["C"] < order["LS"]
        completion_sees_close = order["S"] < order["LC"]
        assert close_sees_final or completion_sees_close, sequence
        valid.append((sequence, close_sees_final, completion_sees_close))
    assert len(valid) == 6, f"unexpected two-thread SC schedules: {len(valid)}"
    assert any(a and not b for _, a, b in valid)
    assert any(b and not a for _, a, b in valid)
    assert any(a and b for _, a, b in valid)
    print("P16.2 seq-cst closed/final completion handshake PASS "
          "(all 6 program-order-preserving interleavings)")

if __name__ == "__main__":
    main()
