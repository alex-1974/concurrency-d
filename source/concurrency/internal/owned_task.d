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
    SubmissionWorkerPool,
    WorkerParkingStats,
    InboxParkingStats,
    NotificationPolicy;

import concurrency.internal.task_record :
    TaskHeader,
    TaskRef;

version (R05TaskTrace)
    import concurrency.internal.task_trace : TaskTraceSnapshot;

version (R05WorkerSearchTrace)
    import concurrency.internal.worker_search_trace : WorkerSearchSnapshot;

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

import core.time :
    MonoTime,
    ticksToNSecs;

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

    // Only call after the previous dispatch's post-return release marker
    // became visible to the producer with acquire ordering. The previous
    // TaskHandle owns its distinct ResultCell and remains independently valid.
    void rearm(F callable, ResultCell!R cell)
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
package(concurrency) enum OwnedRecordPolicy
{
    freshGc,
    recycleTyped
}

// Opt-in research counter. Only compiled with -version=R05RecycleLookupProbe.
// The owning executor's admission mutex protects every write, and readers
// obtain a snapshot only after its workers/producers have been joined.
version (R05RecycleLookupProbe)
{
    package(concurrency) struct RecycleLookupStats
    {
        ulong searches;
        ulong emptySearches;
        ulong attemptedCasts;
        ulong hits;
        ulong misses;
        ulong hitIndexSum;
        ulong maxHitIndex;
        ulong maxCandidates;
        ulong lookupNs;
        ulong maxLookupNs;
    }
}

/**
 * Per-producer R0.5 instrumentation, exclusively owned by its calling
 * producer thread. No sharing or synchronization is needed for the sample
 * itself. Measurements include profiler clock overhead and are diagnostic.
 */
package(concurrency) struct AdmissionProbe
{
    ulong attempts;
    ulong accepted;
    ulong retentionFull;
    ulong ingressFull;
    ulong yields;
    ulong mutexWaitNs;
    ulong mutexHoldNs;
    ulong maxWaitNs;
    ulong maxHoldNs;

    version (R05AdmissionStageProbe)
    {
        // Each producer owns its AdmissionProbe. The counters below
        // are absent in ordinary DMD/LDC builds and in older probes.
        ulong gateCount;
        ulong gateNs;
        ulong cellCount;
        ulong cellNs;
        ulong nodeCount;
        ulong nodeNs;
        ulong publishCount;
        ulong publishNs;
    }

    // Fixed log2 buckets (ns): [0], [1], [2..3], [4..7], ...
    // No allocation or atomics in the measured critical section.
    ulong[64] waitBuckets;
    ulong[64] holdBuckets;

    private static size_t bucket(ulong value) @safe pure nothrow @nogc
    {
        size_t bin;
        while (value > 0 && bin < 63)
        {
            value >>= 1;
            ++bin;
        }
        return bin;
    }

    void recordWait(ulong nanoseconds) @safe nothrow @nogc
    {
        mutexWaitNs += nanoseconds;
        if (nanoseconds > maxWaitNs)
            maxWaitNs = nanoseconds;
        ++waitBuckets[bucket(nanoseconds)];
    }

    void recordHold(ulong nanoseconds) @safe nothrow @nogc
    {
        mutexHoldNs += nanoseconds;
        if (nanoseconds > maxHoldNs)
            maxHoldNs = nanoseconds;
        ++holdBuckets[bucket(nanoseconds)];
    }
}

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
    private RetainedTask[] _spare;
    private size_t _maxRetained;
    private OwnedRecordPolicy _recordPolicy;
    private size_t _freshNodes;
    private size_t _reusedNodes;
    version (R05RecycleLookupProbe)
        private RecycleLookupStats _lookupStats;

    // _mutex serializes admission against shutdown. Exactly one caller
    // performs the worker join; other closers wait for the same outcome.
    private Lifecycle _lifecycle;
    private Throwable _shutdownFailure;

    this(
        size_t workers,
        size_t ingressCapacity,
        size_t maxRetained = 4096,
        OwnedRecordPolicy policy = OwnedRecordPolicy.freshGc,
        bool parkingProfile = false,
        NotificationPolicy notificationPolicy = NotificationPolicy.always)
    {
        if (maxRetained == 0)
            throw new Exception("maxRetained must be positive");

        _pool = new SubmissionWorkerPool(
            workers, ingressCapacity, &markReturned,
            parkingProfile, notificationPolicy);
        _mutex = new Mutex();
        _lifecycleChanged = new Condition(_mutex);
        _lifecycle = Lifecycle.running;
        _maxRetained = maxRetained;
        _recordPolicy = policy;
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
        // The standard path is specialized without timers or probe writes.
        return trySubmitImpl!(F, false)(callable, null);
    }

    /** Research-only timed admission; profile belongs to this producer. */
    auto trySubmitObserved(F)(F callable, ref AdmissionProbe profile) @system
    {
        return trySubmitImpl!(F, true)(callable, &profile);
    }

    private auto trySubmitImpl(F, bool Observed)(
        F callable, AdmissionProbe* profile) @system
    {
        alias R = ReturnType!F;
        TaskHandle!R handle;

        static if (Observed)
        {
            const beforeLock = MonoTime.currTime.ticks;
            ++profile.attempts;
        }

        synchronized (_mutex)
        {
            static if (Observed)
            {
                const lockAcquired = MonoTime.currTime.ticks;
                profile.recordWait(cast(ulong) ticksToNSecs(
                    lockAcquired - beforeLock));
                scope(exit)
                {
                    const lockLeaving = MonoTime.currTime.ticks;
                    profile.recordHold(cast(ulong) ticksToNSecs(
                        lockLeaving - lockAcquired));
                }
            }

            if (_lifecycle != Lifecycle.running)
                throw new Exception("executor is closed");

            // The gate is always timed once, including allocation-free
            // capacity/retention rejections. It excludes mutex acquisition.
            version (R05AdmissionStageProbe)
                static if (Observed)
                    const gateStarted = MonoTime.currTime.ticks;
            if (_retained.length >= _maxRetained)
            {
                // O(capacity) cold path. This is intentionally deferred
                // until the fixed budget fills; no extra lock is imposed
                // on worker-local task execution.
                reapCompletedUnderLock();

                if (_retained.length >= _maxRetained)
                {
                    static if (Observed)
                        ++profile.retentionFull;
                    version (R05AdmissionStageProbe)
                    {
                        static if (Observed)
                        {
                            ++profile.gateCount;
                            profile.gateNs += cast(ulong) ticksToNSecs(
                                MonoTime.currTime.ticks - gateStarted);
                        }
                    }
                    return TaskHandle!R.init;
                }
            }

            // Admission is serialized by this executor's mutex. Since
            // workers can only remove inbox entries, a positive capacity
            // check stays valid until trySubmit below. Avoid allocating
            // the ResultCell and handle on every unsuccessful retry.
            if (!_pool.hasIngressCapacity())
            {
                static if (Observed)
                    ++profile.ingressFull;
                version (R05AdmissionStageProbe)
                {
                    static if (Observed)
                    {
                        ++profile.gateCount;
                        profile.gateNs += cast(ulong) ticksToNSecs(
                            MonoTime.currTime.ticks - gateStarted);
                    }
                }
                return TaskHandle!R.init;
            }

            version (R05AdmissionStageProbe)
            {
                static if (Observed)
                {
                    ++profile.gateCount;
                    profile.gateNs += cast(ulong) ticksToNSecs(
                        MonoTime.currTime.ticks - gateStarted);
                }
            }

            version (R05AdmissionStageProbe)
                static if (Observed)
                    const cellStarted = MonoTime.currTime.ticks;
            auto cell = new ResultCell!R();
            handle = new TaskHandle!R(cell);
            version (R05AdmissionStageProbe)
            {
                static if (Observed)
                {
                    ++profile.cellCount;
                    profile.cellNs += cast(ulong) ticksToNSecs(
                        MonoTime.currTime.ticks - cellStarted);
                }
            }

            version (R05AdmissionStageProbe)
                static if (Observed)
                    const nodeStarted = MonoTime.currTime.ticks;
            OwnedNode!(F, R) node;
            if (_recordPolicy == OwnedRecordPolicy.recycleTyped)
            {
                version (R05RecycleLookupProbe)
                {
                    const searchStarted = MonoTime.currTime.ticks;
                    ++_lookupStats.searches;
                    const candidateCount = _spare.length;
                    if (candidateCount == 0)
                        ++_lookupStats.emptySearches;
                    if (candidateCount > _lookupStats.maxCandidates)
                        _lookupStats.maxCandidates = candidateCount;
                }
                // Exact type-match is essential: a node can be rearmed only
                // for the identical concrete F/R layout. Different closure
                // shapes use independent nodes and cannot alias old handles.
                foreach (i; 0 .. _spare.length)
                {
                    version (R05RecycleLookupProbe)
                        ++_lookupStats.attemptedCasts;
                    node = cast(OwnedNode!(F, R)) _spare[i].node;
                    if (node !is null)
                    {
                        version (R05RecycleLookupProbe)
                        {
                            ++_lookupStats.hits;
                            _lookupStats.hitIndexSum += i;
                            if (i > _lookupStats.maxHitIndex)
                                _lookupStats.maxHitIndex = i;
                        }
                        _spare[i] = _spare[$ - 1];
                        _spare[$ - 1] = RetainedTask.init;
                        _spare.length = _spare.length - 1;
                        node.rearm(callable, cell);
                        ++_reusedNodes;
                        break;
                    }
                }
                version (R05RecycleLookupProbe)
                {
                    if (node is null)
                        ++_lookupStats.misses;
                    const lookupNs = cast(ulong) ticksToNSecs(
                        MonoTime.currTime.ticks - searchStarted);
                    _lookupStats.lookupNs += lookupNs;
                    if (lookupNs > _lookupStats.maxLookupNs)
                        _lookupStats.maxLookupNs = lookupNs;
                }
            }

            if (node is null)
            {
                node = new OwnedNode!(F, R)(callable, cell);
                ++_freshNodes;
            }

            version (R05AdmissionStageProbe)
            {
                static if (Observed)
                {
                    ++profile.nodeCount;
                    profile.nodeNs += cast(ulong) ticksToNSecs(
                        MonoTime.currTime.ticks - nodeStarted);
                }
            }

            // Install the strong GC root before any worker can claim the
            // record. If admission fails, clear the tail GC slot too.
            version (R05AdmissionStageProbe)
                static if (Observed)
                    const publishStarted = MonoTime.currTime.ticks;
            _retained ~= RetainedTask(node, node.returnedFlag());
            const status = _pool.trySubmit(node.reference());
            version (R05AdmissionStageProbe)
            {
                static if (Observed)
                {
                    ++profile.publishCount;
                    profile.publishNs += cast(ulong) ticksToNSecs(
                        MonoTime.currTime.ticks - publishStarted);
                }
            }

            if (status != SubmissionResult.accepted)
            {
                _retained[$ - 1] = RetainedTask.init;
                _retained.length = _retained.length - 1;

                if (_recordPolicy == OwnedRecordPolicy.recycleTyped &&
                    _spare.length < _maxRetained)
                {
                    _spare ~= RetainedTask(node, node.returnedFlag());
                }

                if (status == SubmissionResult.closed)
                    throw new Exception("executor is closed");

                assert(status == SubmissionResult.full);
                static if (Observed)
                    ++profile.ingressFull;
                return typeof(handle).init;
            }

            static if (Observed)
                ++profile.accepted;
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

            if (_recordPolicy == OwnedRecordPolicy.recycleTyped &&
                _spare.length < _maxRetained)
            {
                // Keep a strong root in the typed spare cache. The old
                // consumer handle continues to own its own result cell.
                _spare ~= _retained[i];
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

    /** Number of concrete node allocations made by the executor. */
    size_t freshNodeCount()
    {
        synchronized (_mutex)
            return _freshNodes;
    }

    /** Number of times a previously completed typed node was rearmed. */
    size_t reusedNodeCount()
    {
        synchronized (_mutex)
            return _reusedNodes;
    }

    /** Strongly retained spare nodes, distinct from in-flight records. */
    size_t spareCount()
    {
        synchronized (_mutex)
            return _spare.length;
    }

    version (R05RecycleLookupProbe)
    {
        /**
         * Research-only lookup totals, read only after the sole join.
         * Values include probe overhead and time inside the admission
         * critical section; lookupNs is NOT isolated RTTI cast latency.
         */
        RecycleLookupStats recycleLookupStatsAfterJoin()
        {
            synchronized (_mutex)
            {
                if (_lifecycle != Lifecycle.stopped)
                    throw new Exception("lookup stats require joined executor");
                return _lookupStats;
            }
        }
    }

    /**
     * R0.5 internal diagnostics, valid only AFTER closeAndJoin().
     * Worker-local counter slots are never read while workers are live.
     */
    WorkerParkingStats parkingStatsAfterJoin()
    {
        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.stopped)
                throw new Exception("worker parking stats require joined executor");
            return _pool.parkingStatsAfterJoin();
        }
    }

    /**
     * Research-only per-worker dispatch distribution. Only valid after
     * closeAndJoin(), never concurrently with worker execution.
     */
    WorkerParkingStats[] workerStatsAfterJoin()
    {
        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.stopped)
                throw new Exception("worker fairness stats require joined executor");
            return _pool.workerStatsAfterJoin();
        }
    }

    /** R0.5 inbox notification and occupancy counts after shutdown. */
    InboxParkingStats inboxParkingStatsAfterJoin()
    {
        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.stopped)
                throw new Exception("inbox parking stats require joined executor");
            return _pool.inboxParkingStatsAfterJoin();
        }
    }

    version (R05TaskTrace)
    {
        /** Research-only snapshot. Not readable during worker execution. */
        TaskTraceSnapshot taskTraceAfterJoin()
        {
            synchronized (_mutex)
            {
                if (_lifecycle != Lifecycle.stopped)
                    throw new Exception("task trace requires joined executor");
                return _pool.taskTraceAfterJoin();
            }
        }
    }

    version (R05WorkerSearchTrace)
    {
        /** Worker-owned missed-steal/park events, only after close/join. */
        WorkerSearchSnapshot workerSearchTraceAfterJoin()
        {
            synchronized (_mutex)
            {
                if (_lifecycle != Lifecycle.stopped)
                    throw new Exception("worker search trace requires joined executor");
                return _pool.workerSearchTraceAfterJoin();
            }
        }
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

    /** Instrumented semantic equivalent of submit(), research only. */
    auto submitObserved(F)(F callable, ref AdmissionProbe profile) @system
    {
        for (;;)
        {
            auto handle = trySubmitObserved(callable, profile);
            if (handle !is null)
                return handle;
            ++profile.yields;
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
                foreach (ref entry; _spare)
                    entry = RetainedTask.init;
                _spare.length = 0;
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

version (unittest)
{
    private struct WideCapturedTask
    {
        string text;
        ubyte[256] payload;
        int tag;

        int opCall()
        {
            return tag + cast(int) text.length + payload[0];
        }
    }
}

unittest
{
    // An old TaskHandle retains its original result even after its concrete
    // node has been rearmed repeatedly for new work.
    enum size_t N = 1024;
    foreach (workers; [1, 4])
    {
        auto executor = new OwnedTaskExecutor(
            workers, 3, 8, OwnedRecordPolicy.recycleTyped);

        auto first = executor.submit(&addTwo);
        assert(first.get() == 42);

        foreach (i; 0 .. N)
        {
            auto current = executor.submit(&addTwo);
            if (i % 19 == 0)
                assert(current.get() == 42);
        }

        executor.closeAndJoin();

        assert(first.get() == 42);
        assert(executor.acceptedCount() == N + 1);
        assert(executor.completedCount() == N + 1);
        assert(executor.reusedNodeCount() > 0);
        assert(executor.freshNodeCount() <= 32);
        assert(executor.retainedCount() == 0);
        assert(executor.spareCount() == 0);
    }
}

unittest
{
    // Different concrete callable layouts may occupy the same reuse cache,
    // but must never be confused or overwrite previously observed handles.
    import core.memory : GC;

    auto executor = new OwnedTaskExecutor(
        2, 2, 4, OwnedRecordPolicy.recycleTyped);

    auto original = executor.submit(&addTwo);
    assert(original.get() == 42);

    WideCapturedTask large;
    large.text = "payload-owned-by-task-record";
    large.tag = 7;
    large.payload[0] = 3;

    auto firstWide = executor.submit(large);
    const expected = firstWide.get();
    assert(expected == 7 + large.text.length + 3);

    foreach (i; 0 .. 128)
    {
        large.tag = cast(int) i;
        auto next = executor.submit(large);
        if (i % 9 == 0)
            assert(next.get() == cast(int) i + large.text.length + 3);
    }

    executor.closeAndJoin();
    GC.collect();

    assert(original.get() == 42);
    assert(firstWide.get() == expected);
    assert(executor.completedCount() == 130);
    assert(executor.reusedNodeCount() > 0);
}

unittest
{
    // Zero-spare GC policy preserves existing semantics without node reuse.
    auto executor = new OwnedTaskExecutor(
        2, 2, 4, OwnedRecordPolicy.freshGc);

    foreach (_; 0 .. 128)
    {
        auto h = executor.submit(&addTwo);
        assert(h.get() == 42);
    }

    executor.closeAndJoin();
    assert(executor.reusedNodeCount() == 0);
    assert(executor.spareCount() == 0);
    assert(executor.acceptedCount() == 128);
}

unittest
{
    // Regression: repeated full-ingress rejection must not allocate
    // throwaway ResultCells/TaskHandles/OwnedNodes on the producer thread.
    // One gated worker holds a task while the single ingress slot stays full.
    import core.atomic : MemoryOrder, atomicStore;
    import core.memory : GC;

    shared bool entered;
    shared bool release;

    GatedTask gated;
    gated.entered = &entered;
    gated.release = &release;

    foreach (policy; [OwnedRecordPolicy.freshGc,
                       OwnedRecordPolicy.recycleTyped])
    {
        atomicStore!(MemoryOrder.rel)(entered, false);
        atomicStore!(MemoryOrder.rel)(release, false);

        auto executor = new OwnedTaskExecutor(1, 1, 4, policy);
        auto running = executor.submit(gated);
        waitForFlag(&entered);

        auto waiting = executor.submit(&addTwo);
        const before = GC.allocatedInCurrentThread();

        foreach (_; 0 .. 300)
            assert(executor.trySubmit(&addTwo) is null);

        const after = GC.allocatedInCurrentThread();
        assert(after == before,
            "full-ingress rejection unexpectedly allocated GC memory");

        atomicStore!(MemoryOrder.rel)(release, true);
        assert(running.get() == 17);
        assert(waiting.get() == 42);
        executor.closeAndJoin();

        assert(executor.acceptedCount() == 2);
        assert(executor.completedCount() == 2);
    }
}
