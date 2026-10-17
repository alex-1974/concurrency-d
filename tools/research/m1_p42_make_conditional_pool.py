#!/usr/bin/env python3
"""Generate matched P42 research-only observed pools from exact M0 source.

The two overlays carry identical wait/worker diagnostics. Their sole
publication policy difference is baseline unconditional notify versus
conditional notify when at least one waiter is enrolled. Neither overlay
replaces or edits the production module.
"""
from pathlib import Path
import sys


def once(s, old, new):
    if s.count(old) != 1:
        raise ValueError("P42 source anchor drift: " + old[:90])
    return s.replace(old, new, 1)


def main():
    # Two-argument invocations used by P42.9–P42.14 MUST reproduce the
    # original conditional source byte-for-byte. The P42.16 observed arms
    # are opt-in and symmetrically instrumented.
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: generator SOURCE OUTPUT [legacy|baseline|conditional]")
    arm = sys.argv[3] if len(sys.argv) == 4 else "legacy"
    if arm not in ("legacy", "baseline", "conditional"):
        raise SystemExit("unknown P42 overlay arm: " + arm)
    source, output = map(Path, sys.argv[1:3])
    s = source.read_text()

    if arm == "legacy":
        s = once(s, "module concurrency.internal.submission_pool;",
                 "module concurrency.research.m1_p42_pool;")
        s = once(s, "    private size_t _parkCount;",
                 "    private size_t _parkCount;\\n    private size_t _waiters;")
        s = once(s, """            ++_accepted;
            ++_generation;
            _changed.notify();
            return SubmissionResult.accepted;""",
                 """            ++_accepted;
            ++_generation;
            // P42.6 research hypothesis only. Waiter count is protected by
            // the same mutex as publication and the wait predicate.
            if (_waiters != 0)
                _changed.notify();
            return SubmissionResult.accepted;""")
        s = once(s, """                ++_parkCount;
                _changed.wait();""",
                 """                ++_parkCount;
                ++_waiters;
                _changed.wait();
                assert(_waiters != 0);
                --_waiters;""")
        pool_anchor = """    size_t parkCount()\\n    {\\n        return _inbox.parkCount();\\n    }"""
        s = once(s, pool_anchor, pool_anchor + """\\n\\n    // Research-only instantaneous count under the same inbox mutex.
    size_t waiterCount()
    {
        return _inbox.waiterCount();
    }""")
        inbox_anchor = """    size_t parkCount()\\n    {\\n        synchronized (_mutex)\\n        {\\n            return _parkCount;\\n        }\\n    }"""
        s = once(s, inbox_anchor, inbox_anchor + """\\n\\n    size_t waiterCount()
    {
        synchronized (_mutex)
            return _waiters;
    }""")
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("x") as handle:
            handle.write(s)
        print("P42_CONDITIONAL_POOL_GENERATED research_only=true")
        return
    s = once(s, "module concurrency.internal.submission_pool;",
             ("module concurrency.research.m1_p42_baseline_pool;" if arm == "baseline"
              else "module concurrency.research.m1_p42_pool;"))

    # The TLS identity is used only by diagnostic callbacks. It is not an
    # ownership token and is never part of a normal performance build.
    s = once(s, "private enum size_t LocalCapacity = 1024;",
             """private size_t _p42WorkerIndex = size_t.max;

size_t p42CurrentWorkerIndex() @safe nothrow @nogc
{
    return _p42WorkerIndex;
}

struct P42WaitSnapshot
{
    size_t total;
    size_t[] entries;
    bool[] enrolled;
}

private enum size_t LocalCapacity = 1024;""")

    s = once(s, "    private size_t _parkCount;",
             """    private size_t _parkCount;
    private size_t _waiters;
    private size_t[] _waitEntriesByWorker;
    private bool[] _enrolledByWorker;""")

    s = once(s, """            ++_accepted;
            ++_generation;
            _changed.notify();
            return SubmissionResult.accepted;""",
             """            ++_accepted;
            ++_generation;
            """ + ("""// P42 conditional hypothesis; guarded by the inbox mutex.
            if (_waiters != 0)
                _changed.notify();""" if arm == "conditional" else """// P42 baseline: retain unconditional publication notification.
            _changed.notify();""") + """
            return SubmissionResult.accepted;""")

    s = once(s, """                ++_parkCount;
                _changed.wait();""",
             """                ++_parkCount;
                assert(workerIndex < _enrolledByWorker.length);
                assert(!_enrolledByWorker[workerIndex]);
                ++_waiters;
                ++_waitEntriesByWorker[workerIndex];
                _enrolledByWorker[workerIndex] = true;
                _changed.wait();
                assert(_waiters != 0);
                assert(_enrolledByWorker[workerIndex]);
                _enrolledByWorker[workerIndex] = false;
                --_waiters;""")

    s = once(s, "    void parkUnlessChanged(size_t observed)",
             "    void parkUnlessChanged(size_t observed, size_t workerIndex)")
    s = once(s, "            _inbox.parkUnlessChanged(observed);",
             "            _inbox.parkUnlessChanged(observed, self);")
    s = once(s, "    private void workerLoop(size_t self)\n    {",
             "    private void workerLoop(size_t self)\n    {\n        _p42WorkerIndex = self;")

    s = once(s, "        _inbox = new TaskInbox(ingressCapacity);",
             """        _inbox = new TaskInbox(ingressCapacity);
        _inbox.configureP42Workers(workerCount);""")

    inbox_anchor = """    size_t parkCount()
    {
        synchronized (_mutex)
        {
            return _parkCount;
        }
    }"""
    s = once(s, inbox_anchor, inbox_anchor + """

    // Only called before starting worker threads.
    void configureP42Workers(size_t workers)
    {
        _waitEntriesByWorker = new size_t[workers];
        _enrolledByWorker = new bool[workers];
    }

    size_t waiterCount()
    {
        synchronized (_mutex)
            return _waiters;
    }

    // Single mutex snapshot: aggregate and individual enrollment correspond.
    P42WaitSnapshot waitSnapshot()
    {
        synchronized (_mutex)
        {
            P42WaitSnapshot snapshot;
            snapshot.total = _waiters;
            snapshot.entries = _waitEntriesByWorker.dup;
            snapshot.enrolled = _enrolledByWorker.dup;
            return snapshot;
        }
    }""")

    pool_anchor = """    size_t parkCount()
    {
        return _inbox.parkCount();
    }"""
    s = once(s, pool_anchor, pool_anchor + """

    size_t waiterCount()
    {
        return _inbox.waiterCount();
    }

    P42WaitSnapshot waitSnapshot()
    {
        return _inbox.waitSnapshot();
    }""")

    # Hard-stop if the generator is pointed at the wrong source or tries
    # to overwrite an existing file (the gate also checks this).
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as handle:
        handle.write(s)
    print("P42_OBSERVED_POOL_GENERATED arm=" + arm + " research_only=true")


if __name__ == "__main__":
    main()
