/**
 * Lexically bounded task group prototype. A scope has no detach path and
 * waits for every accepted task's post-dispatch return before it exits.
 */
module concurrency.taskscope;

import concurrency.executor : Executor;
import concurrency.cancellation : CancellationState, CancellationToken;
import concurrency.task : TaskHandle;
import std.traits : ReturnType;

private struct ScopeJoinState
{
    Object handle;
    void function(Executor, Object) waitReturned;
    Throwable function(Object) failure;
}

private void waitScopeTask(R)(Executor executor, Object object)
{
    executor.waitForScopeTask(cast(TaskHandle!R) object);
}

private Throwable scopeTaskFailure(R)(Object object)
{
    return (cast(TaskHandle!R) object).taskFailure();
}

// Frame-owned join state. It is package-visible only so Executor.withScope can
// retain it independently of any move performed on the public TaskScope view.
package(concurrency) final class TaskScopeState
{
    private Executor _executor;
    private CancellationToken _cancellation;
    private ScopeJoinState[] _tasks;
    private size_t _used;
    private bool _joined;

    this(Executor executor, size_t maxTasks) @system
    {
        if (maxTasks == 0)
            throw new Exception("scope maxTasks must be positive");

        _executor = executor;
        _cancellation = CancellationToken(new CancellationState());
        _tasks = new ScopeJoinState[maxTasks];
    }

    /**
     * Submit one child and retain its join obligation in this scope. May wait
     * indefinitely for executor capacity. Throws if this scope has reached
     * maxTasks or has already joined. The returned handle observes the typed
     * result; it does not replace this scope's post-dispatch join.
     */
    auto spawn(F)(auto ref F callable) @system
    {
        if (_joined)
            throw new Exception("cannot spawn after scope join");
        if (_used == _tasks.length)
            throw new Exception("scope maxTasks exceeded");

        auto handle = _executor.submit(callable);
        alias R = ReturnType!F;
        _tasks[_used++] = ScopeJoinState(
            cast(Object) handle,
            &waitScopeTask!R,
            &scopeTaskFailure!R);
        return handle;
    }

    /** Return a copyable signal for children to poll cooperatively. */
    CancellationToken cancellationToken() @safe nothrow
    {
        return _cancellation;
    }

    /** Request cooperative cancellation for this scope's child tasks. */
    void requestCancellation() @safe nothrow
    {
        _cancellation.requestCancellation();
    }

    /**
     * Wait until each accepted child's worker has stopped accessing its task
     * record, then rethrow the first task failure. All children are drained
     * before any task failure is propagated.
     */
    void join()
    {
        drain();

        Throwable firstFailure;
        foreach (task; _tasks[0 .. _used])
        {
            auto failure = task.failure(task.handle);
            if (firstFailure is null && failure !is null)
                firstFailure = failure;
        }

        if (firstFailure !is null)
            throw firstFailure;
    }

    /** Internal unwind path: preserve the builder's exception after draining. */
    void drain()
    {
        if (_joined)
            return;

        foreach (task; _tasks[0 .. _used])
            task.waitReturned(_executor, task.handle);

        _joined = true;
        // Remove completed nodes now, so their copied callables (which may
        // contain scope-bounded borrows) are no longer retained by the pool.
        _executor.reclaimCompletedTasks();
    }
}

/**
 * Bounded set of tasks whose callable captures may borrow the surrounding
 * stack. This API is @system: the caller must keep every borrowed referent
 * valid and synchronize shared state until withScope returns.
 *
 * Construct scopes through Executor.withScope. `maxTasks` limits total
 * admissions in the scope, not only tasks concurrently executing. Task
 * results remain available through their returned handles after join. Moving
 * this public view may reset the source view, but cannot move the join
 * obligation out of Executor.withScope: that frame retains the internal state
 * independently and drains it.
 */
struct TaskScope
{
    private TaskScopeState _state;

    @disable this(this);

    package(concurrency) this(TaskScopeState state) @safe nothrow
    {
        _state = state;
    }

    private TaskScopeState requireState() @safe
    {
        if (_state is null)
            throw new Exception("scope was not created by withScope");
        return _state;
    }

    /** Submit one child and retain its join obligation in the lexical state. */
    auto spawn(F)(auto ref F callable) @system
    {
        return requireState().spawn(callable);
    }

    /** Return a copyable signal for children to poll cooperatively. */
    CancellationToken cancellationToken() @safe nothrow
    {
        if (_state is null)
            return CancellationToken.init;
        return _state.cancellationToken();
    }

    /** Request cooperative cancellation for this scope's child tasks. */
    void requestCancellation() @safe nothrow
    {
        if (_state !is null)
            _state.requestCancellation();
    }

    /** Explicitly join the same state that withScope will always drain. */
    void join()
    {
        requireState().join();
    }
}
