/++
 P01 research-only scoped join kernel. Do not import as a consumer API.

 This prototype deliberately accepts borrowed records through @system. Their
 address and all captured referents are the caller's responsibility until
 closeAndJoin() returns. No detach, dynamic task allocation, or performance
 claim. The normal non-owning TaskRef/TaskHeader is reused unchanged.
+/
module concurrency.research.m1_scoped_join;

import concurrency.internal.task_record :
    TaskHeader, TaskRef, dispatchTask;
import core.atomic :
    MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import std.stdio : writeln;

private enum size_t MaxQueued = 8;
private enum size_t WorkerCount = 2;

/++
 Caller-owned, address-stable record. Never copy/move after publication.
 A result/error becoming available does not mean the worker has returned.
+/
private struct ScopedRecord
{
    TaskHeader header;
    private void delegate() @safe action;
    private Exception failure;
    private shared uint returned;
    private bool prepared;
    private bool submitted;

    static assert(header.offsetof == 0);

    void prepare(void delegate() @safe work) @system
    {
        assert(!prepared, "a record is prepared exactly once");
        assert(work !is null);
        action = work;
        header.execute = &executeRecord;
        atomicStore!(MemoryOrder.raw)(returned, 0u);
        prepared = true;
        submitted = false;
    }

    TaskRef reference() @system
    {
        assert(prepared);
        return TaskRef(cast(shared(TaskHeader)*) &header);
    }

    bool hasReturned() @system
    {
        return atomicLoad!(MemoryOrder.acq)(returned) != 0u;
    }

    Exception error() @system
    {
        assert(hasReturned());
        return failure;
    }
}

/++
 The only @trusted conversion: the header is member zero of a pinned
 ScopedRecord that was published once into this private queue. Publication
 is under the mutex; worker completion precedes join. Arbitrary user code
 does not execute inside this @trusted conversion.
+/
private ScopedRecord* recordFromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    return cast(ScopedRecord*) raw;
}

private void executeRecord(shared(TaskHeader)* raw)
    @safe nothrow
{
    auto record = recordFromHeader(raw);
    try
    {
        record.action();
    }
    catch (Exception problem)
    {
        record.failure = problem;
    }
}

private void markReturned(TaskRef task)
    @safe nothrow @nogc
{
    auto record = recordFromHeader(task.ptr);
    atomicStore!(MemoryOrder.rel)(record.returned, 1u);
}

/++
 Limited research scheduler for TaskRef publication and quiescence.
 Exactly one external controller invokes closeAndJoin(). Concurrent
 submissions are serialized with close, but producers MUST be joined by
 the caller before their borrowed record storage expires.
+/
private final class ScopeKernel
{
    private Mutex mutex;
    private Condition available;
    private TaskRef[MaxQueued] queue;
    private Thread[WorkerCount] workers;

    private size_t head;
    private size_t queued;
    private size_t accepted;
    private size_t returnedCount;
    private size_t startedCount;
    private bool closed;
    private bool joined;
    private bool cancelRequested;

    this()
    {
        mutex = new Mutex();
        available = new Condition(mutex);
    }

    void start() @system
    {
        assert(startedCount == 0);
        try
        {
            foreach (ref worker; workers)
            {
                worker = new Thread({ workerLoop(); });
                worker.start();
                ++startedCount;
            }
        }
        catch (Throwable problem)
        {
            closeAndJoin();
            throw problem;
        }
    }

    bool trySubmit(ref ScopedRecord record) @system
    {
        synchronized (mutex)
        {
            if (closed || queued == MaxQueued || record.submitted)
                return false;

            auto task = record.reference();
            record.submitted = true; // protected by this kernel's mutex
            queue[(head + queued) % MaxQueued] = task;
            ++queued;
            ++accepted;
            available.notify();
            return true;
        }
    }

    // Cancellation is a *request*. It never releases borrowed records.
    void requestCancel() @system
    {
        synchronized (mutex)
        {
            cancelRequested = true;
        }
    }

    bool cancellationRequested() @system
    {
        synchronized (mutex)
            return cancelRequested;
    }

    void closeAndJoin() @system
    {
        synchronized (mutex)
        {
            assert(!joined, "only one join owner; no concurrent joiners");
            closed = true;
            available.notifyAll();
        }

        foreach (index; 0 .. startedCount)
            workers[index].join();

        synchronized (mutex)
        {
            assert(queued == 0);
            assert(accepted == returnedCount);
            joined = true;
        }
    }

    size_t acceptedCount() @system
    {
        synchronized (mutex)
            return accepted;
    }

    size_t returnedTasks() @system
    {
        synchronized (mutex)
            return returnedCount;
    }

    private void workerLoop() @system
    {
        while (true)
        {
            TaskRef task;
            synchronized (mutex)
            {
                while (queued == 0 && !closed)
                    available.wait();

                if (queued == 0 && closed)
                    return;

                task = queue[head];
                head = (head + 1) % MaxQueued;
                --queued;
            }

            // executeRecord catches callbacks' Throwables. This transport
            // dispatch is not allowed to throw.
            dispatchTask(task);
            // Worker's last *record* access. Do not use it after this store.
            markReturned(task);

            synchronized (mutex)
                ++returnedCount;
        }
    }
}

/++ Test synchronization only; deliberately not part of the scope API.
 The tested druntime Condition methods are @system in DMD 2.111/LDC 1.41;
 test-only @trusted wrappers require their own mutex discipline. +/
private final class Gate
{
    Mutex mutex;
    Condition changed;
    size_t arrived;
    bool open;

    this()
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
    }

    void block() @trusted
    {
        synchronized (mutex)
        {
            ++arrived;
            changed.notifyAll();
            while (!open)
                changed.wait();
        }
    }

    void waitUntil(size_t count) @trusted
    {
        synchronized (mutex)
        {
            while (arrived < count)
                changed.wait();
        }
    }

    void release() @trusted
    {
        synchronized (mutex)
        {
            open = true;
            changed.notifyAll();
        }
    }
}

private void testPinnedQueueAndDrain() @system
{
    ScopeKernel kernel = new ScopeKernel();
    ScopedRecord[11] records; // caller frame, never moved after submission
    Gate gate = new Gate();
    shared uint finished;

    foreach (i; 0 .. 2)
        records[i].prepare(() @safe { gate.block(); });
    foreach (i; 2 .. records.length)
        records[i].prepare(() @safe
        {
            atomicOp!"+="(finished, 1u);
        });

    kernel.start();
    try
    {
        assert(kernel.trySubmit(records[0]));
        assert(kernel.trySubmit(records[1]));
        gate.waitUntil(2); // both workers busy
        assert(kernel.trySubmit(records[2]));
        assert(!kernel.trySubmit(records[2])); // duplicate, still free slots
        foreach (i; 3 .. 10)
            assert(kernel.trySubmit(records[i]));
        // 2 active blockers + 8 pending = 10 accepted.
        assert(!kernel.trySubmit(records[10])); // bounded inbox full
        assert(!records[10].submitted); // rejected record remains caller-owned
        foreach (i; 2 .. 10)
            assert(!records[i].hasReturned());
        gate.release();
    }
    finally
        kernel.closeAndJoin();

    assert(kernel.acceptedCount() == 10);
    assert(kernel.returnedTasks() == 10);
    foreach (i; 0 .. 10)
        assert(records[i].hasReturned());
    assert(!records[10].hasReturned());
    assert(atomicLoad!(MemoryOrder.acq)(finished) == 8u);
    assert(!kernel.trySubmit(records[10])); // closed even for never-accepted

}

// Each factory invocation creates its own closure frame for the pointer.
// Capturing a mutable loop-local slot directly is NOT equivalent and caused
// a reproducible wrong-target assertion under both pinned compilers.
private void delegate() @safe borrowedAdd(int* address) @system
{
    return () @safe { *address += 10; };
}

private void testBorrowedStackReference() @system
{
    int[3] stackValues = [3, 5, 7];
    ScopedRecord[3] records;
    ScopeKernel kernel = new ScopeKernel();

    foreach (i; 0 .. records.length)
        records[i].prepare(borrowedAdd(&stackValues[i]));

    kernel.start();
    try
    {
        foreach (ref record; records)
            assert(kernel.trySubmit(record));
    }
    finally
        kernel.closeAndJoin();

    assert(stackValues == [13, 15, 17]);
    foreach (ref record; records)
        assert(record.hasReturned());
}

private void testExceptionDrainAndCancellation() @system
{
    ScopeKernel kernel = new ScopeKernel();
    ScopedRecord[3] records;
    shared uint ran;
    records[0].prepare(() @safe { throw new Exception("child failure"); });
    records[1].prepare(() @safe
    {
        atomicStore!(MemoryOrder.rel)(ran, 1u);
    });
    records[2].prepare(() @safe
    {
        // The controller may request cancellation but this record must
        // still reach its post-dispatch return marker.
    });

    kernel.start();
    try
    {
        kernel.requestCancel();
        assert(kernel.cancellationRequested());
        foreach (ref record; records)
            assert(kernel.trySubmit(record));
        throw new Exception("caller unwind");
    }
    catch (Exception problem)
    {
        assert(problem.msg == "caller unwind");
    }
    finally
        kernel.closeAndJoin();

    assert(kernel.returnedTasks() == 3);
    assert(records[0].error() !is null);
    assert(records[1].error() is null);
    assert(records[2].error() is null);
    assert(atomicLoad!(MemoryOrder.acq)(ran) == 1u);
    foreach (ref record; records)
        assert(record.hasReturned());
}

void main()
{
    testPinnedQueueAndDrain();
    testBorrowedStackReference();
    testExceptionDrainAndCancellation();
    writeln("P01 scoped join: PASS (pinned refs, queue full/duplicate/close, ",
        "join, stack borrow, exceptions, cancellation request)");
}
