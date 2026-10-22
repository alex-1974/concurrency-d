/**
 * Explicitly controlled CPU executor for copyable callable values and results.
 *
 * This is a version-zero API candidate. Submission is @system: the caller must
 * guarantee referent lifetimes and race-free cross-thread access. There is no
 * detach, cancellation, destructor join, work helping or general TaskScope.
 */
module concurrency.executor;

private import concurrency.internal.owned_task : OwnedTaskExecutor;
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
 * CPU executor with bounded ingress and retained-record capacity.
 *
 * Safely publish the executor to producer threads; keep it explicitly rooted
 * until closeAndJoin succeeds. Multiple external producers and close callers
 * are supported. No finalizer or destructor silently joins on the caller's
 * behalf. User callbacks, copies and destructors must not invalidate published
 * storage or reenter executor operations under their admission lock.
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
     * if accepted tasks never return. No fairness, timeout or worker helping is
     * promised. Do not use blocking capacity retry from an exhausted own pool.
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
}
