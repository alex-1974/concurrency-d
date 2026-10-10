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
 *
 * This module additionally hosts the portable R0.4 P01 condition-variable
 * baseline. The predicate is the scheduler-owned generation and work state,
 * not a notification treated as a durable token.
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

import core.sync.condition :
    Condition;

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
    private Condition _changed;
    private TaskRef[] _slots;
    private size_t _head;
    private size_t _used;
    private size_t _accepted;
    private size_t _completed;
    private size_t _generation;
    private size_t _parkCount;
    private bool _closed;

    this(size_t capacity)
    {
        if (capacity == 0)
            throw new Exception("ingress capacity must be positive");

        _mutex = new Mutex();
        _changed = new Condition(_mutex);
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
            ++_generation;
            _changed.notify();
            return SubmissionResult.accepted;
        }
    }

    /**
     * An advisory non-reserving capacity check. The owned executor holds
     * its submission mutex while querying and publishing, so another
     * owned producer cannot fill the inbox in between. A worker may only
     * remove slots, making a positive result remain valid for that path.
     */
    bool hasCapacity()
    {
        synchronized (_mutex)
            return !_closed && _used < _slots.length;
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

            // The final completion releases all workers waiting for the
            // shutdown predicate. Earlier completions introduce no work.
            if (_closed && _completed == _accepted)
            {
                ++_generation;
                _changed.notifyAll();
            }
        }
    }

    void close()
    {
        synchronized (_mutex)
        {
            _closed = true;
            ++_generation;
            _changed.notifyAll();
        }
    }

    /**
     * Capture a generation BEFORE the external inbox/steal search.
     * The uncontended owner-local pop is independent of this mutex.
     */
    size_t wakeGeneration()
    {
        synchronized (_mutex)
        {
            return _generation;
        }
    }

    /**
     * Announces tasks moved into a worker-owned local deque. That move is
     * outside the inbox lock; without a new generation idle thieves might
     * miss an opportunity to steal the new work.
     */
    void announceLocalWork()
    {
        synchronized (_mutex)
        {
            ++_generation;
            _changed.notify();
        }
    }

    /**
     * Atomically compare the observed generation, validate the inbox and
     * release the mutex while sleeping. Any producer that publishes during
     * the search-to-park window changes the generation under this same lock.
     */
    void parkUnlessChanged(size_t observed)
    {
        synchronized (_mutex)
        {
            while (_generation == observed &&
                   _used == 0 &&
                   !(_closed && _completed == _accepted))
            {
                ++_parkCount;
                _changed.wait();
            }
        }
    }

    size_t parkCount()
    {
        synchronized (_mutex)
        {
            return _parkCount;
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
 * Idle workers park on a condition variable using an epoch-style wake
 * generation checked under the same mutex as publication. This is the
 * portable R0.4 P01 baseline, not an optimized spin/yield/futex policy.
 */
package(concurrency) final class SubmissionWorkerPool
{
    private TaskInbox _inbox;
    private LocalQueue[] _queues;
    private Thread[] _workers;
    private size_t _started;

    // Optional internal completion hook. Called by the claiming worker only
    // after dispatch and inbox accounting no longer need the TaskRef target.
    // It must not throw or retain the borrowed TaskRef past this invocation.
    private void function(TaskRef) nothrow _afterExecution;

    this(
        size_t workerCount,
        size_t ingressCapacity,
        void function(TaskRef) nothrow afterExecution = null)
    {
        if (workerCount == 0)
            throw new Exception("workerCount must be positive");

        _inbox = new TaskInbox(ingressCapacity);
        _afterExecution = afterExecution;
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

    /** Optional fast rejection before constructing a costly owned record. */
    bool hasIngressCapacity()
    {
        return _inbox.hasCapacity();
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

    /** Diagnostic only, used by race-oriented parking tests. */
    size_t parkCount()
    {
        return _inbox.parkCount();
    }

    private void executeOne(TaskRef task)
    {
        dispatchTask(task);
        _inbox.completeOne();

        // Returning from the record's execute thunk alone is not a
        // lifetime-safe reclamation marker: the worker could still hold
        // and dereference the record. Only mark after completion accounting
        // has finished and the task's record is no longer accessed here.
        if (_afterExecution !is null)
            _afterExecution(task);
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
            // The local-owner fast path needs no inbox mutex or wake ticket.
            // Only the owning worker can append to this deque.
            auto local = _queues[self].pop();
            if (local.found)
            {
                executeOne(local.value);
                continue;
            }

            // Capture the ticket before checking external ingress and
            // attempting steals. Publication after this point changes it.
            const observed = _inbox.wakeGeneration();

            const taken = _inbox.takeBatch(batch[]);
            if (taken != 0)
            {
                // Publish newly claimed work only into this worker's
                // owner deque, permitting other workers to steal it.
                bool enqueued;
                foreach (i; 1 .. taken)
                {
                    TaskRef task = batch[i];
                    if (_queues[self].tryPush(task))
                    {
                        enqueued = true;
                    }
                    else
                    {
                        executeOne(task);
                    }
                }

                if (enqueued)
                    _inbox.announceLocalWork();

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

            // Condition.wait releases _mutex atomically. If any
            // publication/close happened since observed, this won't sleep.
            _inbox.parkUnlessChanged(observed);
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

version (unittest)
{
    private void waitForPark(SubmissionWorkerPool pool, size_t threshold)
    {
        // Diagnostic synchronization point rather than sleep-based timing.
        // Bounded so an idle-path regression reports a failed test.
        foreach (_; 0 .. 200_000)
        {
            if (pool.parkCount() >= threshold)
                return;

            Thread.yield();
        }

        assert(0, "a worker did not reach the parking protocol");
    }

    private void waitForExecution(shared CountingRecord* record)
    {
        foreach (_; 0 .. 200_000)
        {
            if (atomicLoad!(MemoryOrder.acq)(record.executions) == 1u)
                return;

            Thread.yield();
        }

        assert(0, "isolated task was not executed after wakeup");
    }
}

unittest
{
    // Producer publishes while workers are idle. Repeated idle->work->idle
    // transitions exercise the generation/notification protocol.
    enum size_t Count = 48;
    auto records = new shared CountingRecord[Count];
    auto tasks = new TaskRef[Count];
    prepareRecords(records[], tasks);

    auto pool = new SubmissionWorkerPool(2, 2);
    waitForPark(pool, 1);

    foreach (i; 0 .. Count)
    {
        const oldParks = pool.parkCount();

        assert(pool.trySubmit(tasks[i]) == SubmissionResult.accepted);
        waitForExecution(&records[i]);
        waitForPark(pool, oldParks + 1);
    }

    pool.closeAndJoin();

    assert(pool.completedCount() == Count);
    foreach (i; 0 .. Count)
    {
        assert(atomicLoad!(MemoryOrder.acq)(
            records[i].executions) == 1u);
    }
}

unittest
{
    // All workers initially idle; close must broadcast and join them.
    auto pool = new SubmissionWorkerPool(4, 2);
    waitForPark(pool, 1);

    pool.closeAndJoin();
    assert(pool.acceptedCount() == 0);
    assert(pool.completedCount() == 0);
}

unittest
{
    // Publication before the park check cannot be missed, because the
    // generation is changed under the same mutex as Condition.wait.
    auto inbox = new TaskInbox(2);
    shared CountingRecord record;
    TaskRef task = TaskRef(&record.header);

    const observed = inbox.wakeGeneration();
    assert(inbox.trySubmit(task) == SubmissionResult.accepted);

    // An incorrect generation protocol could block this test forever.
    inbox.parkUnlessChanged(observed);

    TaskRef[1] received;
    assert(inbox.takeBatch(received[]) == 1);
    inbox.completeOne();
    inbox.close();
    assert(inbox.isDrained());
}
