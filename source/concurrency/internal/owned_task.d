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
 * Concrete node with an embedded header-first record. The class itself
 * supplies GC retention; only the record header address reaches the deque.
 */
private final class OwnedNode(F, R)
{
    private struct Record
    {
        TaskHeader header;
        F callable;
        ResultCell!R cell;
    }

    private Record _record;

    this(F callable, ResultCell!R cell)
    {
        _record.callable = callable;
        _record.cell = cell;
        _record.header.execute = &execute;
    }

    TaskRef reference()
    {
        return TaskRef(cast(shared(TaskHeader)*) &_record.header);
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
    private SubmissionWorkerPool _pool;
    private Mutex _mutex;
    private Object[] _retained;
    private size_t _maxRetained;
    private bool _closed;

    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
        if (maxRetained == 0)
            throw new Exception("maxRetained must be positive");

        _pool = new SubmissionWorkerPool(workers, ingressCapacity);
        _mutex = new Mutex();
        _maxRetained = maxRetained;
    }

    /**
     * Returns null if bounded ingress is currently full; throws on close
     * or when the explicit record retention budget has been exhausted.
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
            if (_closed)
                throw new Exception("executor is closed");

            if (_retained.length >= _maxRetained)
                throw new Exception("retained task capacity exhausted");

            // Install the strong GC root before any worker can claim the
            // record. If admission fails, undo only our tail insertion.
            _retained ~= node;
            const status = _pool.trySubmit(node.reference());

            if (status != SubmissionResult.accepted)
            {
                _retained.length = _retained.length - 1;

                if (status == SubmissionResult.closed)
                    throw new Exception("executor is closed");

                assert(status == SubmissionResult.full);
                return typeof(handle).init;
            }
        }

        return handle;
    }

    /** Retry while ingress is transiently full. No lock held when yielding. */
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

    void closeAndJoin()
    {
        synchronized (_mutex)
            _closed = true;

        _pool.closeAndJoin();
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
