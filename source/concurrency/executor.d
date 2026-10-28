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

private void blockBounds(size_t itemCount, size_t blockSize, size_t block,
    out size_t first, out size_t last) @safe pure nothrow
{
    first = block * blockSize;
    const remaining = itemCount - first;
    last = first + (remaining < blockSize ? remaining : blockSize);
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

/** Cyclically distributed blocks with a participant-local atomic queue cursor. */
private struct SplitRangeState
{
    shared size_t[] _nextBlock;
    size_t[] _blocksPerLane;
    size_t _itemCount;
    size_t _blockSize;
    size_t _laneCount;

    this(size_t maxLanes, size_t itemCount, size_t minGrainSize)
    {
        _itemCount = itemCount;
        // Use more blocks for larger domains to keep their tails divisible.
        const blocksPerLane = itemCount <= 4096 ? 8 : 16;
        const denominator = maxLanes <= size_t.max / blocksPerLane
            ? maxLanes * blocksPerLane : size_t.max;
        _blockSize = itemCount / denominator;
        if (_blockSize < minGrainSize)
            _blockSize = minGrainSize;
        // Keep tiny domains from creating one queue entry per individual item.
        if (_blockSize < 4)
            _blockSize = 4;

        const blockCount = itemCount / _blockSize +
            (itemCount % _blockSize != 0 ? 1 : 0);
        _laneCount = blockCount < maxLanes ? blockCount : maxLanes;
        _nextBlock = new shared size_t[_laneCount];
        _blocksPerLane = new size_t[_laneCount];
        foreach (lane; 0 .. _laneCount)
        {
            _blocksPerLane[lane] = lane < blockCount
                ? (blockCount - 1 - lane) / _laneCount + 1 : 0;
        }
    }

    bool take(size_t lane, out size_t first, out size_t last) @system
    {
        first = atomicLoad!(MemoryOrder.raw)(_nextBlock[lane]);
        while (first < _blocksPerLane[lane])
        {
            const remaining = _blocksPerLane[lane] - first;
            const claimSize = remaining / 4 > 0 ? remaining / 4 : 1;
            last = first + (remaining < claimSize ? remaining : claimSize);
            if (cas!(MemoryOrder.raw, MemoryOrder.raw)(
                _nextBlock.ptr + lane, first, last))
                return true;
            first = atomicLoad!(MemoryOrder.raw)(_nextBlock[lane]);
        }
        return false;
    }

    bool steal(size_t thief, out size_t victim,
        out size_t first, out size_t last) @system
    {
        foreach (offset; 1 .. _laneCount)
        {
            victim = (thief + offset) % _laneCount;
            if (take(victim, first, last))
                return true;
        }
        return false;
    }

    bool empty() @system
    {
        foreach (lane; 0 .. _laneCount)
        {
            if (atomicLoad!(MemoryOrder.raw)(_nextBlock[lane]) <
                _blocksPerLane[lane])
                return false;
        }
        return true;
    }

    void run(F)(size_t lane, size_t first, size_t last,
        ref F body) @system
    {
        foreach (ordinal; first .. last)
        {
            const block = lane + ordinal * _laneCount;
            size_t begin;
            size_t end;
            blockBounds(_itemCount, _blockSize, block, begin, end);
            foreach (index; begin .. end)
                body(index);
        }
    }
}

private struct SplitRangeWorker(F)
{
    F _body;
    SplitRangeState _ranges;
    size_t _lane;

    this(F body, SplitRangeState ranges, size_t lane)
    {
        _body = body;
        _ranges = ranges;
        _lane = lane;
    }

    void opCall() @system
    {
        while (true)
        {
            size_t first;
            size_t last;
            if (_ranges.take(_lane, first, last))
            {
                _ranges.run(_lane, first, last, _body);
                continue;
            }
            size_t victim;
            if (_ranges.steal(_lane, victim, first, last))
            {
                _ranges.run(victim, first, last, _body);
                continue;
            }
            if (_ranges.empty())
                return;
        }
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
     * Submit a homogeneous batch atomically and return one typed
     * handle per callable. The batch must fit both ingress and retained-record
     * capacities; otherwise this throws. An empty batch returns no handles.
     * If current capacity is occupied, the call waits until the whole batch
     * fits and may wait indefinitely if existing work cannot release capacity.
     * A same-pool worker helps execute queued work while waiting. The batch
     * uses one admission lock and one inbox lock, reducing synchronization for
     * many small tasks. Each task still has its own record and typed handle.
     * Arbitrary captures remain the caller's responsibility.
     */
    auto submitBatch(F)(scope F[] callables,
        WorkSize workSize = WorkSize.small) @system
        if (supportedTask!F)
    {
        return _impl.submitBatch(callables, workSize);
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
     * Apply `body` to each item using a scheduler-selected grain based on the
     * caller's estimate of per-item work. `WorkSize.small` may run a bounded
     * range inline; larger domains and `WorkSize.large` use parallel ranges.
     * This is a heuristic convenience overload. Use the explicit-grain
     * overload when the caller needs direct control over claim size.
     */
    void parallelFor(F)(size_t itemCount, auto ref F body,
        WorkSize itemWork) @system
        if (supportedIndexTask!F)
    {
        if (itemCount == 0)
            return;

        size_t grainSize;
        const inlineLimit = _workerCount <= size_t.max / 256
            ? _workerCount * 256 : size_t.max;
        if (itemWork == WorkSize.small && itemCount <= inlineLimit)
        {
            grainSize = itemCount;
        }
        else
        {
            const rangesPerWorker = itemWork == WorkSize.small ? 8 : 4;
            const targetRanges = _workerCount <= size_t.max / rangesPerWorker
                ? _workerCount * rangesPerWorker : size_t.max;
            grainSize = itemCount / targetRanges +
                (itemCount % targetRanges != 0 ? 1 : 0);
        }

        parallelForImpl(itemCount, grainSize, body, false);
    }

    /**
     * Apply `body` to every index from zero up to, but not including,
     * `itemCount`, using guided dynamic ranges. For `minGrainSize == 1`, work
     * is divided into cyclic blocks that idle participants can steal. Other
     * minimum grain sizes use dynamically claimed ranges. Claims are at least
     * `minGrainSize` while enough work remains;
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

        // Fine adaptive work uses cyclic blocks to distribute clustered work
        // across participants while retaining per-lane atomic claim cursors.
        if (guided && grainSize == 1)
        {
            auto ranges = SplitRangeState(workerCount, itemCount, grainSize);
            if (ranges._laneCount == 1)
            {
                auto workerBody = body;
                foreach (index; 0 .. itemCount)
                    workerBody(index);
                return;
            }
            withScope(ranges._laneCount - 1, (ref tasks) {
                foreach (lane; 1 .. ranges._laneCount)
                    tasks.spawn(SplitRangeWorker!F(body, ranges, lane),
                        WorkSize.large);
                SplitRangeWorker!F(body, ranges, 0)();
            });
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

    size_t first;
    size_t last;
    const block = (size_t.max - 1) / 8;
    blockBounds(size_t.max, 8, block, first, last);
    assert(last == size_t.max);
}
