/**
 * Experimental M0 owned-callable submission layer.
 *
 * Each accepted work node is strongly retained by the executor until the
 * executor has joined. A separate typed result cell allows the caller to
 * wait before shutdown or drop the result handle entirely. This first design
 * intentionally caps the number of retained nodes; reclamation/recycling
 * before join is a later performance/lifetime decision.
 *
 * The submission methods are @system: an arbitrary D callable may contain
 * borrowed references that are NOT safe to ship to another thread. This
 * module cannot yet validate arbitrary closure captures for @safe callers.
 */
module concurrency.internal.owned_task;

import concurrency.internal.submission_pool :
    SubmissionResult,
    SubmissionWorkerPool;

import concurrency.internal.task_record :
    TaskHeader,
    TaskRef;

import core.sync.condition :
    Condition;

import core.atomic :
    MemoryOrder,
    atomicLoad,
    atomicStore;

import core.sync.mutex :
    Mutex;

import core.thread :
    Thread;

import std.traits :
    ReturnType;

/** A single-result completion cell, independent of executor shutdown. */
private final class ResultCell(R)
{
    private Mutex _mutex;
    private Condition _changed;
    private bool _done;
    private Throwable _error;

    static if (!is(R == void))
        private R _value;

    this()
    {
        _mutex = new Mutex();
        _changed = new Condition(_mutex);
    }

    static if (is(R == void))
    {
        void succeed()
        {
            synchronized (_mutex)
            {
                assert(!_done);
                _done = true;
                _changed.notifyAll();
            }
        }
    }
    else
    {
        void succeed(R value)
        {
            synchronized (_mutex)
            {
                assert(!_done);
                _value = value;
                _done = true;
                _changed.notifyAll();
            }
        }
    }

    void fail(Throwable failure)
    {
        synchronized (_mutex)
        {
            assert(!_done);
            _error = failure;
            _done = true;
            _changed.notifyAll();
        }
    }

    bool isComplete()
    {
        synchronized (_mutex)
            return _done;
    }

    auto get()
    {
        synchronized (_mutex)
        {
            while (!_done)
                _changed.wait();

            if (_error !is null)
                throw _error;

            static if (!is(R == void))
                return _value;
        }
    }
}

/**
 * A typed result handle. Dropping it never cancels accepted work.
 * The executor owns the task record, not the TaskHandle.
 */
package(concurrency) final class TaskHandle(R)
{
    private ResultCell!R _cell;

    this(ResultCell!R cell)
    {
        _cell = cell;
    }

    bool isComplete()
    {
        return _cell.isComplete();
    }

    auto get()
    {
        return _cell.get();
    }
}

/**
 * Common leading record layout for the owned-executor completion callback.
 * The release flag is set after returning from dispatch, not by the user
 * callable and not merely when the result cell becomes ready.
 */
private struct CompletionPrefix
{
    TaskHeader header;
    shared uint returned;
}

private void markReturned(TaskRef task)
    @trusted nothrow
{
    auto prefix = cast(shared(CompletionPrefix)*) task.ptr;
    atomicStore!(MemoryOrder.rel)(prefix.returned, 1u);
}

private struct RetainedTask
{
    Object node;
    shared uint* returned;
}

/**
 * Concrete node with an embedded header-first record. The class itself
 * supplies GC retention; only the record header address reaches the deque.
 */
private final class OwnedNode(F, R)
{
    private struct Record
    {
        CompletionPrefix prefix;
        F callable;
        ResultCell!R cell;
    }

    static assert(Record.prefix.offsetof == 0);

    private Record _record;

    this(F callable, ResultCell!R cell)
    {
        _record.callable = callable;
        _record.cell = cell;
        _record.prefix.header.execute = &execute;
        atomicStore!(MemoryOrder.raw)(_record.prefix.returned, 0u);
    }

    TaskRef reference()
    {
        return TaskRef(cast(shared(TaskHeader)*) &_record.prefix.header);
    }

    shared uint* returnedFlag()
    {
        return &_record.prefix.returned;
    }

    private static void execute(shared(TaskHeader)* header)
        @trusted nothrow
    {
        // The correct F/R instantiation installs this thunk. The executor
        // claims each TaskRef once, and the owning class retains storage.
        auto record = cast(Record*) header;

        try
        {
            static if (is(R == void))
            {
                record.callable();
                record.cell.succeed();
            }
            else
            {
                record.cell.succeed(record.callable());
            }
        }
        catch (Throwable failure)
        {
            // Even an Error from user code must be observed rather than
            // escaping through the scheduler and losing completion count.
            try
            {
                record.cell.fail(failure);
            }
            catch (Throwable)
            {
                // Fatal synchronization failure is outside the ordinary
                // recoverable-exception guarantee.
            }
        }
    }
}

/**
 * Owned task prototype over SubmissionWorkerPool.
 *
 * Records are retained in a bounded executor-owned Object[] so that GC
 * cannot collect a task merely because its TaskHandle has been dropped.
 * Admission and close are serialized under the same lock. The cost of
 * retaining all accepted nodes until join is deliberate and explicitly
 * bounded; a future pool should reclaim completed nodes incrementally.
 */
package(concurrency) final class OwnedTaskExecutor
{
    private enum Lifecycle : ubyte
    {
        running,
        draining,
        stopped
    }

    private SubmissionWorkerPool _pool;
    private Mutex _mutex;
    private Condition _lifecycleChanged;
    private RetainedTask[] _retained;
    private size_t _maxRetained;

    // _mutex serializes admission against shutdown. Exactly one caller
    // performs the worker join; other closers wait for the same outcome.
    private Lifecycle _lifecycle;
    private Throwable _shutdownFailure;

    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
        if (maxRetained == 0)
            throw new Exception("maxRetained must be positive");

        _pool = new SubmissionWorkerPool(
            workers, ingressCapacity, &markReturned);
        _mutex = new Mutex();
        _lifecycleChanged = new Condition(_mutex);
        _lifecycle = Lifecycle.running;
        _maxRetained = maxRetained;
    }

    /**
     * Returns null when bounded ingress or the in-flight retention budget
     * is full. A completed record becomes reclaimable after the worker
     * returns from dispatch and records its completion; no accepted work
     * is forgotten. Throws after the executor starts draining.
     *
     * Arbitrary mutable cross-thread captures are caller responsibility.
     * Successful admission keeps both record and result cell alive until
     * all accepted tasks have completed.
     */
    auto trySubmit(F)(F callable) @system
    {
        alias R = ReturnType!F;
        auto cell = new ResultCell!R();
        auto handle = new TaskHandle!R(cell);
        auto node = new OwnedNode!(F, R)(callable, cell);

        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.running)
                throw new Exception("executor is closed");

            if (_retained.length >= _maxRetained)
            {
                // O(capacity) cold path. This is intentionally deferred
                // until the fixed budget fills; no extra lock is imposed
                // on worker-local task execution.
                reapCompletedUnderLock();

                if (_retained.length >= _maxRetained)
                    return typeof(handle).init;
            }

            // Install the strong GC root before any worker can claim the
            // record. If admission fails, clear the tail GC slot too.
            _retained ~= RetainedTask(node, node.returnedFlag());
            const status = _pool.trySubmit(node.reference());

            if (status != SubmissionResult.accepted)
            {
                _retained[$ - 1] = RetainedTask.init;
                _retained.length = _retained.length - 1;

                if (status == SubmissionResult.closed)
                    throw new Exception("executor is closed");

                assert(status == SubmissionResult.full);
                return typeof(handle).init;
            }
        }

        return handle;
    }

    /**
     * Reclaim only records whose worker has completed all record accesses.
     * Caller holds _mutex. Clearing the vacated tail is required because a
     * GC-scanned D array backing allocation can outlive its logical length.
     */
    private void reapCompletedUnderLock()
    {
        size_t i;

        while (i < _retained.length)
        {
            if (atomicLoad!(MemoryOrder.acq)(
                *_retained[i].returned) == 0u)
            {
                ++i;
                continue;
            }

            _retained[i] = _retained[$ - 1];
            _retained[$ - 1] = RetainedTask.init;
            _retained.length = _retained.length - 1;
        }
    }

    /**
     * Explicit maintenance opportunity, including idle executors that have
     * not reached the retained-record cap yet. Returns remaining roots.
     */
    size_t reclaimCompleted()
    {
        synchronized (_mutex)
        {
            reapCompletedUnderLock();
            return _retained.length;
        }
    }

    /** Test/diagnostic observation; excludes rejected ephemeral nodes. */
    size_t retainedCount()
    {
        synchronized (_mutex)
            return _retained.length;
    }

    /** Retry while ingress or the in-flight record budget is full. */
    auto submit(F)(F callable) @system
    {
        for (;;)
        {
            auto handle = trySubmit(callable);

            if (handle !is null)
                return handle;

            Thread.yield();
        }
    }

    /**
     * Idempotent, thread-safe draining shutdown for external controller
     * threads. The first caller linearizes RUNNING -> DRAINING against task
     * admission and performs the only Thread.join sequence. Other callers
     * wait for STOPPED and observe the same shutdown outcome.
     *
     * A task running on this executor must not call closeAndJoin(): joining
     * its own worker would deadlock. Do not race destruction/GC collection
     * of this executor with active methods.
     */
    void closeAndJoin()
    {
        synchronized (_mutex)
        {
            final switch (_lifecycle)
            {
                case Lifecycle.running:
                    _lifecycle = Lifecycle.draining;
                    break;

                case Lifecycle.draining:
                    while (_lifecycle != Lifecycle.stopped)
                        _lifecycleChanged.wait();

                    if (_shutdownFailure !is null)
                        throw _shutdownFailure;
                    return;

                case Lifecycle.stopped:
                    if (_shutdownFailure !is null)
                        throw _shutdownFailure;
                    return;
            }
        }

        // Joining with _mutex held would block other controller threads
        // (and any final admission already linearized before shutdown).
        Throwable failure;
        try
        {
            _pool.closeAndJoin();
        }
        catch (Throwable error)
        {
            failure = error;
        }

        synchronized (_mutex)
        {
            if (failure is null)
            {
                // All worker callbacks have returned by now. Clearing
                // these references cannot invalidate a queued record.
                foreach (ref entry; _retained)
                    entry = RetainedTask.init;
                _retained.length = 0;
            }

            _shutdownFailure = failure;
            _lifecycle = Lifecycle.stopped;
            _lifecycleChanged.notifyAll();
        }

        if (failure !is null)
            throw failure;
    }

    /** Diagnostic for lifecycle tests, not yet part of the public API. */
    bool isStopped()
    {
        synchronized (_mutex)
            return _lifecycle == Lifecycle.stopped;
    }

    /** Returns false as soon as a shutdown has claimed the join. */
    bool isAccepting()
    {
        synchronized (_mutex)
            return _lifecycle == Lifecycle.running;
    }

    size_t acceptedCount()
    {
        return _pool.acceptedCount();
    }

    size_t completedCount()
    {
        return _pool.completedCount();
    }
}

version (unittest)
{
    private int addTwo()
    {
        return 42;
    }

    private void noop()
    {
    }

    private int failTask()
    {
        throw new Exception("expected task failure");
    }

    private struct CapturedValue
    {
        int offset;

        int opCall()
        {
            return offset + 10;
        }
    }

    private struct GatedTask
    {
        shared bool* entered;
        shared bool* release;

        int opCall()
        {
            import core.atomic : MemoryOrder, atomicLoad, atomicStore;
            atomicStore!(MemoryOrder.rel)(*entered, true);

            while (!atomicLoad!(MemoryOrder.acq)(*release))
                Thread.yield();

            return 17;
        }
    }

    private void waitForFlag(shared bool* flag)
    {
        import core.atomic : MemoryOrder, atomicLoad;
        import core.time : MonoTime, dur;

        const deadline = MonoTime.currTime + dur!"seconds"(10);

        while (!atomicLoad!(MemoryOrder.acq)(*flag))
        {
            assert(MonoTime.currTime < deadline,
                "timed out waiting for worker to enter task");
            Thread.yield();
        }
    }

    private Thread makeClosingThread(
        OwnedTaskExecutor executor,
        shared uint* started)
    {
        return new Thread({
            import core.atomic : MemoryOrder, atomicFetchAdd;
            atomicFetchAdd!(MemoryOrder.rel)(*started, 1u);
            executor.closeAndJoin();
        });
    }

    private Thread makeCompetingProducer(
        OwnedTaskExecutor executor,
        shared uint* admitted)
    {
        return new Thread({
            import core.atomic : MemoryOrder, atomicFetchAdd;

            foreach (_; 0 .. 256)
            {
                try
                {
                    auto handle = executor.trySubmit(&addTwo);

                    if (handle !is null)
                        atomicFetchAdd!(MemoryOrder.rel)(*admitted, 1u);
                    else
                        Thread.yield();
                }
                catch (Exception)
                {
                    // A concurrent shutdown rejects the entire
                    // unaccepted operation; no completion is owed.
                    break;
                }
            }
        });
    }
}

unittest
{
    auto executor = new OwnedTaskExecutor(2, 4, 32);

    auto scalar = executor.submit(&addTwo);
    CapturedValue valueCallable;
    valueCallable.offset = 23;
    auto captured = executor.submit(valueCallable);
    auto empty = executor.submit(&noop);

    // Each TaskHandle waits independently, without closing the executor.
    assert(scalar.get() == 42);
    assert(captured.get() == 33);
    empty.get();

    auto failed = executor.submit(&failTask);
    bool sawFailure;

    try
    {
        failed.get();
    }
    catch (Exception error)
    {
        sawFailure = error.msg == "expected task failure";
    }

    assert(sawFailure);

    executor.closeAndJoin();
    assert(executor.acceptedCount() == 4);
    assert(executor.completedCount() == 4);
}

unittest
{
    enum size_t Count = 128;
    auto executor = new OwnedTaskExecutor(4, 2, Count);

    // Dropping the handle must not end an accepted task lifetime.
    foreach (_; 0 .. Count)
    {
        auto ignored = executor.submit(&addTwo);
    }

    executor.closeAndJoin();
    assert(executor.acceptedCount() == Count);
    assert(executor.completedCount() == Count);

    bool rejected;
    try
    {
        executor.submit(&addTwo);
    }
    catch (Exception)
    {
        rejected = true;
    }

    assert(rejected);
}

unittest
{
    // Retention capacity is explicit rather than growing without bound.
    auto executor = new OwnedTaskExecutor(1, 1, 1);
    auto first = executor.submit(&addTwo);

    bool capacityRejected;
    try
    {
        executor.submit(&addTwo);
    }
    catch (Exception error)
    {
        capacityRejected =
            error.msg == "retained task capacity exhausted";
    }

    assert(capacityRejected);
    assert(first.get() == 42);

    executor.closeAndJoin();
    assert(executor.acceptedCount() == 1);
    assert(executor.completedCount() == 1);
}

unittest
{
    // A worker is executing while two more tasks remain queued.
    // Three concurrent shutdown callers must perform one join sequence.
    import core.atomic : MemoryOrder, atomicLoad, atomicStore;
    import core.time : MonoTime, dur;

    shared bool entered;
    shared bool release;
    shared uint closerStarted;

    GatedTask gated;
    gated.entered = &entered;
    gated.release = &release;

    auto executor = new OwnedTaskExecutor(1, 3, 8);
    auto blocked = executor.submit(gated);
    waitForFlag(&entered);

    auto queuedValue = executor.submit(&addTwo);
    auto queuedError = executor.submit(&failTask);

    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = makeClosingThread(executor, &closerStarted);
        closers[i].start();
    }

    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (executor.isAccepting())
    {
        assert(MonoTime.currTime < deadline,
            "shutdown did not linearize");
        Thread.yield();
    }

    // Post-close submission must fail before claiming a completion slot.
    bool rejected;
    try
    {
        executor.trySubmit(&addTwo);
    }
    catch (Exception)
    {
        rejected = true;
    }
    assert(rejected);
    assert(!executor.isStopped());

    atomicStore!(MemoryOrder.rel)(release, true);

    foreach (thread; closers)
        thread.join();

    assert(atomicLoad!(MemoryOrder.acq)(closerStarted) == 3u);
    assert(executor.isStopped());

    // The same terminal results remain observable after shutdown.
    assert(blocked.get() == 17);
    assert(queuedValue.get() == 42);

    bool capturedError;
    try
    {
        queuedError.get();
    }
    catch (Exception error)
    {
        capturedError = error.msg == "expected task failure";
    }
    assert(capturedError);

    assert(executor.acceptedCount() == 3);
    assert(executor.completedCount() == 3);
    executor.closeAndJoin(); // repeated calls must be harmless
}

unittest
{
    // Multiple producer threads race with shutdown. Every accepted record
    // must finish exactly once; late submissions never reopen the executor.
    import core.atomic : MemoryOrder, atomicLoad;
    import core.time : MonoTime, dur;

    auto executor = new OwnedTaskExecutor(4, 8, 2048);
    shared uint admitted;

    Thread[4] producers;
    foreach (i; 0 .. producers.length)
    {
        producers[i] = makeCompetingProducer(executor, &admitted);
        producers[i].start();
    }

    // The producers are deliberately not joined before the close, so
    // admission and the RUNNING -> DRAINING transition can overlap.
    executor.closeAndJoin();

    foreach (thread; producers)
        thread.join();

    assert(executor.isStopped());
    assert(executor.acceptedCount() ==
        atomicLoad!(MemoryOrder.acq)(admitted));
    assert(executor.completedCount() == executor.acceptedCount());
}
