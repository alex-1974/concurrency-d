#!/usr/bin/env python3
"""P15: generate bounded timed-lock M0 research copy from PINNED source.

Five normal (non-Condition.wait) TaskInbox lock sites are sampled.
Every measurement adds timestamp overhead, including INSIDE the lock:
hold_ns is a perturbed observation, never the baseline lock's true cost.
The generated file is NOT production source. Fail closed on any source drift.
"""
import argparse
import hashlib
from pathlib import Path

EXPECTED = "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def gitblob(data):
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()

def only(s, before, after):
    count = s.count(before)
    if count != 1:
        raise RuntimeError(f"P15 stale source anchor ({count}): {before[:110]!r}")
    return s.replace(before, after, 1)

def measure_method(source: str, header: str, field: str) -> str:
    # Find and change only the first lock WITHIN this named method.
    begin = source.index(header)
    lock = "        synchronized (_mutex)\n        {"
    idx = source.index(lock, begin)
    if source.find("    }\n", begin) < idx:
        raise RuntimeError("P15 lock target escaped method " + header)
    replacement = (
        "        long p15Requested;\n"
        "        if (P15Enabled)\n"
        "            p15Requested = MonoTime.currTime.ticks;\n"
        + lock
        + "\n            long p15Acquired;\n"
        "            if (P15Enabled)\n"
        "                p15Acquired = MonoTime.currTime.ticks;\n"
        "            scope (exit)\n"
        "            {\n"
        "                if (P15Enabled)\n"
        f"                    p15Observe(_p15.{field}, p15Requested, p15Acquired);\n"
        "            }"
    )
    return source[:idx] + source[idx:].replace(lock, replacement, 1)

def generate(source: Path, output: Path):
    raw = source.read_bytes()
    if gitblob(raw) != EXPECTED:
        raise RuntimeError("P15 source no longer matches reviewed M0: " + gitblob(raw))
    s = raw.decode("utf-8")
    s = only(s, "module concurrency.internal.submission_pool;",
        """module concurrency.research.m1_p15_pool;

import core.time : MonoTime, ticksToNSecs;

// P15 timings are only populated with -version=P15Timed.
// Distinguish caller's mutex acquisition wait from work done WHILE locked.
// The latter includes clock reads and statistics updates in timed mode.
version (P15Timed) private enum bool P15Enabled = true;
else private enum bool P15Enabled = false;

enum size_t P15LockKinds = 5;

struct P15Duration
{
    ulong calls;
    ulong waitNs;
    ulong holdNs;
    ulong maxWaitNs;
    ulong maxHoldNs;
}
struct P15Snapshot
{
    P15Duration[P15LockKinds] entries;
}
private void p15Observe(ref P15Duration dst, long requested, long acquired)
{
    const finished = MonoTime.currTime.ticks;
    if (acquired < requested || finished < acquired)
        return; // clock monotonicity anomaly: counted separately by samples
    const waited = cast(ulong) ticksToNSecs(acquired - requested);
    const held = cast(ulong) ticksToNSecs(finished - acquired);
    ++dst.calls;
    dst.waitNs += waited;
    dst.holdNs += held;
    if (waited > dst.maxWaitNs) dst.maxWaitNs = waited;
    if (held > dst.maxHoldNs) dst.maxHoldNs = held;
}
""")
    s = only(s,
        "    private bool _closed;\n\n    this(size_t capacity)",
        "    private bool _closed;\n    private P15Snapshot _p15;\n\n    this(size_t capacity)")
    methods = [
        ("SubmissionResult trySubmit(TaskRef task)", "entries[0]"),
        ("size_t takeBatch(scope TaskRef[] output)", "entries[1]"),
        ("void completeOne()", "entries[2]"),
        ("size_t wakeGeneration()", "entries[3]"),
        ("void announceLocalWork()", "entries[4]"),
    ]
    for header, field in methods:
        s = measure_method(s, header, field)
    s = only(s,
        """    bool isDrained()
    {
        synchronized (_mutex)""",
        """    // Read only after ALL native workers have successfully joined.
    P15Snapshot p15Read()
    {
        synchronized (_mutex)
            return _p15;
    }

    bool isDrained()
    {
        synchronized (_mutex)""")
    s = only(s,
        """    /** Diagnostic only, used by race-oriented parking tests. */
    size_t parkCount()
    {
        return _inbox.parkCount();
    }""",
        """    /** Diagnostic only, used by race-oriented parking tests. */
    size_t parkCount()
    {
        return _inbox.parkCount();
    }

    P15Snapshot p15Snapshot()
    {
        return _inbox.p15Read();
    }""")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "// GENERATED P15 LOCK-TIMING RESEARCH COPY; NOT PRODUCTION.\n"
        "// M0 pinned Git blob " + EXPECTED + "\n"
        + s, encoding="utf-8")
    print("P15 generated pinned mutex timing overlay:", output)

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    generate(a.source, a.output)
