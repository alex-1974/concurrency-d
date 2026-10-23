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

private import concurrency.internal.owned_task : OwnedTaskExecutor;
private import concurrency.taskscope : TaskScope, TaskScopeState;
private import concurrency.task : TaskHandle;
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

    /**
     * All limits must be positive. workers is explicit (no guessed default).
     * ingressCapacity bounds waiting inbox entries; maxRetained bounds task
     * records still retained by the executor, not bytes or total heap usage.
     * Owner setup completes before any native worker starts.
     */
    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
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
     */
    auto trySubmit(F)(auto ref F callable) @system
        if (supportedTask!F)
    {
        return _impl.trySubmit(callable);
    }

    /**
     * Retry capacity rejection until admitted or closed. May wait indefinitely
     * if retained/inbox capacity is held by work that cannot make progress.
     * When a worker retries admission, it runs available same-pool work to
     * make capacity progress. No fairness or timeout is promised; blocked
     * callbacks or a retained budget too small for active parents can exhaust it.
     */
    auto submit(F)(auto ref F callable) @system
        if (supportedTask!F)
    {
        return _impl.submit(callable);
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
    auto join(F1, F2)(auto ref F1 left, auto ref F2 right) @system
        if (supportedTask!F1 && supportedTask!F2)
    {
        alias L = ReturnType!F1;
        alias R = ReturnType!F2;
        TaskHandle!L leftHandle;
        JoinResult!(L, R) result;

        withScope(1, (ref tasks) {
            leftHandle = tasks.spawn(left);
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
}
