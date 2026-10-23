/**
 * Cooperative cancellation shared by a task scope and its child tasks.
 * Requesting cancellation never interrupts a task or discharges a join.
 */
module concurrency.cancellation;

import core.atomic : MemoryOrder, atomicLoad, atomicStore;

package(concurrency) final class CancellationState
{
    shared uint requested;
}

/**
 * Copyable, thread-safe cancellation signal. Tasks decide where and how often
 * to poll it. A token may outlive its scope; the request then has no executor
 * effect, but its state remains valid. All copies share one idempotent request
 * bit. Request and task completion may race; cancellation never publishes or
 * replaces a TaskHandle result. The default-initialized token is inert.
 */
struct CancellationToken
{
    private CancellationState _state;

    package(concurrency) this(CancellationState state) @safe nothrow
    {
        _state = state;
    }

    /** Read the cooperative request with acquire ordering. */
    bool isCancellationRequested() const @safe nothrow
    {
        if (_state is null)
            return false;
        return atomicLoad!(MemoryOrder.acq)(_state.requested) != 0;
    }

    /** Publish the shared, idempotent cooperative request with release ordering. */
    void requestCancellation() @safe nothrow
    {
        if (_state is null)
            return;
        atomicStore!(MemoryOrder.rel)(_state.requested, 1u);
    }
}
