/++
 M1 P02: research-only lexical batch that always joins before it returns.
 Thread/capture safety deliberately remains @system at the entry point.
 No public TaskScope implementation, no borrowed callback detach.
+/
module concurrency.research.m1_lexical_batch;

import concurrency.internal.task_record :
    TaskHeader, TaskRef, dispatchTask;
import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.memory : GC;
import std.stdio : writeln;

private enum size_t Capacity = 8;
private enum size_t Workers = 2;
private alias Work = void delegate() @safe;

private struct Record
{
    @disable this(this); // compiler forbids ordinary postblit of this record
    TaskHeader header;
    Work callback;
    Exception failure;
    shared uint returned;

    static assert(header.offsetof == 0);

    void init(Work job) @system
    {
        assert(job !is null);
        callback = job;
        header.execute = &execute;
        atomicStore!(MemoryOrder.raw)(returned, 0u);
    }

    TaskRef task() @system
    {
        return TaskRef(cast(shared(TaskHeader)*) &header);
    }

    bool hasReturned() @safe nothrow @nogc
    {
        return atomicLoad!(MemoryOrder.acq)(returned) != 0u;
    }
}

// The normal copy construction route for a record that may contain a
// published TaskHeader address must stay disabled. This does not claim to
// prohibit arbitrary byte moves from @system code.
static assert(!__traits(compiles, {
    Record first;
    Record copy = first;
}), "P02 records must reject ordinary copy construction");

private Record* fromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    // Only internal pinned Record[N] elements are published.
    // Header is first; scope cannot return before every worker joins.
    return cast(Record*) raw;
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = fromHeader(raw);
    try
        record.callback();
    catch (Exception problem)
        record.failure = problem;
}

private void markReturned(TaskRef task) @safe nothrow @nogc
{
    auto record = fromHeader(task.ptr);
    atomicStore!(MemoryOrder.rel)(record.returned, 1u);
}

private final class Batch
{
    private Mutex mutex;
    private Condition ready;
    private TaskRef[Capacity] queue;
    private Thread[Workers] threads;
    private size_t next;
    private size_t pending;
    private size_t accepted;
    private size_t completed;
    private size_t started;
    private bool closing;
    private bool joined;

    this()
    {
        mutex = new Mutex();
        ready = new Condition(mutex);
    }

    void start() @system
    {
        try
        {
            foreach (ref worker; threads)
            {
                worker = new Thread({ consume(); });
                worker.start();
                ++started;
            }
        }
        catch (Throwable problem)
        {
            closeAndJoin();
            throw problem;
        }
    }

    void publish(TaskRef task) @system
    {
        synchronized (mutex)
        {
            assert(!closing && pending != Capacity);
            queue[(next + pending) % Capacity] = task;
            ++pending;
            ++accepted;
            ready.notify();
        }
    }

    void closeAndJoin() @system
    {
        assert(!joined);
        synchronized (mutex)
        {
            closing = true;
            ready.notifyAll();
        }

        foreach (index; 0 .. started)
            threads[index].join();

        synchronized (mutex)
        {
            assert(pending == 0);
            assert(accepted == completed);
            joined = true;
        }
    }

    size_t acceptedCount() @system
    {
        synchronized (mutex)
            return accepted;
    }

    size_t returnedCount() @system
    {
        synchronized (mutex)
            return completed;
    }

    private void consume() @system
    {
        while (true)
        {
            TaskRef task;
            synchronized (mutex)
            {
                while (pending == 0 && !closing)
                    ready.wait();
                if (pending == 0 && closing)
                    return;

                task = queue[next];
                next = (next + 1) % Capacity;
                --pending;
            }

            dispatchTask(task);
            markReturned(task); // last record access
            synchronized (mutex)
                ++completed;
        }
    }
}

private struct BatchResult
{
    size_t accepted;
    size_t returned;
    size_t exceptions;
}

/++
 A lexical batch: the only source of the TaskRefs is the private, pinned
 local Record[Capacity]. Every accepted record is joined in the finally
 block, including when a worker callback throws an ordinary Exception.

 Returns AFTER all worker threads have returned, so borrowed referents
 of callbacks supplied by the caller must stay alive for this call.
 @system: a scope parameter controls escape, not safe cross-thread access.
+/
private BatchResult runScopedBatch(scope Work[] callbacks) @system
{
    if (callbacks.length > Capacity)
        throw new Exception("P02 lexical batch capacity exceeded");
    BatchResult result;
    if (callbacks.length == 0)
        return result;

    Record[Capacity] records;
    foreach (i, callback; callbacks)
        records[i].init(callback);

    auto batch = new Batch();
    batch.start();
    try
    {
        foreach (i; 0 .. callbacks.length)
            batch.publish(records[i].task());
    }
    finally
        batch.closeAndJoin();

    result.accepted = batch.acceptedCount();
    result.returned = batch.returnedCount();
    foreach (i; 0 .. callbacks.length)
    {
        assert(records[i].hasReturned());
        if (records[i].failure !is null)
            ++result.exceptions;
    }
    return result;
}

private Work borrowedIncrement(shared(uint)* target) @system
{
    return () @safe { atomicOp!"+="(*target, 1u); };
}

private void testStackBorrows() @system
{
    shared uint[4] slots;
    Work[4] jobs;
    foreach (i; 0 .. jobs.length)
        jobs[i] = borrowedIncrement(&slots[i]);

    auto result = runScopedBatch(jobs[]);
    assert(result.accepted == 4 && result.returned == 4);
    assert(result.exceptions == 0);
    foreach (ref slot; slots)
        assert(atomicLoad!(MemoryOrder.acq)(slot) == 1u);
}

private void testThrownChildStillDrains() @system
{
    shared uint ran;
    Work[3] jobs;
    jobs[0] = () @safe { throw new Exception("child"); };
    jobs[1] = borrowedIncrement(&ran);
    jobs[2] = borrowedIncrement(&ran);
    auto result = runScopedBatch(jobs[]);
    assert(result.accepted == 3 && result.returned == 3);
    assert(result.exceptions == 1);
    assert(atomicLoad!(MemoryOrder.acq)(ran) == 2u);
}

private void testBatchCapacityAndEmpty() @system
{
    Work[0] none;
    auto empty = runScopedBatch(none[]);
    assert(empty.accepted == 0 && empty.returned == 0);

    shared uint executed;
    Work[Capacity + 1] tooMany;
    foreach (ref job; tooMany)
        job = borrowedIncrement(&executed);
    bool rejected;
    try
        runScopedBatch(tooMany[]);
    catch (Exception problem)
        rejected = problem.msg == "P02 lexical batch capacity exceeded";
    assert(rejected);
    assert(atomicLoad!(MemoryOrder.acq)(executed) == 0u);
}

private void testRepeatedLexicalBatches() @system
{
    // Repeated independent submissions must never observe stale TaskRefs
    // from an earlier call whose stack records already expired.
    shared uint total;
    foreach (round; 0 .. 32)
    {
        Work[Capacity] jobs;
        foreach (ref job; jobs)
            job = borrowedIncrement(&total);
        auto result = runScopedBatch(jobs[]);
        assert(result.accepted == Capacity && result.returned == Capacity);
        assert(result.exceptions == 0);
    }
    assert(atomicLoad!(MemoryOrder.acq)(total) == 32u * Capacity);
}

private void gcCollectForTest() @trusted
{
    GC.collect();
}

private final class GcWitness
{
    int value;
    this(int number) { value = number; }
}

private void testGcVisibleCapturedObject() @system
{
    auto witness = new GcWitness(83);
    shared uint seen;
    Work[1] jobs;
    jobs[0] = () @safe
    {
        gcCollectForTest();
        assert(witness.value == 83);
        atomicStore!(MemoryOrder.rel)(seen, 1u);
    };
    auto result = runScopedBatch(jobs[]);
    assert(result.accepted == 1 && result.returned == 1);
    assert(result.exceptions == 0);
    assert(atomicLoad!(MemoryOrder.acq)(seen) == 1u);
}

private struct LifetimeGuard
{
    @disable this(this);
    shared(uint)* destroyed;
    shared(uint)* workDone;
    ~this() @system
    {
        assert(atomicLoad!(MemoryOrder.acq)(*workDone) == 1u);
        atomicOp!"+="(*destroyed, 1u);
    }
}

private void testDestructorAfterJoinedWork() @system
{
    shared uint done;
    shared uint destroyed;
    {
        LifetimeGuard guard;
        guard.destroyed = &destroyed;
        guard.workDone = &done;
        Work[1] jobs = [borrowedIncrement(&done)];
        auto result = runScopedBatch(jobs[]);
        assert(result.returned == 1);
        assert(atomicLoad!(MemoryOrder.acq)(destroyed) == 0u);
    }
    assert(atomicLoad!(MemoryOrder.acq)(destroyed) == 1u);
}

void main()
{
    testStackBorrows();
    testThrownChildStillDrains();
    testBatchCapacityAndEmpty();
    testRepeatedLexicalBatches();
    testGcVisibleCapturedObject();
    testDestructorAfterJoinedWork();
    writeln("P02 lexical batch: PASS (automatic join, stack/GC borrows, ",
        "exception drain, capacity rejection, 32 cycles, destructor order)");
}
