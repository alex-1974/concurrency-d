/**
 * Experimental M0 owned-callable submission layer.
 *
 * Each accepted work node is strongly retained until its post-dispatch return
 * marker permits reclamation or the executor has joined. A separate typed result cell allows the caller to
 * wait before shutdown or drop the result handle entirely. This first design
 * intentionally caps retained nodes and reclaims completed records using
 * their release/acquire returned markers.
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
    TaskRef,
    TaskBatchHint;

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

import concurrency.internal.lifecycle : LifecycleFailure, lifecycleFailStop;
import concurrency.task : BatchResultCell, ResultCell, ResultNotifier,
    TaskHandle;
import concurrency.work_size : WorkSize;
import concurrency.errors : ExecutorClosedException;

import std.traits :
    ReturnType;

/**
 * Common leading record layout for the owned-executor completion callback.
 * The release flag is set after returning from dispatch, not by the user
 * callable and not merely when the result cell becomes ready.
 */
private struct CompletionPrefix
{
    TaskHeader header;
    shared uint returned;
    void function(TaskRef) nothrow afterExecution;
}

private void markReturned(TaskRef task)
    @trusted nothrow
{
    auto prefix = cast(shared(CompletionPrefix)*) task.ptr;
    const callback = (cast(CompletionPrefix*) prefix).afterExecution;
    assert(callback !is null);
    callback(task);
}

private struct RetainedTask
{
    Object node;
    shared uint* returned;
}

/**
 * Concrete node with an embedded header-first record. Inheriting the result
 * cell keeps the handle and executor-owned task record in one GC allocation;
 * only the record header address reaches the deque.
 */
private final class OwnedNode(F, R) : ResultCell!R
{
    private struct Record
    {
        CompletionPrefix prefix;
        F callable;
        ResultCell!R cell;
    }

    static assert(Record.prefix.offsetof == 0);

    private Record _record;

    this(F callable, ResultNotifier notifier, WorkSize workSize)
    {
        super(notifier);
        _record.callable = callable;
        _record.cell = this;
        _record.prefix.header.execute = &execute;
        _record.prefix.header.batchHint = workSize == WorkSize.large
            ? TaskBatchHint.oneAtATime : TaskBatchHint.normal;
        _record.prefix.afterExecution = &publishReturned;
        atomicStore!(MemoryOrder.raw)(_record.prefix.returned, 0u);
    }

    TaskRef reference()
    {
        return TaskRef(cast(shared(TaskHeader)*) &_record.prefix.header);
    }

    shared(uint)* returnedFlag()
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
                // Failure to publish the outcome must not be swallowed:
                // a handle could otherwise wait forever for an unreported task.
                lifecycleFailStop(LifecycleFailure.worker);
            }
        }
    }

    private static void publishReturned(TaskRef task)
        @trusted nothrow
    {
        // Keep the result cell in a local before the returned marker. The
        // release marker is the worker's final access to this task record.
        auto record = cast(Record*) task.ptr;
        auto cell = record.cell;
        atomicStore!(MemoryOrder.rel)(record.prefix.returned, 1u);
        cell.markReturned();
    }
}

/** Stable contiguous task records shared by one synchronous batch. */
private final class OwnedBatchStorage(F, R)
{
    private struct Record
    {
        CompletionPrefix prefix;
        F callable;
        BatchResultCell!R batch;
        size_t index;
    }

    static assert(Record.prefix.offsetof == 0);

    private Record _single;
    private Record[] _records;
    private size_t _count;

    this(scope F[] callables, BatchResultCell!R batch, WorkSize workSize)
    {
        _count = callables.length;
        if (_count == 1)
        {
            initialize(_single, callables[0], batch, 0, workSize);
        }
        else
        {
            _records = new Record[_count];
            foreach (index, ref callable; callables)
                initialize(_records[index], callable, batch, index, workSize);
        }
    }

    TaskRef reference(size_t index)
    {
        auto record = recordAt(index);
        return TaskRef(cast(shared(TaskHeader)*)
            &record.prefix.header);
    }

    shared(uint)* returnedFlag(size_t index)
    {
        return &recordAt(index).prefix.returned;
    }

    private void initialize(ref Record record, F callable,
        BatchResultCell!R batch, size_t index, WorkSize workSize)
    {
        record.callable = callable;
        record.batch = batch;
        record.index = index;
        record.prefix.header.execute = &execute;
        record.prefix.header.batchHint = workSize == WorkSize.large
            ? TaskBatchHint.oneAtATime : TaskBatchHint.normal;
        record.prefix.afterExecution = &publishReturned;
        atomicStore!(MemoryOrder.raw)(record.prefix.returned, 0u);
    }

    private Record* recordAt(size_t index)
    {
        assert(index < _count);
        return _count == 1 ? &_single : &_records[index];
    }

    private static void execute(shared(TaskHeader)* header)
        @trusted nothrow
    {
        auto record = cast(Record*) header;
        try
        {
            static if (is(R == void))
                record.callable();
            else
                record.batch.setValue(record.index, record.callable());
        }
        catch (Throwable failure)
        {
            record.batch.recordFailure(failure);
        }
    }

    private static void publishReturned(TaskRef task)
        @trusted nothrow
    {
        auto record = cast(Record*) task.ptr;
        auto batch = record.batch;
        const index = record.index;
        atomicStore!(MemoryOrder.rel)(record.prefix.returned, 1u);
        batch.completeTask();
    }
}

/**
 * Owned task prototype over SubmissionWorkerPool.
 *
 * Records are retained in a bounded executor-owned Object[] so that GC
 * cannot collect a task merely because its TaskHandle has been dropped.
 * Admission and close are serialized under the same lock. The cost of
 * retaining unreturned nodes is deliberately bounded; returned-marker
 * reclamation permits reuse of that budget before executor shutdown.
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
    private ResultNotifier _resultNotifier;
    private Mutex _mutex;
    private Condition _lifecycleChanged;
    private RetainedTask[] _retained;
    private size_t _maxRetained;
    private size_t _ingressCapacity;

    // _mutex serializes admission against shutdown. Exactly one caller
    // performs the worker join; other closers wait for the same outcome.
    private Lifecycle _lifecycle;

    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
        if (maxRetained == 0)
            throw new Exception("maxRetained must be positive");

        // Finish all owner allocations before any native worker can start.
        // A setup failure may then unwind without leaking a live idle pool.
        _mutex = new Mutex();
        _lifecycleChanged = new Condition(_mutex);
        _resultNotifier = new ResultNotifier();
        _lifecycle = Lifecycle.running;
        _maxRetained = maxRetained;
        _ingressCapacity = ingressCapacity;
        _pool = new SubmissionWorkerPool(
            workers, ingressCapacity, &markReturned);
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
    auto trySubmit(F)(F callable,
        WorkSize workSize = WorkSize.small) @system
    {
        alias R = ReturnType!F;
        TaskHandle!R handle;

        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.running)
                throw new ExecutorClosedException();

            if (_retained.length >= _maxRetained)
            {
                // O(capacity) cold path. This is intentionally deferred
                // until the fixed budget fills; no extra lock is imposed
                // on worker-local task execution.
                reapCompletedUnderLock();

                if (_retained.length >= _maxRetained)
                    return TaskHandle!R.init;
            }

            // All owned producers serialize on _mutex. Only workers can
            // remove ingress slots, so a positive capacity check remains
            // valid until publication. Backpressure needs no allocations.
            if (!_pool.hasIngressCapacity())
                return TaskHandle!R.init;

            auto node = new OwnedNode!(F, R)(callable, _resultNotifier,
                workSize);
            handle = new TaskHandle!R(node);

            // Install the strong GC root before any worker can claim the
            // record. If admission fails, clear the tail GC slot too.
            _retained ~= RetainedTask(node, node.returnedFlag());
            const status = _pool.trySubmit(node.reference());

            if (status != SubmissionResult.accepted)
            {
                _retained[$ - 1] = RetainedTask.init;
                _retained.length = _retained.length - 1;

                if (status == SubmissionResult.closed)
                    throw new ExecutorClosedException();

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

    /** Wait for scope quiescence, helping this executor when called by a worker. */
    void waitForScopeTask(R)(TaskHandle!R handle) @system
    {
        if (_pool.isCurrentWorker())
        {
            _pool.helpUntil(
                () => handle.hasReturned(),
                () => handle.waitUntilReturned());
        }
        else
            handle.waitUntilReturned();
    }

    /** Test/diagnostic observation; excludes rejected ephemeral nodes. */
    size_t retainedCount()
    {
        synchronized (_mutex)
            return _retained.length;
    }

    /** Retry while ingress or the in-flight record budget is full. */
    auto submit(F)(F callable,
        WorkSize workSize = WorkSize.small) @system
    {
        for (;;)
        {
            auto handle = trySubmit(callable, workSize);

            if (handle !is null)
                return handle;

            if (_pool.isCurrentWorker() && _pool.helpCurrentWorkerOnce())
                continue;

            Thread.yield();
        }
    }

    /** Admit a homogeneous batch atomically with one owner and inbox lock. */
    auto submitBatch(F)(scope F[] callables,
        WorkSize workSize = WorkSize.small) @system
    {
        alias R = ReturnType!F;
        if (callables.length == 0)
            return new TaskHandle!R[0];
        if (callables.length > _maxRetained ||
            callables.length > _ingressCapacity)
            throw new Exception("submitBatch exceeds executor capacity");

        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.running)
                throw new ExecutorClosedException();
        }

        auto handles = new TaskHandle!R[callables.length];
        auto refs = new TaskRef[callables.length];
        auto roots = new RetainedTask[callables.length];
        foreach (index, ref callable; callables)
        {
            auto node = new OwnedNode!(F, R)(callable, _resultNotifier,
                workSize);
            handles[index] = new TaskHandle!R(node);
            refs[index] = node.reference();
            roots[index] = RetainedTask(node, node.returnedFlag());
        }

        while (true)
        {
            bool retry;
            synchronized (_mutex)
            {
                if (_lifecycle != Lifecycle.running)
                    throw new ExecutorClosedException();

                if (_retained.length > _maxRetained - roots.length)
                {
                    reapCompletedUnderLock();
                    retry = _retained.length > _maxRetained - roots.length;
                }

                if (!retry && !_pool.hasIngressCapacity(refs.length))
                    retry = true;

                if (!retry)
                {
                    _retained ~= roots;
                    const status = _pool.trySubmitBatch(refs);
                    assert(status == SubmissionResult.accepted);
                    return handles;
                }
            }

            if (_pool.isCurrentWorker() && _pool.helpCurrentWorkerOnce())
                continue;
            Thread.yield();
        }
    }

    /** Submit a homogeneous group and collect its results as one operation. */
    auto submitBatchAndWait(F)(scope F[] callables,
        WorkSize workSize = WorkSize.small) @system
    {
        alias R = ReturnType!F;
        static if (is(R == void))
        {
            if (callables.length == 0)
                return;
        }
        else
        {
            if (callables.length == 0)
                return new R[0];
        }

        if (callables.length > _maxRetained ||
            callables.length > _ingressCapacity)
            throw new Exception("submitBatchAndWait exceeds executor capacity");

        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.running)
                throw new ExecutorClosedException();
        }

        auto batch = new BatchResultCell!R(_resultNotifier, callables.length);
        auto nodes = new OwnedBatchStorage!(F, R)(callables, batch, workSize);
        auto refs = new TaskRef[callables.length];
        auto roots = new RetainedTask[callables.length];
        foreach (index; 0 .. callables.length)
        {
            refs[index] = nodes.reference(index);
            roots[index] = RetainedTask(nodes, nodes.returnedFlag(index));
        }

        while (true)
        {
            bool retry;
            synchronized (_mutex)
            {
                if (_lifecycle != Lifecycle.running)
                    throw new ExecutorClosedException();

                if (_retained.length > _maxRetained - roots.length)
                {
                    reapCompletedUnderLock();
                    retry = _retained.length > _maxRetained - roots.length;
                }

                if (!retry && !_pool.hasIngressCapacity(refs.length))
                    retry = true;

                if (!retry)
                {
                    _retained ~= roots;
                    const status = _pool.trySubmitBatch(refs);
                    assert(status == SubmissionResult.accepted);
                    break;
                }
            }

            if (_pool.isCurrentWorker() && _pool.helpCurrentWorkerOnce())
                continue;
            Thread.yield();
        }

        if (_pool.isCurrentWorker())
        {
            while (!batch.isComplete())
            {
                if (!_pool.helpCurrentWorkerOnce())
                    Thread.yield();
            }
        }
        else
            batch.waitForCompletion();

        return batch.get();
    }

    /**
     * Idempotent, thread-safe draining shutdown for external controller
     * threads. The first caller linearizes RUNNING -> DRAINING against task
     * admission and performs the only Thread.join sequence. Other callers
     * wait for STOPPED, which is published only after successful native join.
     * Uncertain native lifetime is process-fatal, not a recoverable STOPPED.
     *
     * A task running on this executor receives WorkerSelfJoinException before
     * the lifecycle lock/state transition. Do not race destruction/GC collection
     * of this executor with active methods.
     */
    void closeAndJoin()
    {
        // Reject a worker even when another controller is already draining:
        // waiting on that controller here would deadlock its native join.
        _pool.requireExternalController();
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
                    return;

                case Lifecycle.stopped:
                    return;
            }
        }

        // Joining with _mutex held would block other controller threads
        // (and any final admission already linearized before shutdown).
        try
        {
            _pool.closeAndJoin();
        }
        catch (Throwable)
        {
            // Defensive boundary: a pool shutdown failure is not proof of
            // quiescence. Never publish stopped or allow owner-stack unwind.
            lifecycleFailStop(LifecycleFailure.owner);
        }

        synchronized (_mutex)
        {
            // Every worker has positively joined; final callbacks returned.
            foreach (ref entry; _retained)
                entry = RetainedTask.init;
            _retained.length = 0;

            _lifecycle = Lifecycle.stopped;
            _lifecycleChanged.notifyAll();
        }
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

    /** Reject scope joins initiated by a worker of this same pool. */
    void requireExternalController()
    {
        _pool.requireExternalController();
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
    // Retention capacity is a *concurrent* budget, not a lifetime counter.
    // A record must never be reclaimed while its worker is still in it.
    import core.atomic : MemoryOrder, atomicStore;
    import core.time : MonoTime, dur;

    shared bool entered;
    shared bool release;

    GatedTask gate;
    gate.entered = &entered;
    gate.release = &release;

    auto executor = new OwnedTaskExecutor(1, 1, 1);
    auto first = executor.submit(gate);
    waitForFlag(&entered);

    assert(executor.retainedCount() == 1);
    assert(executor.trySubmit(&addTwo) is null);
    assert(executor.reclaimCompleted() == 1);

    atomicStore!(MemoryOrder.rel)(release, true);
    assert(first.get() == 17);

    // Result publication happens before the post-dispatch marker: allow
    // the worker to leave the thunk before expecting a reclaimed slot.
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    TaskHandle!int second;
    while (second is null)
    {
        assert(MonoTime.currTime < deadline,
            "completed task was never made reclaimable");
        second = executor.trySubmit(&addTwo);
        if (second is null)
            Thread.yield();
    }

    assert(second.get() == 42);
    assert(executor.retainedCount() <= 1);

    executor.closeAndJoin();
    assert(executor.retainedCount() == 0);
    assert(executor.acceptedCount() == 2);
    assert(executor.completedCount() == 2);
}

unittest
{
    // Several thousand tasks can pass through a tiny bounded retention
    // budget without a permanent "capacity exhausted" state.
    enum size_t Tasks = 2048;

    foreach (workers; [1, 4])
    {
        auto executor = new OwnedTaskExecutor(workers, 3, 8);
        size_t results;

        foreach (i; 0 .. Tasks)
        {
            auto h = executor.submit(&addTwo);
            if ((i % 7) == 0)
            {
                assert(h.get() == 42);
                ++results;
            }
            // Other handles are deliberately dropped. The worker and
            // retained record still guarantee exactly one completion.
        }

        executor.closeAndJoin();

        assert(executor.acceptedCount() == Tasks);
        assert(executor.completedCount() == Tasks);
        assert(executor.retainedCount() == 0);
        assert(results > 0);

        // A handle obtained before reclamation remains independently
        // usable because it owns a separate result cell.
    }
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

unittest
{
    // A gated worker cannot consume the sole waiting ingress slot.
    // Rejected attempts must not allocate temporary result cells, handles
    // or records merely to learn that the queue is already full.
    import core.atomic : MemoryOrder, atomicStore;
    import core.memory : GC;

    shared bool entered;
    shared bool release;
    GatedTask gated;
    gated.entered = &entered;
    gated.release = &release;

    auto executor = new OwnedTaskExecutor(1, 1, 4);
    auto running = executor.submit(gated);
    waitForFlag(&entered);

    auto queued = executor.submit(&addTwo);
    const before = GC.allocatedInCurrentThread();

    foreach (_; 0 .. 300)
        assert(executor.trySubmit(&addTwo) is null);

    const after = GC.allocatedInCurrentThread();
    assert(after == before,
        "full queue rejection allocated on the producer thread");

    atomicStore!(MemoryOrder.rel)(release, true);
    assert(running.get() == 17);
    assert(queued.get() == 42);
    executor.closeAndJoin();

    assert(executor.acceptedCount() == 2);
    assert(executor.completedCount() == 2);
}
