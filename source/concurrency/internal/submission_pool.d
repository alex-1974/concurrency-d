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

import concurrency.internal.lifecycle :
    LifecycleFailure, lifecycleFailStop;
import concurrency.errors : WorkerSelfJoinException;

// D thread-local identity: installed once at worker entry, cleared at exit.
// No identity lookup is added to the per-task scheduling hot path.
private SubmissionWorkerPool currentWorkerPool;
private size_t currentWorkerIndex;

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
    private size_t _waiters;
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

            // A worker between generation capture and wait enrollment will
            // observe this generation change under the same mutex and skip
            // sleeping. Notify only an already-enrolled waiter; a Condition
            // notification is not a stored work token.
            if (_waiters != 0)
                _changed.notify();
            return SubmissionResult.accepted;
        }
    }

    /**
     * Advisory full-inbox check, called while OwnedTaskExecutor's producer
     * admission mutex is held. Worker threads only remove entries; another
     * owned producer cannot add an entry before that owner's trySubmit.
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
                ++_waiters;
                scope (exit)
                {
                    assert(_waiters != 0);
                    --_waiters;
                }
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
 * portable R0.4 condition/generation protocol. Publish notification is
 * coalesced when no worker is enrolled in the condition wait; local handoff,
 * close and final completion retain their original wake policies.
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
                startWorker(_workers[index]);
                ++_started;
            }
        }
        catch (Throwable failure)
        {
            // An allocation/worker-construction failure outside startWorker
            // is known to precede the next native launch. Join confirmed workers
            // before propagating it. startWorker itself never unwinds uncertainly.
            if (_started != 0)
            {
                closeInbox();
                joinStartedWorkers();
            }

            throw failure;
        }
    }

    private void startWorker(Thread worker)
    {
        try
        {
            worker.start();
        }
        catch (Throwable)
        {
            // start can throw after native launch, before _started increments.
            lifecycleFailStop(LifecycleFailure.start);
        }
    }

    private void closeInbox()
    {
        try
            _inbox.close();
        catch (Throwable)
            lifecycleFailStop(LifecycleFailure.close);
    }

    private void joinStartedWorkers()
    {
        foreach (index; 0 .. _started)
        {
            Throwable unhandled;
            try
                unhandled = _workers[index].join(false);
            catch (Throwable)
                lifecycleFailStop(LifecycleFailure.join);

            // A returned worker failure is distinct from a native join error.
            // Neither is an ordinary task Exception at this pool boundary.
            if (unhandled !is null)
                lifecycleFailStop(LifecycleFailure.worker);
        }
    }

    /** Must run before an owned executor enters its draining state/wait. */
    void requireExternalController()
    {
        if (currentWorkerPool is this)
            throw new WorkerSelfJoinException();
    }

    // Separate invocation frame per worker preserves single deque ownership.
    private Thread makeWorker(size_t workerIndex)
    {
        return new Thread({
            auto previous = currentWorkerPool;
            auto previousIndex = currentWorkerIndex;
            currentWorkerPool = this;
            currentWorkerIndex = workerIndex;
            scope(exit)
            {
                currentWorkerPool = previous;
                currentWorkerIndex = previousIndex;
            }
            try
                workerLoop(workerIndex);
            catch (Throwable)
                lifecycleFailStop(LifecycleFailure.worker);
        });
    }

    SubmissionResult trySubmit(TaskRef task)
    {
        return _inbox.trySubmit(task);
    }

    /** Reject known-full inboxes before creating owned task records. */
    bool hasIngressCapacity()
    {
        return _inbox.hasCapacity();
    }

    bool isCurrentWorker()
    {
        return currentWorkerPool is this;
    }

    /** Run one available task when a same-pool worker is blocked on admission. */
    bool helpCurrentWorkerOnce()
    {
        if (currentWorkerPool !is this)
            return false;

        const self = currentWorkerIndex;
        size_t nextVictim = _queues.length > 1
            ? (self + 1) % _queues.length
            : self;
        return helpOne(self, nextVictim);
    }

    /**
     * A same-pool worker waits cooperatively: it executes runnable work from
     * its owner deque, ingress, or victim deques before sleeping on the target
     * result's returned condition. This keeps nested lexical scopes from
     * exhausting the entire worker set while every worker blocks in join.
     */
    void helpUntil(
        scope bool delegate() completed,
        scope void delegate() waitCompleted)
    {
        if (currentWorkerPool !is this)
        {
            waitCompleted();
            return;
        }

        const self = currentWorkerIndex;
        size_t nextVictim = _queues.length > 1
            ? (self + 1) % _queues.length
            : self;

        while (!completed())
        {
            if (helpOne(self, nextVictim))
                continue;

            if (completed())
                break;

            waitCompleted();
        }
    }

    /** Blocks until all admitted tasks have completed and all workers exit. */
    void closeAndJoin()
    {
        requireExternalController();
        closeInbox();

        // Concurrent raw-pool joins remain excluded; OwnedTaskExecutor
        // serializes external close callers before entering this method.
        joinStartedWorkers();
        if (!_inbox.isDrained())
            lifecycleFailStop(LifecycleFailure.drain);
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

    /** One bounded scheduling pass for a worker currently waiting in join. */
    private bool helpOne(size_t self, ref size_t nextVictim)
    {
        auto local = _queues[self].pop();
        if (local.found)
        {
            executeOne(local.value);
            return true;
        }

        TaskRef[IngressBatchSize] batch;
        const taken = _inbox.takeBatch(batch[]);
        if (taken != 0)
        {
            bool enqueued;
            foreach (i; 1 .. taken)
            {
                TaskRef task = batch[i];
                if (_queues[self].tryPush(task))
                    enqueued = true;
                else
                    executeOne(task);
            }

            if (enqueued)
                _inbox.announceLocalWork();

            executeOne(batch[0]);
            return true;
        }

        foreach (_; 0 .. _queues.length)
        {
            const victim = nextVictim;
            nextVictim = (nextVictim + 1) % _queues.length;
            if (victim == self)
                continue;

            auto stolen = _queues[victim].steal();
            if (!stolen.found)
                continue;

            executeOne(stolen.value);
            return true;
        }

        return false;
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

            // Scan one complete cycle of candidate indices. Skipping
            // self within N-1 slots can omit a foreign deque entirely and
            // allow parking while that deque still contains runnable work.
            foreach (_; 0 .. _queues.length)
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
    // Regression: a full unsuccessful search must attempt every foreign
    // deque exactly once before it may park. The historical N-1 candidate
    // loop could consume one slot on self and omit a foreign queue.
    enum size_t MaxWorkers = 16;
    foreach (size_t workers; 1 .. MaxWorkers + 1)
    {
        foreach (size_t self; 0 .. workers)
        {
            foreach (size_t initial; 0 .. workers)
            {
                bool[MaxWorkers] visited;
                size_t cursor = initial;
                size_t attempts;

                // Mirror the candidate cursor and self-skip semantics
                // exercised by workerLoop, including wraparound and N=1.
                foreach (_; 0 .. workers)
                {
                    const victim = cursor;
                    cursor = (cursor + 1) % workers;
                    if (victim == self)
                        continue;

                    assert(!visited[victim],
                        "foreign victim inspected more than once");
                    visited[victim] = true;
                    ++attempts;
                }

                assert(attempts == workers - 1,
                    "failed scan omitted a foreign queue");
                assert(cursor == initial,
                    "complete scan must traverse exactly one cycle");
                foreach (size_t victim; 0 .. workers)
                    assert(visited[victim] == (victim != self),
                        "foreign deque omitted before parking");
            }
        }
    }

    // Historic failure: self=2, start=1, N=4 previously examined
    // 1, self(2), 3, but never owner 0. Owner 0 must now be visited.
    size_t cursor = 1;
    bool foundVictimZero;
    foreach (_; 0 .. 4)
    {
        const victim = cursor;
        cursor = (cursor + 1) % 4;
        if (victim == 2)
            continue;
        if (victim == 0)
            foundVictimZero = true;
    }
    assert(foundVictimZero);
}

unittest
{
    // Multiple producers, bounded ingress and uneven/even worker counts.
    // These exercise the actual concurrent pop/steal/park/close lifecycle,
    // complementing the deterministic all-start-index coverage regression.
    enum size_t TaskCount = 3072;
    enum size_t ProducerCount = 4;

    foreach (workerCount; [1, 2, 3, 4, 8])
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
    // transitions exercise notification to a confirmed enrolled waiter.
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
