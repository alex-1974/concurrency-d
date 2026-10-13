/++
 M1 P03 — bounded dynamic lexical task-scope research, NOT a public API.

 A producer callback may submit several tasks while workers are already
 running. All TaskRefs point to pinned caller-frame records. The lexical
 driver closes and joins in a finally block, including builder exceptions.

 The builder and submission are deliberately @system: neither D scope nor
 @safe callback bodies certify transitive capture lifetime/thread safety.
 No detached tasks, worker-side spawning, parallel producers, or arbitrary
 exception/fatal-Error guarantees are established by this experiment.
+/
module concurrency.research.m1_dynamic_scope;

import concurrency.internal.task_record : TaskHeader, TaskRef, dispatchTask;
import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.memory : GC;
import std.stdio : writeln;

private enum size_t QueueCapacity = 8;
private enum size_t TaskBudget = 24;
private enum size_t WorkerCount = 2;
private alias Work = void delegate() @safe;

private struct PinnedRecord
{
    @disable this(this);

    TaskHeader header;
    Work callback;
    Exception failure;
    shared uint returned;

    static assert(header.offsetof == 0);

    void prepare(Work job) @system
    {
        assert(job !is null);
        callback = job;
        failure = null;
        header.execute = &execute;
        atomicStore!(MemoryOrder.raw)(returned, 0u);
    }

    TaskRef transport() @system
    {
        return TaskRef(cast(shared(TaskHeader)*) &header);
    }

    bool hasReturned() @safe nothrow @nogc
    {
        return atomicLoad!(MemoryOrder.acq)(returned) != 0u;
    }
}

static assert(!__traits(compiles, {
    PinnedRecord one;
    PinnedRecord two = one;
}), "ordinary record copy must remain forbidden");

private PinnedRecord* recordFromHeader(shared(TaskHeader)* header)
    @trusted nothrow @nogc
{
    // Narrow conversion only: pinned header-first record, never relocated
    // before the lexical driver joins all threads.
    return cast(PinnedRecord*) header;
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = recordFromHeader(raw);
    try
        record.callback();
    catch (Exception problem)
        record.failure = problem;
}

private void markReturned(TaskRef task) @safe nothrow @nogc
{
    auto record = recordFromHeader(task.ptr);
    atomicStore!(MemoryOrder.rel)(record.returned, 1u);
}

/++ Single external producer, two workers, synchronized bounded inbox. +/
private final class Engine
{
    private Mutex mutex;
    private Condition available;
    private Condition returnedChanged;
    private TaskRef[QueueCapacity] queue;
    private Thread[WorkerCount] workers;
    private size_t front;
    private size_t queued;
    private size_t accepted;
    private size_t returned;
    private size_t started;
    private bool closed;
    private bool joined;

    this()
    {
        mutex = new Mutex();
        available = new Condition(mutex);
        returnedChanged = new Condition(mutex);
    }

    void start() @system
    {
        try
        {
            foreach (ref worker; workers)
            {
                worker = new Thread({ workerLoop(); });
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

    bool tryPublish(TaskRef task) @system
    {
        synchronized (mutex)
        {
            if (closed || queued == QueueCapacity)
                return false;

            queue[(front + queued) % QueueCapacity] = task;
            ++queued;
            ++accepted;
            available.notify();
            return true;
        }
    }

    // Only the external producer may wait here. Calling this from a worker
    // in a saturated pool is outside the contract and can deadlock.
    void waitUntilReturned(size_t target) @system
    {
        synchronized (mutex)
        {
            assert(target <= accepted);
            while (returned < target)
                returnedChanged.wait();
        }
    }

    void closeAndJoin() @system
    {
        synchronized (mutex)
        {
            assert(!joined);
            closed = true;
            available.notifyAll();
        }

        foreach (i; 0 .. started)
            workers[i].join();

        synchronized (mutex)
        {
            assert(queued == 0);
            assert(accepted == returned);
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
            return returned;
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

                task = queue[front];
                front = (front + 1) % QueueCapacity;
                --queued;
            }

            dispatchTask(task);
            markReturned(task);
            synchronized (mutex)
            {
                ++returned;
                returnedChanged.notifyAll();
            }
        }
    }
}

private struct Outcome
{
    size_t admitted;
    size_t quiescent;
    size_t childExceptions;
    size_t rejected;
}

/++
 Producer-facing capability. It is an ordinary @system research value;
 do not claim that its pointer cannot escape via arbitrary @system code.
 No TaskRef and no direct Record address is exposed to the producer.
+/
private struct Portal
{
    @disable this(this);

    private PinnedRecord[TaskBudget] records;
    private Engine engine;
    private size_t slots;
    private size_t rejected;

    void connect(Engine e) @system
    {
        engine = e;
    }

    bool trySpawn(Work work) @system
    {
        // Rejection BEFORE preparing the next record; no published task
        // must ever be overwritten/recycled within this lexical call.
        if (work is null || slots == TaskBudget)
        {
            ++rejected;
            return false;
        }

        auto index = slots;
        records[index].prepare(work);
        if (!engine.tryPublish(records[index].transport()))
        {
            ++rejected;
            return false; // unsubmitted slot may be safely overwritten
        }

        ++slots;
        return true;
    }

    size_t acceptedCount() @system
    {
        return engine.acceptedCount();
    }

    void waitUntilReturned(size_t target) @system
    {
        engine.waitUntilReturned(target);
    }

    size_t rejectedCount() @system
    {
        return rejected;
    }

    Outcome summary() @system
    {
        Outcome result;
        result.admitted = engine.acceptedCount();
        result.quiescent = engine.returnedCount();
        result.rejected = rejected;
        assert(result.admitted == slots);
        foreach (i; 0 .. slots)
        {
            assert(records[i].hasReturned());
            if (records[i].failure !is null)
                ++result.childExceptions;
        }
        return result;
    }
}

private alias Build = void delegate(Portal*) @system;

/++
 Lexical dynamic scope. Builder executes on the controlling thread and may
 interleave submissions with worker completions. Both portal and records
 are pinned in this frame. The builder never receives a detachable TaskRef.

 Even if build throws an ordinary Exception, finally joins all admitted
 workers before local records and caller-captured referents may go away.

 @system remains essential until actual capture/escape limitations are
 enforceable against the real API.
+/
private Outcome runScoped(scope Build build) @system
{
    assert(build !is null);
    Portal portal;
    auto engine = new Engine();
    portal.connect(engine);

    engine.start();
    try
        build(&portal);
    finally
        engine.closeAndJoin();

    return portal.summary();
}

// Test-only synchronization; druntime Condition wait/notify methods are
// @system under the pinned compilers, kept in this isolated trusted helper.
private final class Gate
{
    private Mutex mutex;
    private Condition changed;
    private size_t arrived;
    private bool opened;

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
            while (!opened)
                changed.wait();
        }
    }

    void waitFor(size_t count) @trusted
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
            opened = true;
            changed.notifyAll();
        }
    }
}

private Work atomicInc(shared(uint)* ptr) @system
{
    return () @safe { atomicOp!"+="(*ptr, 1u); };
}

private void testDynamicBackpressure() @system
{
    Gate gate = new Gate();
    shared uint completed;
    auto result = runScoped((Portal* portal) @system
    {
        assert(portal.trySpawn(() @safe { gate.block(); }));
        assert(portal.trySpawn(() @safe { gate.block(); }));
        gate.waitFor(2); // two workers executing, none can drain inbox

        foreach (i; 0 .. QueueCapacity)
            assert(portal.trySpawn(atomicInc(&completed)));
        assert(!portal.trySpawn(atomicInc(&completed))); // inbox full
        assert(portal.acceptedCount() == 10);
        gate.release(); // release blocked workers before lexical return
    });

    assert(result.admitted == 10 && result.quiescent == 10);
    assert(result.rejected == 1 && result.childExceptions == 0);
    assert(atomicLoad!(MemoryOrder.acq)(completed) == QueueCapacity);
}

private void testIncrementalAdmissionAndBudget() @system
{
    shared uint completed;
    auto result = runScoped((Portal* portal) @system
    {
        foreach (batch; 0 .. TaskBudget / QueueCapacity)
        {
            foreach (i; 0 .. QueueCapacity)
                assert(portal.trySpawn(atomicInc(&completed)));
            portal.waitUntilReturned((batch + 1) * QueueCapacity);
        }
        // Queue is empty, but the 24 pinned records are all committed.
        // No address may be recycled during this lexical scope.
        assert(!portal.trySpawn(atomicInc(&completed)));
    });

    assert(result.admitted == TaskBudget);
    assert(result.quiescent == TaskBudget);
    assert(result.rejected == 1);
    assert(atomicLoad!(MemoryOrder.acq)(completed) == TaskBudget);
}

private void testThrowingBuilderJoins() @system
{
    shared uint completed;
    bool sawBuilderError;
    try
    {
        runScoped((Portal* portal) @system
        {
            assert(portal.trySpawn(atomicInc(&completed)));
            assert(portal.trySpawn(atomicInc(&completed)));
            throw new Exception("builder abort");
        });
    }
    catch (Exception error)
        sawBuilderError = error.msg == "builder abort";

    assert(sawBuilderError);
    // runScoped finally has already joined accepted jobs before rethrow.
    assert(atomicLoad!(MemoryOrder.acq)(completed) == 2u);
}

private void testChildExceptionIsolation() @system
{
    shared uint completed;
    auto result = runScoped((Portal* portal) @system
    {
        assert(portal.trySpawn(() @safe { throw new Exception("child"); }));
        assert(portal.trySpawn(atomicInc(&completed)));
    });
    assert(result.admitted == 2 && result.quiescent == 2);
    assert(result.childExceptions == 1);
    assert(atomicLoad!(MemoryOrder.acq)(completed) == 1u);
}

private void collectGcForTest() @trusted
{
    GC.collect();
}

private final class GcWitness
{
    int value;
    this(int number) { value = number; }
}

private void testGcCaptureAndDestructorOrder() @system
{
    auto witness = new GcWitness(41);
    shared uint completed;
    shared uint destroyed;

    {
        struct Guard
        {
            @disable this(this);
            shared(uint)* finished;
            shared(uint)* destructorCount;
            ~this() @system
            {
                assert(atomicLoad!(MemoryOrder.acq)(*finished) == 1u);
                atomicOp!"+="(*destructorCount, 1u);
            }
        }
        Guard guard;
        guard.finished = &completed;
        guard.destructorCount = &destroyed;

        auto outcome = runScoped((Portal* portal) @system
        {
            assert(portal.trySpawn(() @safe
            {
                collectGcForTest();
                assert(witness.value == 41);
                atomicStore!(MemoryOrder.rel)(completed, 1u);
            }));
        });
        assert(outcome.admitted == 1 && outcome.quiescent == 1);
        assert(outcome.childExceptions == 0);
        assert(atomicLoad!(MemoryOrder.acq)(destroyed) == 0u);
    }
    assert(atomicLoad!(MemoryOrder.acq)(destroyed) == 1u);
}

void main()
{
    testDynamicBackpressure();
    testIncrementalAdmissionAndBudget();
    testThrowingBuilderJoins();
    testChildExceptionIsolation();
    testGcCaptureAndDestructorOrder();
    writeln("P03 dynamic lexical scope: PASS (backpressure, 24 pinned ",
        "tasks, builder unwind, child errors, GC capture, destructor order)");
}
