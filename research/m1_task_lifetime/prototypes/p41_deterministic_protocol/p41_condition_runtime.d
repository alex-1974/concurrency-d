module p41_condition_runtime;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;

private final class Gate
{
    Mutex mutex;
    Condition changed;
    size_t generation;
    bool closed;
    size_t waitEntries;
    size_t returns;
    size_t workerDone;

    this()
    {
        mutex = new Mutex;
        changed = new Condition(mutex);
    }

    void close()
    {
        synchronized (mutex)
        {
            closed = true;
            ++generation;
            changed.notifyAll();
        }
    }

    void signalWithoutStateChange()
    {
        synchronized (mutex)
            changed.notifyAll();
    }

    void runWorker(size_t observed)
    {
        synchronized (mutex)
        {
            while (generation == observed && !closed)
            {
                ++waitEntries;
                changed.wait();
                ++returns;
            }
            ++workerDone;
        }
    }

    size_t ticket()
    {
        synchronized (mutex)
            return generation;
    }

    void snapshot(out size_t entries, out size_t returned, out size_t done)
    {
        synchronized (mutex)
        {
            entries = waitEntries;
            returned = returns;
            done = workerDone;
        }
    }
}

private void untilEntries(Gate gate, size_t minimum)
{
    foreach (_; 0 .. 100_000)
    {
        size_t e, r, d;
        gate.snapshot(e, r, d);
        if (e >= minimum)
            return;
        Thread.yield();
    }
    assert(false, "P41 unchanged generation failed to re-enter wait");
}

private void untilWait(Gate gate)
{
    foreach (_; 0 .. 100_000)
    {
        size_t entered, returned, done;
        gate.snapshot(entered, returned, done);
        if (entered > 0)
            return;
        Thread.yield();
    }
    assert(false, "P41 worker did not enter Condition.wait");
}

void main()
{
    // Shutdown before the generation ticket: worker bypasses the wait.
    {
        auto gate = new Gate;
        gate.close();
        auto observed = gate.ticket();
        auto worker = new Thread({ gate.runWorker(observed); });
        worker.start();
        worker.join();
        size_t e, r, d;
        gate.snapshot(e, r, d);
        assert(e == 0 && r == 0 && d == 1);
    }

    // Ticket before close: the mutex-guarded predicate rejects stale ticket.
    {
        auto gate = new Gate;
        auto observed = gate.ticket();
        gate.close();
        auto worker = new Thread({ gate.runWorker(observed); });
        worker.start();
        worker.join();
        size_t e, r, d;
        gate.snapshot(e, r, d);
        assert(e == 0 && r == 0 && d == 1);
    }

    // Closing when waiter has entered Condition.wait unblocks and joins.
    {
        auto gate = new Gate;
        auto observed = gate.ticket();
        auto worker = new Thread({ gate.runWorker(observed); });
        worker.start();
        untilWait(gate);
        gate.close();
        worker.join();
        size_t e, r, d;
        gate.snapshot(e, r, d);
        assert(e >= 1 && r == e && d == 1);
    }

    // An unchanged-state broadcast cannot satisfy the wait predicate.
    {
        auto gate = new Gate;
        auto observed = gate.ticket();
        auto worker = new Thread({ gate.runWorker(observed); });
        worker.start();
        untilWait(gate);
        gate.signalWithoutStateChange();
        // The second wait entry is observed through the same mutex as the
        // condition: the unchanged generation must cause a real re-wait.
        untilEntries(gate, 2);
        size_t beforeEntries, beforeReturns, beforeDone;
        gate.snapshot(beforeEntries, beforeReturns, beforeDone);
        assert(beforeReturns >= 1 && beforeDone == 0);
        gate.close();
        worker.join();
        size_t e, r, d;
        gate.snapshot(e, r, d);
        assert(e >= 2 && r == e && d == 1);
    }

    import std.stdio : writeln;
    writeln("P41_NATIVE_CONDITION_PASS cases=4");
    writeln("P41_NATIVE_LIMIT standalone_condition_fixture_not_production_pool");
}
