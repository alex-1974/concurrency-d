/**
 * Explicitly controlled CPU executor for copyable callable values and results.
 *
 * This is a version-zero API candidate. Submission is @system: the caller must
 * guarantee referent lifetimes and race-free cross-thread access. There is no
 * detach, independent-task cancellation or destructor join. Worker helping is
 * limited to scoped admission and joins; TaskHandle.get() is an ordinary wait.
 * TaskScope exposes only cooperative cancellation for its lexical children.
 */
module concurrency.executor;

private import core.atomic : atomicFetchAdd, atomicLoad, cas, MemoryOrder;
private import concurrency.internal.owned_task : OwnedTaskExecutor;
private import concurrency.taskscope : TaskScope, TaskScopeState;
private import concurrency.task : TaskHandle;
private import concurrency.work_size : WorkSize;
private import std.traits : ReturnType;

// Match the actual storage operations: default storage, copy construction and
// assignment. This is a representation constraint, not an ownership proof.
private template canStoreCopy(T)
{
    enum canStoreCopy = __traits(compiles, (ref T source) {
        T storage;
        T copy = source;
        storage = source;
    });
}

private template supportedTask(F)
{
    static if (__traits(compiles, ReturnType!F) &&
               __traits(compiles, (ref F value) { value(); }))
    {
        alias R = ReturnType!F;
        static if (is(R == void))
            enum supportedTask = canStoreCopy!F;
        else
            enum supportedTask = canStoreCopy!F && canStoreCopy!R;
    }
    else
        enum supportedTask = false;
}

private template supportedIndexTask(F)
{
    enum supportedIndexTask = canStoreCopy!F &&
        __traits(compiles, (ref F value, size_t index) { value(index); });
}

private bool canUseFetchAdd(size_t itemCount, size_t grainSize,
    size_t workerCount) @safe pure nothrow
{
    // Leave room for the last partially filled range and one terminal claim
    // from each worker, so the monotonic counter cannot wrap.
    return workerCount < size_t.max &&
        workerCount + 1 <= (size_t.max - itemCount) / grainSize;
}

private struct RangeWorker(F)
{
    F _body;
    shared size_t* _nextIndex;
    size_t _itemCount;
    size_t _grainSize;
    bool _fetchAddSafe;
    bool _guided;
    size_t _workerCount;

    this(F body, shared size_t* nextIndex, size_t itemCount, size_t grainSize,
        bool fetchAddSafe, bool guided, size_t workerCount)
    {
        _body = body;
        _nextIndex = nextIndex;
        _itemCount = itemCount;
        _grainSize = grainSize;
        _fetchAddSafe = fetchAddSafe;
        _guided = guided;
        _workerCount = workerCount;
    }

    void opCall()
    {
        while (true)
        {
            size_t first;
            size_t last;
            if (_guided)
            {
                // This counter only grants disjoint index ranges. Task
                // submission and the scope join publish callback state/results.
                first = atomicLoad!(MemoryOrder.raw)(*_nextIndex);
                while (true)
                {
                    if (first >= _itemCount)
                        return;
                    const remaining = _itemCount - first;
                    // Aim for about eight guided ranges per participant so
                    // front-loaded expensive work is split across workers.
                    const guidedSize = remaining / _workerCount / 8;
                    const claimSize = guidedSize > _grainSize
                        ? guidedSize : _grainSize;
                    last = first + (remaining < claimSize ? remaining : claimSize);
                    if (cas!(MemoryOrder.raw, MemoryOrder.raw)(
                        _nextIndex, first, last))
                        break;
                    first = atomicLoad!(MemoryOrder.raw)(*_nextIndex);
                }
            }
            else if (_fetchAddSafe)
            {
                first = atomicFetchAdd!(MemoryOrder.raw)(*_nextIndex, _grainSize);
                if (first >= _itemCount)
                    return;
            }
            else
            {
                first = atomicLoad!(MemoryOrder.acq)(*_nextIndex);
                while (true)
                {
                    if (first >= _itemCount)
                        return;
                    const remaining = _itemCount - first;
                    last = first + (remaining < _grainSize ? remaining : _grainSize);
                    if (cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(
                        _nextIndex, first, last))
                        break;
                    first = atomicLoad!(MemoryOrder.acq)(*_nextIndex);
                }
            }
            if (_fetchAddSafe && !_guided)
            {
                const remaining = _itemCount - first;
                last = first + (remaining < _grainSize ? remaining : _grainSize);
            }
            runRange(first, last);
        }
    }

    private void runRange(size_t first, size_t last)
    {
        foreach (index; first .. last)
            _body(index);
    }
}

/**
 * Results from Executor.join. Fields for void-returning callables are omitted.
 */
struct JoinResult(L, R)
{
    static if (!is(L == void)) L left;
    static if (!is(R == void)) R right;
}

/**
 * CPU executor with bounded ingress and retained-record capacity.
 *
 * Safely publish the executor to producer threads; keep it explicitly rooted
 * until closeAndJoin succeeds. Multiple external producers and close callers
 * are supported. No finalizer or destructor silently joins on the caller's
 * behalf. Scoped joins may help execute work on this executor from a worker;
 * a TaskHandle.get() wait does not. User callbacks, copies and destructors
 * must not invalidate published storage or reenter executor operations under
 * their admission lock.
 *
 * Native start/join uncertainty and escaped scheduler failures are process-fatal
 * (abort). This preserves the internal lifecycle boundary; it does not provide
 * recoverable OS thread failure handling or availability under runtime damage.
 */
final class Executor
{
    private OwnedTaskExecutor _impl;
    private size_t _workerCount;

    /**
     * All limits must be positive. workers is explicit (no guessed default).
     * ingressCapacity bounds waiting inbox entries; maxRetained bounds task
     * records still retained by the executor, not bytes or total heap usage.
     * Owner setup completes before any native worker starts.
     */
    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
        _workerCount = workers;
        _impl = new OwnedTaskExecutor(workers, ingressCapacity, maxRetained);
    }

    /**
     * Try one admission. Returns a typed handle, or null when ingress or the
     * retained-record budget is exhausted. Closed submission throws
     * ExecutorClosedException. Rejection creates no execution obligation.
     *
     * F must be invocable without arguments. F and a non-void result must
     * support the storage/copy operations used by the implementation. Arbitrary
     * captured pointers and mutable state remain the caller's responsibility.
     * auto ref avoids an extra facade-level callable copy; storage still copies.
     * workSize defaults to the small-task inbox batching policy. Passing large
     * asks workers to leave following ingress entries available for other
     * workers; it does not split or preempt this callable.
     */
    auto trySubmit(F)(auto ref F callable,
        WorkSize workSize = WorkSize.small) @system
        if (supportedTask!F)
    {
        return _impl.trySubmit(callable, workSize);
    }

    /**
     * Retry capacity rejection until admitted or closed. May wait indefinitely
     * if retained/inbox capacity is held by work that cannot make progress.
     * When a worker retries admission, it runs available same-pool work to
     * make capacity progress. No fairness or timeout is promised; blocked
     * callbacks or a retained budget too small for active parents can exhaust it.
     * workSize defaults to small and may be set to large for an estimated
     * long-running callable.
     */
    auto submit(F)(auto ref F callable,
        WorkSize workSize = WorkSize.small) @system
        if (supportedTask!F)
    {
        return _impl.submit(callable, workSize);
    }

    /**
     * Reject new admission, drain accepted work and positively join workers.
     * Successful external calls are idempotent and coordinate concurrent
     * closers. A task that never returns can prevent this call from returning.
     * A same-executor worker receives WorkerSelfJoinException before changing
     * state or waiting on another closer. Result readiness is not a join fence.
     */
    void closeAndJoin()
    {
        _impl.closeAndJoin();
    }

    package(concurrency) void reclaimCompletedTasks()
    {
        _impl.reclaimCompleted();
    }

    package(concurrency) void waitForScopeTask(R)(TaskHandle!R handle) @system
    {
        _impl.waitForScopeTask(handle);
    }

    /**
     * Run a bounded lexical task group. Every accepted child is joined after
     * its worker has returned from dispatch, even if `body` throws. Task
     * failures are rethrown after all children return. The scope is @system:
     * callers must keep borrowed captures valid and synchronize shared state.
     *
     * maxTasks is the maximum number of children submitted during this call.
     * Submission can wait indefinitely for executor capacity. A same-pool
     * worker can open a nested scope; its join helps run queued executor work
     * rather than blocking all workers. Detach is not provided.
     */
    void withScope(
        size_t maxTasks,
        scope void delegate(ref TaskScope) body) @system
    {
        if (body is null)
            throw new Exception("scope body must not be null");

        auto state = new TaskScopeState(this, maxTasks);
        TaskScope taskScope = TaskScope(state);
        try
        {
            body(taskScope);
        }
        catch (Throwable failure)
        {
            // Drain only; preserve the body's exception as the visible error.
            state.drain();
            throw failure;
        }

        state.join();
    }

    /**
     * Fork `left` as one scoped child and run `right` inline on the caller.
     * Both sides complete before this returns; non-void results are returned
     * in JoinResult. If either side fails, the other side is still drained
     * before the exception escapes. This is a small fork-join primitive, not
     * a load-balancing policy; callers choose which side to schedule.
     *
     * This operation is @system for the same capture-lifetime reasons as
     * submit and withScope. It may wait for bounded executor admission and
     * can help available work when called from one of this executor's workers.
     */
    auto join(F1, F2)(auto ref F1 left, auto ref F2 right,
        WorkSize leftWorkSize = WorkSize.small) @system
        if (supportedTask!F1 && supportedTask!F2)
    {
        alias L = ReturnType!F1;
        alias R = ReturnType!F2;
        TaskHandle!L leftHandle;
        JoinResult!(L, R) result;

        withScope(1, (ref tasks) {
            leftHandle = tasks.spawn(left, leftWorkSize);
            static if (is(R == void))
                right();
            else
                result.right = right();
        });

        static if (is(L == void))
            leftHandle.get();
        else
            result.left = leftHandle.get();

        return result;
    }

    /**
     * Apply `body` to every index from zero up to, but not including,
     * `itemCount`, using dynamically
     * claimed contiguous ranges of at most `grainSize` indices. The caller
     * participates alongside at most `_workerCount - 1` executor workers. The
     * scope joins all workers before returning and drains them if a callback
     * throws. A zero grainSize is invalid; itemCount may be zero. Each worker
     * receives a copy of `body`. The caller must synchronize state shared by
     * callback copies.
     */
    void parallelFor(F)(size_t itemCount, size_t grainSize,
        auto ref F body) @system
        if (supportedIndexTask!F)
    {
        parallelForImpl(itemCount, grainSize, body, false);
    }

    /**
     * Apply `body` to every index from zero up to, but not including,
     * `itemCount`, using guided dynamic
     * ranges. Claims are at least `minGrainSize` while enough work remains;
     * the final partial claim may be smaller. Earlier claims may be larger
     * while much work remains, then shrink near the tail. The caller
     * participates alongside at most `_workerCount - 1` workers. The scope
     * joins all workers before returning and drains them if a callback throws.
     * Each worker receives a copy of `body`; synchronize shared callback state.
     */
    void parallelForAdaptive(F)(size_t itemCount, size_t minGrainSize,
        auto ref F body) @system
        if (supportedIndexTask!F)
    {
        parallelForImpl(itemCount, minGrainSize, body, true);
    }

    private void parallelForImpl(F)(size_t itemCount, size_t grainSize,
        auto ref F body, bool guided) @system
        if (supportedIndexTask!F)
    {
        if (grainSize == 0)
            throw new Exception(guided
                ? "parallelForAdaptive minGrainSize must be positive"
                : "parallelFor grainSize must be positive");
        if (itemCount == 0)
            return;

        const rangeCount = itemCount / grainSize +
            (itemCount % grainSize != 0 ? 1 : 0);
        const workerCount = rangeCount < _workerCount ? rangeCount : _workerCount;
        const fetchAddSafe = canUseFetchAdd(itemCount, grainSize, workerCount);
        if (workerCount == 1)
        {
            auto workerBody = body;
            foreach (index; 0 .. itemCount)
                workerBody(index);
            return;
        }

        shared size_t nextIndex;
        auto runRanges = RangeWorker!F(body, &nextIndex, itemCount, grainSize,
            fetchAddSafe, guided, workerCount);
        withScope(workerCount - 1, (ref tasks) {
            foreach (_; 1 .. workerCount)
                tasks.spawn(runRanges, WorkSize.large);
            runRanges();
        });
    }
}

unittest
{
    assert(canUseFetchAdd(size_t.max - 64, 8, 4));
    assert(!canUseFetchAdd(size_t.max - 39, 8, 4));
    assert(!canUseFetchAdd(size_t.max - 64, 8, size_t.max));
}
