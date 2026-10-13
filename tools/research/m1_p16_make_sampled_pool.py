#!/usr/bin/env python3
"""P16.1: pin exact M0 and create per-worker sampled completion-call timers.

Unlike P15, neither probe takes a timestamp inside the TaskInbox mutex,
and neither updates a shared counter. Exactly 1/64 completion calls are
sampled per worker. Null probe measures adjacent clock calls *before*
normal completion; measured probe brackets the entire completion call.
This cannot split mutex wait/hold or determine the production lock cost.
"""
import argparse
import hashlib
from pathlib import Path

EXPECTED = "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def replace_once(s, old, new):
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f"P16 source anchor changed ({n}): {old[:105]}")
    return s.replace(old, new, 1)

def generate(source, dest):
    raw = source.read_bytes()
    sha = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if sha != EXPECTED:
        raise RuntimeError(f"P16 M0 changed, manual review required: {sha}")
    s = raw.decode("utf8")
    s = replace_once(s, "module concurrency.internal.submission_pool;",
        """module concurrency.research.m1_p16_pool;

import core.time : MonoTime, ticksToNSecs;

// Fixed P16 research period. Each worker samples its own 64th completion.
enum size_t P16Period = 64;
align(64) private struct P16Worker
{
    ulong calls;
    ulong samples;
    ulong durationNs;
    ulong maxNs;
    ulong clockAnomalies;
}
struct P16Snapshot
{
    size_t workerCount;
    ulong calls;
    ulong samples;
    ulong durationNs;
    ulong maxNs;
    ulong clockAnomalies;
    ulong[16] perWorkerCalls;
    ulong[16] perWorkerSamples;
}
private void p16Account(ref P16Worker stats, long begin, long finish)
{
    ++stats.samples;
    if (finish < begin)
    {
        ++stats.clockAnomalies;
        return;
    }
    const ns = cast(ulong) ticksToNSecs(finish - begin);
    stats.durationNs += ns;
    if (ns > stats.maxNs)
        stats.maxNs = ns;
}
""")
    s = replace_once(s,
        """    private size_t _started;

    // Optional internal completion hook.""",
        """    private size_t _started;
    private P16Worker[] _p16Workers;

    // Optional internal completion hook.""")
    s = replace_once(s,
        """        _workers = new Thread[workerCount];

        try""",
        """        _workers = new Thread[workerCount];
        _p16Workers = new P16Worker[workerCount];

        try""")
    s = replace_once(s,
        """    /** Diagnostic only, used by race-oriented parking tests. */
    size_t parkCount()
    {
        return _inbox.parkCount();
    }

    private void executeOne(TaskRef task)""",
        """    /** Diagnostic only, used by race-oriented parking tests. */
    size_t parkCount()
    {
        return _inbox.parkCount();
    }

    // ONLY after all native workers have successfully joined.
    P16Snapshot p16Snapshot()
    {
        P16Snapshot snap;
        snap.workerCount = _p16Workers.length;
        foreach (i, ref stat; _p16Workers)
        {
            if (i < snap.perWorkerCalls.length)
            {
                snap.perWorkerCalls[i] = stat.calls;
                snap.perWorkerSamples[i] = stat.samples;
            }
            snap.calls += stat.calls;
            snap.samples += stat.samples;
            snap.durationNs += stat.durationNs;
            snap.clockAnomalies += stat.clockAnomalies;
            if (stat.maxNs > snap.maxNs)
                snap.maxNs = stat.maxNs;
        }
        return snap;
    }

    private void p16CompleteOne(size_t self)
    {
        auto stats = &_p16Workers[self];
        ++stats.calls;
        if ((stats.calls & (P16Period - 1)) == 0)
        {
            const before = MonoTime.currTime.ticks;
            long after;
            version (P16NullProbe)
            {
                // Same two timestamp calls, but around NO work.
                // The normal completion runs AFTER both clocks.
                after = MonoTime.currTime.ticks;
                _inbox.completeOne();
            }
            else
            {
                // Entire completion call (not just lock wait/hold).
                _inbox.completeOne();
                after = MonoTime.currTime.ticks;
            }
            p16Account(*stats, before, after);
        }
        else
        {
            _inbox.completeOne();
        }
    }

    private void executeOne(TaskRef task, size_t self)""")
    s = replace_once(s,
        """        dispatchTask(task);
        _inbox.completeOne();

        // Returning from the record's execute thunk""",
        """        dispatchTask(task);
        p16CompleteOne(self);

        // Returning from the record's execute thunk""")
    for old, new in [
        ("executeOne(local.value);", "executeOne(local.value, self);"),
        ("executeOne(task);", "executeOne(task, self);"),
        ("executeOne(batch[0]);", "executeOne(batch[0], self);"),
        ("executeOne(stolen.value);", "executeOne(stolen.value, self);"),
    ]:
        s = replace_once(s, old, new)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(
        "// GENERATED P16 sampled/null M0 research-only overlay; DO NOT EDIT.\n"
        f"// Source git blob: {EXPECTED}\n" + s, encoding="utf8")
    print("P16: source qualified, generated:", dest)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    a = parser.parse_args()
    generate(a.source, a.destination)
