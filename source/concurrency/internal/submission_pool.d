/**
 * Internal multi-producer task ingress for M0.
 *
 * Producers never push into the owner-only WorkStealingDeque of another
 * thread. They publish non-owning TaskRefs into a bounded mutex-protected
 * FIFO. Worker threads drain small batches from this FIFO into their own
 * deques, then execute or steal as usual.
 *
 * This is a synchronous-lifetime prototype: the caller retains every
 * admitted TaskRecord until closeAndJoin() has returned. A public owned-task
 * API and general failure propagation are separate M0 work.
 */
module concurrency.internal.submission_pool;

import concurrency.internal.task_record :
    TaskHeader,
    TaskRef,
    dispatchTask;

import concurrency.internal.work_stealing_queue :
    LocalWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad;

import core.sync.mutex :
    Mutex;

import core.thread :
    Thread;

package(concurrency) enum SubmissionResult
{
    accepted,
    full,
    closed
}

private enum size_t LocalCapacity = 1024;
private enum size_t IngressBatchSize = 8;

private alias LocalQueue =
    LocalWorkStealingDeque!(TaskRef, LocalCapacity);

/**
 * A bounded MPMC inbox. Every state transition is protected by one mutex.
 * `accepted` counts obligations, not queue slots: claiming a TaskRef
 * removes a slot but completion occurs only after dispatchTask returns.
 */
private final class TaskInbox
{
    private Mutex _mutex;
    private TaskRef[] _slots;
    private size_t _head;
    private size_t _used;
    private size_t _accepted;
    private size_t _completed;
    private bool _closed;

    this(size_t capacity)
    {
        if (capacity == 0)
            throw new Exception("ingress capacity must be positive");

        _mutex = new Mutex();
        _slots = new TaskRef[capacity];
    }

    SubmissionResult trySubmit(TaskRef task)
    {
        if (task.ptr is null)
            throw new Exception("cannot submit a null TaskRef");

        synchronized (_mutex)
        {
            if (_closed)
                return SubmissionResult.closed;

            if (_used == _slots.length)
                return SubmissionResult.full;

            // Commit the execution obligation and make the record visible
            // under the same mutex. A failed submission changes neither.
            const tail = (_head + _used) % _slots.length;
            _slots[tail] = task;
            ++_used;
            ++_accepted;
            return SubmissionResult.accepted;
        }
    }

    size_t takeBatch(scope TaskRef[] output)
    {
        synchronized (_mutex)
        {
            size_t taken;

            while (taken < output.length && _used != 0)
            {
                output[taken] = _slots[_head];
                _slots[_head] = TaskRef.init;
                _head = (_head + 1) % _slots.length;
                --_used;
                ++taken;
            }

            return taken;
        }
    }

    void completeOne()
    {
        synchronized (_mutex)
        {
            assert(_completed < _accepted);
            ++_completed;
        }
    }

    void close()
    {
        synchronized (_mutex)
        {
            _closed = true;
        }
    }

    bool isDrained()
    {
        synchronized (_mutex)
        {
            return _closed &&
                _used == 0 &&
                _completed == _accepted;
        }
    }

    size_t acceptedCount()
    {
        synchronized (_mutex)
        {
            return _accepted;
        }
    }

    size_t completedCount()
    {
        synchronized (_mutex)
        {
            return _completed;
        }
    }
}

/**
 * First internal long-running worker pool with external task submission.
 *
 * The pool is created at its final address, owns its worker deques and inbox,
 * and is closed/joined explicitly by its controlling thread. Many producer
 * threads may call trySubmit concurrently with each other and with close.
 *
 * Ingress rejection does NOT transfer ownership of a TaskRecord. On success,
 * the pool owes one execution, but it never owns the TaskRecord storage.
 * Keep every admitted record alive until closeAndJoin completes.
 *
 * Worker threads yield while idle; condition-variable parking is issue #10.
 */
package(concurrency) final class SubmissionWorkerPool
{
    private TaskInbox _inbox;
    private LocalQueue[] _queues;
    private Thread[] _workers;
    private size_t _started;

    this(size_t workerCount, size_t ingressCapacity)
    {
        if (workerCount == 0)
            throw new Exception("workerCount must be positive");

        _inbox = new TaskInbox(ingressCapacity);
        _queues = new LocalQueue[workerCount];
        _workers = new Thread[workerCount];

        try
        {
            foreach (index; 0 .. workerCount)
            {
                _workers[index] = makeWorker(index);
                _workers[index].start();
                ++_started;
            }
        }
        catch (Throwable failure)
        {
            // If startup partially succeeds, no tasks have been admitted.
            // Close the inbox and join every successfully started thread.
            _inbox.close();

            foreach (index; 0 .. _started)
                _workers[index].join();

            throw failure;
        }
    }

    // Separate invocation frame per worker is necessary: each deque must
    // have exactly one owner. Never capture a reused foreach slot here.
    private Thread makeWorker(size_t workerIndex)
    {
        return new Thread({
            workerLoop(workerIndex);
        });
    }

    SubmissionResult trySubmit(TaskRef task)
    {
        return _inbox.trySubmit(task);
    }

    /** Blocks until all admitted tasks have completed and all workers exit. */
    void closeAndJoin()
    {
        _inbox.close();

        // Must be called by the controlling thread; concurrent joins of the
        // same Thread objects are not an admitted operation in this slice.
        foreach (index; 0 .. _started)
            _workers[index].join();
    }

    size_t acceptedCount()
    {
        return _inbox.acceptedCount();
    }

    size_t completedCount()
    {
        return _inbox.completedCount();
    }

    private void executeOne(TaskRef task)
    {
        dispatchTask(task);
        _inbox.completeOne();
    }

    private void workerLoop(size_t self)
    {
        TaskRef[IngressBatchSize] batch;

        size_t nextVictim =
            _queues.length > 1
            ? (self + 1) % _queues.length
            : self;

        for (;;)
        {
            auto local = _queues[self].pop();
            if (local.found)
            {
                executeOne(local.value);
                continue;
            }

            const taken = _inbox.takeBatch(batch[]);
            if (taken != 0)
            {
                // Publish newly claimed work only into this worker's
                // owner deque, permitting other workers to steal it.
                foreach (i; 1 .. taken)
                {
                    TaskRef task = batch[i];
                    if (!_queues[self].tryPush(task))
                        executeOne(task);
                }

                executeOne(batch[0]);
                continue;
            }

            bool foundWork;

            foreach (_; 0 .. _queues.length - 1)
            {
                const victim = nextVictim;
                nextVictim = (nextVictim + 1) % _queues.length;

                if (victim == self)
                    continue;

                auto stolen = _queues[victim].steal();

                if (!stolen.found)
                    continue;

                executeOne(stolen.value);
                foundWork = true;
                break;
            }

            if (foundWork)
                continue;

            if (_inbox.isDrained())
                break;

            Thread.yield();
        }
    }
}

version (unittest)
{
    private struct CountingRecord
    {
        TaskHeader header;
        size_t id;
        shared uint executions;
    }

    private void executeCounting(shared(TaskHeader)* header)
        @trusted @nogc nothrow
    {
        auto record = cast(shared(CountingRecord)*) header;
        assert(atomicLoad!(MemoryOrder.raw)(record.id) != 0);
        atomicFetchAdd!(MemoryOrder.rel)(
            record.executions,
            1u);
    }

    private void prepareRecords(
        shared CountingRecord[] records,
        TaskRef[] tasks)
    {
        assert(records.length == tasks.length);

        foreach (i; 0 .. tasks.length)
        {
            records[i].header.execute = &executeCounting;
            records[i].id = i + 1;
            records[i].executions = 0;
            tasks[i] = TaskRef(&records[i].header);
        }
    }

    // Give each producer its own invocation frame. Capturing an enclosing
    // foreach iteration variable in a long-lived thread closure can alias a
    // reused loop activation and cause duplicate task submissions.
    private Thread makeProducer(
        SubmissionWorkerPool pool,
        TaskRef[] tasks,
        size_t producerIndex,
        size_t producerCount)
    {
        return new Thread({
            for (size_t i = producerIndex;
                 i < tasks.length;
                 i += producerCount)
            {
                for (;;)
                {
                    const result = pool.trySubmit(tasks[i]);

                    if (result == SubmissionResult.accepted)
                        break;

                    assert(result == SubmissionResult.full);
                    Thread.yield();
                }
            }
        });
    }
}

unittest
{
    // Deterministic backpressure and close behavior without consumers.
    auto inbox = new TaskInbox(2);

    shared CountingRecord[3] records;
    TaskRef[3] tasks;
    prepareRecords(records[], tasks[]);

    assert(inbox.trySubmit(tasks[0]) == SubmissionResult.accepted);
    assert(inbox.trySubmit(tasks[1]) == SubmissionResult.accepted);
    assert(inbox.trySubmit(tasks[2]) == SubmissionResult.full);

    TaskRef[2] received;
    assert(inbox.takeBatch(received[]) == 2);
    assert(received[0].ptr == tasks[0].ptr);
    assert(received[1].ptr == tasks[1].ptr);
    assert(!inbox.isDrained());

    inbox.completeOne();
    inbox.completeOne();
    inbox.close();

    assert(inbox.isDrained());
    assert(inbox.acceptedCount() == 2);
    assert(inbox.completedCount() == 2);
    assert(inbox.trySubmit(tasks[2]) == SubmissionResult.closed);
}

unittest
{
    // Multiple independent producers, bounded ingress and 1/4 workers.
    enum size_t TaskCount = 3072;
    enum size_t ProducerCount = 4;

    foreach (workerCount; [1, 4])
    {
        auto records = new shared CountingRecord[TaskCount];
        auto tasks = new TaskRef[TaskCount];
        prepareRecords(records[], tasks);

        auto pool = new SubmissionWorkerPool(workerCount, 3);
        Thread[ProducerCount] producers;

        foreach (producerIndex; 0 .. ProducerCount)
        {
            producers[producerIndex] = makeProducer(
                pool,
                tasks,
                producerIndex,
                ProducerCount);
            producers[producerIndex].start();
        }

        foreach (producer; producers)
            producer.join();

        pool.closeAndJoin();

        assert(pool.acceptedCount() == TaskCount);
        assert(pool.completedCount() == TaskCount);
        assert(pool.trySubmit(tasks[0]) == SubmissionResult.closed);

        foreach (i; 0 .. TaskCount)
        {
            assert(atomicLoad!(MemoryOrder.acq)(
                records[i].executions) == 1u);
        }
    }
}

unittest
{
    // Closing while producers are active: only accepted records may execute.
    enum size_t TaskCount = 1024;
    auto records = new shared CountingRecord[TaskCount];
    auto tasks = new TaskRef[TaskCount];
    prepareRecords(records[], tasks);

    auto pool = new SubmissionWorkerPool(2, 2);
    auto accepted = new shared uint[TaskCount];

    auto producer = new Thread({
        foreach (i; 0 .. TaskCount)
        {
            const result = pool.trySubmit(tasks[i]);

            if (result == SubmissionResult.closed)
                break;

            if (result == SubmissionResult.full)
            {
                Thread.yield();
                continue;
            }

            atomicFetchAdd!(MemoryOrder.rel)(
                accepted[i],
                1u);
        }
    });

    producer.start();
    pool.closeAndJoin();
    producer.join();

    size_t count;
    foreach (i; 0 .. TaskCount)
    {
        const wasAccepted = atomicLoad!(MemoryOrder.acq)(accepted[i]);
        const executions = atomicLoad!(MemoryOrder.acq)(
            records[i].executions);

        assert(wasAccepted <= 1u);
        assert(executions == wasAccepted);
        count += wasAccepted;
    }

    assert(count == pool.acceptedCount());
    assert(count == pool.completedCount());
}
