/**
 * M0 internal worker batch, extracted from the qualified R0.3 scheduling
 * neighborhood. This is deliberately not a public Executor API.
 *
 * Each worker is the sole owner of one containers-d deque. Other workers may
 * only steal from it. Input TaskRefs borrow stable caller-owned records; this
 * synchronous batch joins every worker before returning.
 *
 * External submission, general child-task spawning, typed results, exceptions,
 * failure during Thread.start(), worker parking and shutdown policies belong
 * to subsequent M0 issues. Idle workers yield in this first correctness slice.
 */
module concurrency.internal.worker_batch;

import concurrency.internal.task_record :
    TaskHeader,
    TaskRef,
    dispatchTask;

import concurrency.internal.work_stealing_queue :
    LocalWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicStore;

import core.thread :
    Thread;

package(concurrency) enum BatchStealMode
{
    single,
    batch
}

private enum size_t LocalCapacity = 1024;
private enum size_t StealBatchSize = 8;

private alias Queue =
    LocalWorkStealingDeque!(TaskRef, LocalCapacity);

private struct WorkerCounters
{
    size_t executed;
    size_t localPops;
    size_t stolen;
    size_t stealClaims;
    size_t failedSteals;
    size_t overflowInline;
}

package(concurrency) struct BatchStatistics
{
    size_t executed;
    size_t localPops;
    size_t stolen;
    size_t stealClaims;
    size_t failedSteals;
    size_t overflowInline;
}

private void executeOne(
    TaskRef task,
    ref WorkerCounters counters,
    shared size_t* completed)
    @safe nothrow
{
    dispatchTask(task);
    ++counters.executed;

    atomicFetchAdd!(MemoryOrder.rel)(
        *completed,
        cast(size_t) 1);
}

/**
 * Select all peers in deterministic round-robin order, skipping self.
 * The cursor is owned by the worker and never shared.
 */
private size_t nextPeer(
    ref size_t cursor,
    size_t self,
    size_t workerCount)
    @safe @nogc nothrow
{
    for (;;)
    {
        const peer = cursor;
        cursor = (cursor + 1) % workerCount;

        if (peer != self)
            return peer;
    }
}

private Thread makeWorker(
    size_t workerIndex,
    size_t workerCount,
    BatchStealMode mode,
    TaskRef[] tasks,
    Queue[] queues,
    shared size_t* ready,
    shared bool* start,
    shared size_t* completed,
    shared WorkerCounters* published)
{
    return new Thread({
        WorkerCounters counters;
        TaskRef[StealBatchSize] batch;

        size_t nextVictim =
            workerCount > 1
            ? (workerIndex + 1) % workerCount
            : workerIndex;

        atomicFetchAdd!(MemoryOrder.rel)(
            *ready,
            cast(size_t) 1);

        while (!atomicLoad!(MemoryOrder.acq)(*start))
            Thread.yield();

        // Every worker publishes only into its own deque.
        // Overflow follows the selected R0.3 execute-inline baseline.
        for (size_t i = workerIndex;
             i < tasks.length;
             i += workerCount)
        {
            TaskRef task = tasks[i];

            if (!queues[workerIndex].tryPush(task))
            {
                ++counters.overflowInline;
                executeOne(task, counters, completed);
            }
        }

        while (atomicLoad!(MemoryOrder.acq)(*completed)
            != tasks.length)
        {
            auto local = queues[workerIndex].pop();

            if (local.found)
            {
                ++counters.localPops;
                executeOne(local.value, counters, completed);
                continue;
            }

            bool foundWork;

            foreach (_; 0 .. workerCount - 1)
            {
                const victim = nextPeer(
                    nextVictim,
                    workerIndex,
                    workerCount);

                final switch (mode)
                {
                    case BatchStealMode.single:
                    {
                        auto stolen = queues[victim].steal();

                        if (!stolen.found)
                        {
                            ++counters.failedSteals;
                            break;
                        }

                        ++counters.stealClaims;
                        ++counters.stolen;
                        executeOne(stolen.value, counters, completed);
                        foundWork = true;
                        break;
                    }

                    case BatchStealMode.batch:
                    {
                        const count = queues[victim].stealBatch(batch[]);

                        if (count == 0)
                        {
                            ++counters.failedSteals;
                            break;
                        }

                        ++counters.stealClaims;
                        counters.stolen += count;

                        executeOne(batch[0], counters, completed);

                        // A thief becomes owner of its own local deque.
                        // Never push into the victim's deque.
                        foreach (task; batch[1 .. count])
                        {
                            if (!queues[workerIndex].tryPush(task))
                            {
                                ++counters.overflowInline;
                                executeOne(task, counters, completed);
                            }
                        }

                        foundWork = true;
                        break;
                    }
                }

                if (foundWork)
                    break;
            }

            if (!foundWork)
                Thread.yield();
        }

        // Published only once, read after Thread.join() by the caller.
        published[workerIndex] = cast(shared) counters;
    });
}

/**
 * Internal synchronous scheduling fixture.
 *
 * Exactly one worker owns each deque. Records and TaskRef storage are owned by
 * the caller; all associated records must remain stable and live until this
 * function returns. The input is not modified. This is a system-level
 * boundary until M1 formalizes safe borrowed versus owned task submission.
 *
 * All accepted tasks must have nonthrowing, @nogc execution thunks; later
 * typed-task adapters will catch and record user exceptions in their thunk.
 */
package(concurrency) BatchStatistics runSeededBatch(
    TaskRef[] tasks,
    size_t workerCount,
    BatchStealMode mode = BatchStealMode.single)
{
    if (workerCount == 0)
        throw new Exception("workerCount must be positive");

    if (tasks.length == 0)
        return BatchStatistics.init;

    auto queues = new Queue[workerCount];
    auto threads = new Thread[workerCount];

    shared size_t ready;
    shared bool start;
    shared size_t completed;

    auto published = new shared WorkerCounters[workerCount];

    // Worker startup currently assumes Thread.start succeeds for every
    // worker; startup-failure cleanup is part of M0 lifecycle issue #12.
    foreach (index; 0 .. workerCount)
    {
        threads[index] = makeWorker(
            index,
            workerCount,
            mode,
            tasks,
            queues,
            &ready,
            &start,
            &completed,
            published.ptr);

        threads[index].start();
    }

    while (atomicLoad!(MemoryOrder.acq)(ready) != workerCount)
        Thread.yield();

    atomicStore!(MemoryOrder.rel)(start, true);

    foreach (thread; threads)
        thread.join();

    BatchStatistics result;

    foreach (index; 0 .. workerCount)
    {
        const counters = cast(WorkerCounters) published[index];

        result.executed += counters.executed;
        result.localPops += counters.localPops;
        result.stolen += counters.stolen;
        result.stealClaims += counters.stealClaims;
        result.failedSteals += counters.failedSteals;
        result.overflowInline += counters.overflowInline;
    }

    if (result.executed != tasks.length
        || atomicLoad!(MemoryOrder.acq)(completed) != tasks.length)
    {
        throw new Exception("worker batch completion mismatch");
    }

    return result;
}

version (unittest)
{
    private struct CountingRecord
    {
        TaskHeader header; // Must be first for the concrete thunk.
        size_t id;
        shared uint executions;
    }

    private void executeCounting(
        shared(TaskHeader)* header)
        @trusted @nogc nothrow
    {
        auto record = cast(shared(CountingRecord)*) header;

        assert(atomicLoad!(MemoryOrder.raw)(record.id) != 0);
        atomicFetchAdd!(MemoryOrder.rel)(record.executions, 1u);
    }

    private void qualifyBatch(
        size_t count,
        size_t workerCount,
        BatchStealMode mode)
    {
        auto records = new shared CountingRecord[count];
        auto tasks = new TaskRef[count];

        foreach (i; 0 .. count)
        {
            records[i].header.execute = &executeCounting;
            records[i].id = i + 1;
            records[i].executions = 0;
            tasks[i] = TaskRef(&records[i].header);
        }

        const stats = runSeededBatch(tasks, workerCount, mode);
        assert(stats.executed == count);
        // Stolen tasks may subsequently be queued and popped locally,
        // so transport counters are not an exclusive work partition.
        assert(stats.stolen <= count);
        assert(stats.overflowInline <= count);

        foreach (i; 0 .. count)
        {
            assert(atomicLoad!(MemoryOrder.acq)(
                records[i].executions) == 1u);
        }
    }
}

unittest
{
    // Small queues, batches and tasks that overflow the bounded deque.
    foreach (mode; [BatchStealMode.single, BatchStealMode.batch])
    {
        foreach (workers; [1, 2, 4])
        {
            qualifyBatch(1, workers, mode);
            qualifyBatch(73, workers, mode);
            qualifyBatch(4097, workers, mode);
        }
    }

    assert(runSeededBatch(
        TaskRef[].init,
        1).executed == 0);
}
