/**
 * Typed task results independent of task-record reclamation and executor join.
 * Submission retains the task even if its handle is dropped. A result becoming
 * ready does not certify the last worker access to the task record.
 */
module concurrency.task;

private import core.sync.mutex : Mutex;
private import core.sync.condition : Condition;
private import core.atomic : MemoryOrder, atomicLoad, atomicStore;
private import concurrency.internal.lifecycle : LifecycleFailure, lifecycleFailStop;

// One shared lock, but wait queues are created only for cells that actually wait.
package(concurrency) final class ResultNotifier
{
    private Mutex _mutex;

    this()
    {
        _mutex = new Mutex();
    }

    void lock() { _mutex.lock(); }
    void unlock() { _mutex.unlock(); }
    Condition newCondition() { return new Condition(_mutex); }
}

// Internal synchronized completion cell, independent of executor shutdown.
package(concurrency) final class ResultCell(R)
{
    private ResultNotifier _notifier;
    private Condition _changed;
    private shared uint _done;
    private shared uint _returned;
    private Throwable _error;

    static if (!is(R == void))
        private R _value;

    this(ResultNotifier notifier)
    {
        _notifier = notifier;
    }

    private void prepareWait()
    {
        if (_changed is null)
            _changed = _notifier.newCondition();
    }

    static if (is(R == void))
    {
        void succeed()
        {
            _notifier.lock();
            scope(exit) _notifier.unlock();
            assert(atomicLoad!(MemoryOrder.acq)(_done) == 0u);
            atomicStore!(MemoryOrder.rel)(_done, 1u);
            if (_changed !is null)
                _changed.notifyAll();
        }
    }
    else
    {
        void succeed(R value)
        {
            _notifier.lock();
            scope(exit) _notifier.unlock();
            assert(atomicLoad!(MemoryOrder.acq)(_done) == 0u);
            _value = value;
            atomicStore!(MemoryOrder.rel)(_done, 1u);
            if (_changed !is null)
                _changed.notifyAll();
        }
    }

    void fail(Throwable failure)
    {
        _notifier.lock();
        scope(exit) _notifier.unlock();
        assert(atomicLoad!(MemoryOrder.acq)(_done) == 0u);
        _error = failure;
        atomicStore!(MemoryOrder.rel)(_done, 1u);
        if (_changed !is null)
            _changed.notifyAll();
    }

    bool isComplete()
    {
        return atomicLoad!(MemoryOrder.acq)(_done) != 0u;
    }

    /** Published after the worker has stopped accessing the task record. */
    package(concurrency) void markReturned() @system nothrow
    {
        try
        {
            _notifier.lock();
            scope(exit) _notifier.unlock();
            atomicStore!(MemoryOrder.rel)(_returned, 1u);
            if (_changed !is null)
                _changed.notifyAll();
        }
        catch (Throwable)
        {
            lifecycleFailStop(LifecycleFailure.worker);
        }
    }

    /** Wait for post-dispatch return, which is later than result readiness. */
    package(concurrency) void waitUntilReturned() @system
    {
        if (atomicLoad!(MemoryOrder.acq)(_returned) != 0u)
            return;

        try
        {
            _notifier.lock();
            scope(exit) _notifier.unlock();
            prepareWait();
            while (atomicLoad!(MemoryOrder.acq)(_returned) == 0u)
            {
                _changed.wait();
            }
        }
        catch (Throwable)
        {
            // Returning while a child may still hold a borrowed TaskRef would
            // invalidate caller storage. Treat uncertain synchronization as
            // the same fatal lifetime boundary as uncertain native join.
            lifecycleFailStop(LifecycleFailure.owner);
        }
    }

    package(concurrency) bool hasReturned()
    {
        return atomicLoad!(MemoryOrder.acq)(_returned) != 0u;
    }

    package(concurrency) Throwable taskFailure()
    {
        _notifier.lock();
        scope(exit) _notifier.unlock();
        return _error;
    }

    auto get()
    {
        // Match Phobos' ready-result fast path: most streamed tasks are often
        // complete by the time their bounded producer window is consumed.
        if (atomicLoad!(MemoryOrder.acq)(_done) != 0u)
        {
            if (_error !is null)
                throw _error;

            static if (!is(R == void))
                return _value;
            else
                return;
        }

        _notifier.lock();
        scope(exit) _notifier.unlock();
        prepareWait();
        while (atomicLoad!(MemoryOrder.acq)(_done) == 0u)
        {
            _changed.wait();
        }

        if (_error !is null)
            throw _error;

        static if (!is(R == void))
            return _value;
    }
}

/**
 * A typed result handle. Dropping it never cancels accepted work.
 * The executor owns the task record, not the TaskHandle.
 */
final class TaskHandle(R)
{
    private ResultCell!R _cell;

    package(concurrency) this(ResultCell!R cell)
    {
        _cell = cell;
    }

    /** Observe synchronized result/error readiness; not worker quiescence. */
    bool isComplete()
    {
        return _cell.isComplete();
    }

    package(concurrency) final void waitUntilReturned()
    {
        _cell.waitUntilReturned();
    }

    package(concurrency) final bool hasReturned()
    {
        return _cell.hasReturned();
    }

    package(concurrency) final Throwable taskFailure()
    {
        return _cell.taskFailure();
    }

    /**
     * Wait for the result, return a copy (or void), or rethrow the task failure.
     * Repeated calls observe the same stored outcome. Mutable reference results
     * remain shared references, not deep copies. Do not block a worker on an
     * unmet result that requires capacity from the same exhausted executor.
     */
    auto get()
    {
        return _cell.get();
    }
}
