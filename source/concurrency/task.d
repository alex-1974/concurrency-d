/**
 * Typed task results independent of task-record reclamation and executor join.
 * Submission retains the task even if its handle is dropped. A result becoming
 * ready does not certify the last worker access to the task record.
 */
module concurrency.task;

private import core.sync.mutex : Mutex;
private import core.sync.condition : Condition;

// Internal synchronized completion cell, independent of executor shutdown.
package(concurrency) final class ResultCell(R)
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
