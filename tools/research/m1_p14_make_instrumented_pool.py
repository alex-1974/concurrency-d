#!/usr/bin/env python3
"""Generate an exact-source research-only instrumented copy of the M0 pool.

No changes to source/concurrency are made. Fail closed if upstream differs:
new source must be reaudited before inserting instrumentation. Counters are
per worker with cache-line alignment and read only after successful joins.
This is event-count research, NOT a production safety or performance policy.
"""
from pathlib import Path
import argparse
import hashlib

EXPECTED_GIT_BLOB = "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a"

def replace_once(content: str, old: str, new: str) -> str:
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"P14 source changed, expected 1 anchor, found {count}: {old[:95]!r}")
    return content.replace(old, new, 1)

def generate(source: Path, destination: Path) -> None:
    raw = source.read_bytes()
    blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
    if blob != EXPECTED_GIT_BLOB:
        raise RuntimeError(f"P14 re-audit needed: M0 blob {blob} != {EXPECTED_GIT_BLOB}")
    result = raw.decode("utf-8")

    result = replace_once(result,
        "module concurrency.internal.submission_pool;",
        """module concurrency.research.m1_p14_pool;

// Added only in this opt-in generated research copy, not production.
align(64) package(concurrency) struct P14WorkerStats
{
    ulong localHits;
    ulong localMisses;
    ulong inboxBatchAttempts;
    ulong inboxBatchClaims;
    ulong inboxBatchTasks;
    ulong localPushes;
    ulong localPushFailures;
    ulong stealAttempts;
    ulong stealSuccesses;
    ulong parkAttempts;
    ulong executed;
}
package(concurrency) struct P14Trace
{
    ulong fullSubmissions;
    ulong acceptedSubmissions;
    ulong submitSignals;
    ulong localSignals;
    ulong completeCalls;
    ulong finalSignals;
    ulong closeSignals;
    ulong parkWaits;
    ulong localHits;
    ulong localMisses;
    ulong inboxBatchAttempts;
    ulong inboxBatchClaims;
    ulong inboxBatchTasks;
    ulong localPushes;
    ulong localPushFailures;
    ulong stealAttempts;
    ulong stealSuccesses;
    ulong parkAttempts;
    ulong executed;
    size_t workerCount;
    ulong[16] workerExecuted;
}
""")

    result = replace_once(result,
        "    private bool _closed;\n\n    this(size_t capacity)",
        """    private bool _closed;
    private ulong _p14Full;
    private ulong _p14Accepted;
    private ulong _p14SubmitSignals;
    private ulong _p14LocalSignals;
    private ulong _p14CompleteCalls;
    private ulong _p14FinalSignals;
    private ulong _p14CloseSignals;

    this(size_t capacity)""")
    result = replace_once(result,
        """            if (_used == _slots.length)
                return SubmissionResult.full;""",
        """            if (_used == _slots.length)
            {
                ++_p14Full;
                return SubmissionResult.full;
            }""")
    result = replace_once(result,
        """            ++_accepted;
            ++_generation;
            _changed.notify();""",
        """            ++_accepted;
            ++_p14Accepted;
            ++_generation;
            ++_p14SubmitSignals;
            _changed.notify();""")
    result = replace_once(result,
        """            assert(_completed < _accepted);
            ++_completed;""",
        """            assert(_completed < _accepted);
            ++_completed;
            ++_p14CompleteCalls;""")
    result = replace_once(result,
        """            if (_closed && _completed == _accepted)
            {
                ++_generation;
                _changed.notifyAll();
            }""",
        """            if (_closed && _completed == _accepted)
            {
                ++_generation;
                ++_p14FinalSignals;
                _changed.notifyAll();
            }""")
    result = replace_once(result,
        """            _closed = true;
            ++_generation;
            _changed.notifyAll();""",
        """            _closed = true;
            ++_generation;
            ++_p14CloseSignals;
            _changed.notifyAll();""")
    result = replace_once(result,
        """            ++_generation;
            _changed.notify();
        }
    }

    /**
     * Atomically compare""",
        """            ++_generation;
            ++_p14LocalSignals;
            _changed.notify();
        }
    }

    /**
     * Atomically compare""")
    result = replace_once(result,
        """    size_t parkCount()
    {
        synchronized (_mutex)
        {
            return _parkCount;
        }
    }

    bool isDrained()""",
        """    size_t parkCount()
    {
        synchronized (_mutex)
        {
            return _parkCount;
        }
    }

    void p14Read(ref P14Trace trace)
    {
        synchronized (_mutex)
        {
            trace.fullSubmissions = _p14Full;
            trace.acceptedSubmissions = _p14Accepted;
            trace.submitSignals = _p14SubmitSignals;
            trace.localSignals = _p14LocalSignals;
            trace.completeCalls = _p14CompleteCalls;
            trace.finalSignals = _p14FinalSignals;
            trace.closeSignals = _p14CloseSignals;
            trace.parkWaits = _parkCount;
        }
    }

    bool isDrained()""")
    result = replace_once(result,
        """    private size_t _started;

    // Optional internal completion hook.""",
        """    private size_t _started;
    private P14WorkerStats[] _p14Workers;

    // Optional internal completion hook.""")
    result = replace_once(result,
        """        _workers = new Thread[workerCount];

        try""",
        """        _workers = new Thread[workerCount];
        _p14Workers = new P14WorkerStats[workerCount];

        try""")
    result = replace_once(result,
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

    // Read only AFTER closeAndJoin succeeded (no concurrent counter writes).
    P14Trace p14Snapshot()
    {
        P14Trace trace;
        _inbox.p14Read(trace);
        trace.workerCount = _p14Workers.length;
        foreach (index, ref worker; _p14Workers)
        {
            if (index < trace.workerExecuted.length)
                trace.workerExecuted[index] = worker.executed;
            trace.localHits += worker.localHits;
            trace.localMisses += worker.localMisses;
            trace.inboxBatchAttempts += worker.inboxBatchAttempts;
            trace.inboxBatchClaims += worker.inboxBatchClaims;
            trace.inboxBatchTasks += worker.inboxBatchTasks;
            trace.localPushes += worker.localPushes;
            trace.localPushFailures += worker.localPushFailures;
            trace.stealAttempts += worker.stealAttempts;
            trace.stealSuccesses += worker.stealSuccesses;
            trace.parkAttempts += worker.parkAttempts;
            trace.executed += worker.executed;
        }
        return trace;
    }

    private void executeOne(TaskRef task, size_t self)""")
    result = replace_once(result,
        """        dispatchTask(task);
        _inbox.completeOne();""",
        """        dispatchTask(task);
        ++_p14Workers[self].executed;
        _inbox.completeOne();""")
    for old, new in (
        ("executeOne(local.value);", "executeOne(local.value, self);"),
        ("executeOne(task);", "executeOne(task, self);"),
        ("executeOne(batch[0]);", "executeOne(batch[0], self);"),
        ("executeOne(stolen.value);", "executeOne(stolen.value, self);"),
    ):
        result = replace_once(result, old, new)
    result = replace_once(result,
        """            auto local = _queues[self].pop();
            if (local.found)
            {
                executeOne(local.value, self);
                continue;
            }""",
        """            auto local = _queues[self].pop();
            if (local.found)
            {
                ++_p14Workers[self].localHits;
                executeOne(local.value, self);
                continue;
            }
            ++_p14Workers[self].localMisses;""")
    result = replace_once(result,
        """            const taken = _inbox.takeBatch(batch[]);
            if (taken != 0)
            {""",
        """            const taken = _inbox.takeBatch(batch[]);
            ++_p14Workers[self].inboxBatchAttempts;
            if (taken != 0)
            {
                ++_p14Workers[self].inboxBatchClaims;
                _p14Workers[self].inboxBatchTasks += taken;""")
    result = replace_once(result,
        """                    if (_queues[self].tryPush(task))
                    {
                        enqueued = true;
                    }
                    else
                    {
                        executeOne(task, self);
                    }""",
        """                    if (_queues[self].tryPush(task))
                    {
                        ++_p14Workers[self].localPushes;
                        enqueued = true;
                    }
                    else
                    {
                        ++_p14Workers[self].localPushFailures;
                        executeOne(task, self);
                    }""")
    result = replace_once(result,
        """                auto stolen = _queues[victim].steal();

                if (!stolen.found)
                    continue;""",
        """                ++_p14Workers[self].stealAttempts;
                auto stolen = _queues[victim].steal();

                if (!stolen.found)
                    continue;
                ++_p14Workers[self].stealSuccesses;""")
    result = replace_once(result,
        """            _inbox.parkUnlessChanged(observed);
        }
    }""",
        """            ++_p14Workers[self].parkAttempts;
            _inbox.parkUnlessChanged(observed);
        }
    }""")

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        "// AUTO-GENERATED P14 RESEARCH COPY. DO NOT EDIT BY HAND.\n"
        f"// Exact reviewed M0 source Git blob: {blob}\n"
        "// Internal behavioral source is unchanged except event counting.\n"
        + result, encoding="utf-8"
    )
    print(f"P14 generated {destination} from exact M0 Git blob {blob}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    generate(args.source, args.output)
