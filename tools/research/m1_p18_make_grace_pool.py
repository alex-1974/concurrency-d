#!/usr/bin/env python3
"""P18: exact-source, research-only, ONE bounded retry of idle search.

Baseline is untouched production M0. Generated candidate recaptures the
wake generation ticket, searches local/inbox/all victim queues at most once
again after Thread.yield(), then executes existing isDrained/Condition gate.

No new shared state, synchronization, atomics or production edits.
"""
import argparse
import hashlib
from pathlib import Path

ORIGINAL_M0_BLOB = "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def once(src, old, new):
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f"P18 M0 anchor changed ({count}): {old[:110]!r}")
    return src.replace(old, new, 1)

def generate(source, destination):
    raw = source.read_bytes()
    blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if blob != ORIGINAL_M0_BLOB:
        raise RuntimeError(f"P18 M0 source drift: {blob} != {ORIGINAL_M0_BLOB}")
    code = raw.decode("utf8")
    code = once(code,
        "module concurrency.internal.submission_pool;",
        """module concurrency.research.m1_p18_grace_pool;

// Fixed one-retry bounded idle grace. Not a general spin policy.
// The existing Condition-generation gate is the final authority.
private enum size_t P18MaxIdleRetries = 1;""")
    code = once(code,
        """        for (;;)
        {
            // The local-owner fast path needs no inbox mutex or wake ticket.""",
        """        // Worker-owned state, never shared between workers.
        size_t idleRetries;
        for (;;)
        {
            // The local-owner fast path needs no inbox mutex or wake ticket.""")
    code = once(code,
        """                executeOne(local.value);
                continue;""",
        """                idleRetries = 0;
                executeOne(local.value);
                continue;""")
    code = once(code,
        """                executeOne(batch[0]);
                continue;""",
        """                idleRetries = 0;
                executeOne(batch[0]);
                continue;""")
    code = once(code,
        """            if (foundWork)
                continue;

            if (_inbox.isDrained())
                break;

            // Condition.wait releases _mutex atomically. If any
            // publication/close happened since observed, this won't sleep.
            _inbox.parkUnlessChanged(observed);""",
        """            if (foundWork)
            {
                idleRetries = 0;
                continue;
            }

            if (_inbox.isDrained())
                break;

            // A bounded, at-most-one additional FULL search pass.
            // The next loop captures a FRESH generation before searching
            // local -> ingress -> every other worker. If work arrived
            // during yield/search, the original generation-gated condition
            // protocol still prevents a lost notification.
            if (idleRetries < P18MaxIdleRetries)
            {
                ++idleRetries;
                Thread.yield();
                continue;
            }

            idleRetries = 0;
            // Original M0 mutex/Condition/close/last-completion predicate,
            // called with the ticket captured before the SECOND search.
            _inbox.parkUnlessChanged(observed);""")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        "// GENERATED P18 BOUNDED IDLE GRACE RESEARCH COPY; NO PRODUCTION EDIT.\n"
        f"// Original M0 Git blob {ORIGINAL_M0_BLOB}\n" + code,
        encoding="utf8")
    print("P18 generated reviewed M0 research variant:", destination)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(args.source, args.destination)
