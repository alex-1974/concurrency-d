module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicOp,
    atomicStore;

import core.thread :
    Thread;

version (linux)
{
    import core.sys.linux.sched :
        CPU_SET,
        cpu_set_t,
        sched_getcpu,
        sched_setaffinity;
}

import std.datetime.stopwatch :
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t Workers = 4;
enum size_t LogSize = 10;
enum size_t Capacity = size_t(1) << LogSize;
enum size_t BatchSize = 8;

enum size_t Tasks = 1_048_576;
enum size_t WorkRounds = 16;

enum size_t ProducerWorker = 0;

struct TaskRef
{
    ulong value;
}

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        TaskRef,
        LogSize);

struct WorkerStats
{
    ulong executed;

    ulong localPops;
    ulong stolenTasks;
    ulong batchClaims;

    ulong failedSteals;
    ulong overflowInline;

    ulong valueSum;
    ulong valueXor;
    ulong workChecksum;
}

private void pinCurrentThread(
    size_t cpu)
{
    version (linux)
    {
        cpu_set_t mask;

        CPU_SET(
            cpu,
            &mask);

        if (
            sched_setaffinity(
                0,
                cpu_set_t.sizeof,
                &mask) != 0)
        {
            throw new Exception(
                "sched_setaffinity failed");
        }

        const actual =
            sched_getcpu();

        if (
            actual < 0 ||
            cast(size_t) actual != cpu)
        {
            throw new Exception(
                "affinity verification failed");
        }
    }
    else
    {
        throw new Exception(
            "Linux affinity required");
    }
}

private ulong doWork(
    ulong value)
    @safe @nogc nothrow
{
    ulong x =
        value +
        0x9e3779b97f4a7c15UL;

    foreach (i; 0 .. WorkRounds)
    {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;

        x *=
            0x2545f4914f6cdd1dUL;

        x +=
            cast(ulong) i +
            0x9e3779b97f4a7c15UL;
    }

    return x;
}

private void executeTask(
    TaskRef task,
    ref WorkerStats stats,
    shared ulong* completed)
    @safe @nogc nothrow
{
    ++stats.executed;

    stats.valueSum +=
        task.value;

    stats.valueXor ^=
        task.value;

    stats.workChecksum ^=
        doWork(
            task.value);

    atomicFetchAdd!(
        MemoryOrder.rel)(
            *completed,
            1);
}

private ulong expectedWorkChecksum()
{
    ulong result;

    foreach (i; 0 .. Tasks)
    {
        result ^=
            doWork(
                cast(ulong) i + 1);
    }

    return result;
}

private Thread makeWorker(
    size_t workerIndex,
    Queue[] queues,
    shared size_t* readyCount,
    shared bool* start,
    shared bool* producerDone,
    shared ulong* completed,
    shared WorkerStats* publishedStats)
{
    return new Thread({
        /*
         * CPUs 0..3 are distinct physical cores on the qualification host.
         */
        pinCurrentThread(
            workerIndex);

        WorkerStats stats;

        TaskRef[BatchSize] batch;

        size_t nextVictim =
            (workerIndex + 1) %
            Workers;

        atomicFetchAdd!(
            MemoryOrder.rel)(
                *readyCount,
                1);

        while (
            !atomicLoad!(
                MemoryOrder.acq)(
                    *start))
        {
            Thread.yield();
        }

        /*
         * Deliberately skew production to worker 0.
         *
         * This creates steal pressure and exercises the selected P12
         * execute-inline fallback without requiring a public spawn API.
         */
        if (
            workerIndex ==
            ProducerWorker)
        {
            foreach (i; 0 .. Tasks)
            {
                const task =
                    TaskRef(
                        cast(ulong) i + 1);

                if (
                    queues[
                        workerIndex]
                    .tryPush(task))
                {
                    continue;
                }

                ++stats.overflowInline;

                executeTask(
                    task,
                    stats,
                    completed);
            }

            atomicStore!(
                MemoryOrder.rel)(
                    *producerDone,
                    true);
        }

        for (;;)
        {
            /*
             * Work-first local owner path.
             */
            const local =
                queues[
                    workerIndex]
                .pop();

            if (local.found)
            {
                ++stats.localPops;

                executeTask(
                    local.value,
                    stats,
                    completed);

                continue;
            }

            bool gotWork;

            /*
             * Round-robin victims. The worker never steals from itself.
             */
            foreach (_; 0 .. Workers - 1)
            {
                const victim =
                    nextVictim;

                nextVictim =
                    (nextVictim + 1) %
                    Workers;

                if (
                    victim ==
                    workerIndex)
                {
                    continue;
                }

                const taken =
                    queues[victim]
                    .stealBatch(
                        batch[]);

                if (taken == 0)
                {
                    ++stats.failedSteals;
                    continue;
                }

                ++stats.batchClaims;
                stats.stolenTasks +=
                    taken;

                /*
                 * Execute one stolen task immediately.
                 *
                 * Transfer the rest to this worker's own deque. This makes
                 * stolen work local and exercises owner-side push/pop on
                 * every worker rather than keeping workers permanently as
                 * thieves.
                 */
                executeTask(
                    batch[0],
                    stats,
                    completed);

                foreach (
                    task;
                    batch[1 .. taken])
                {
                    if (
                        queues[
                            workerIndex]
                        .tryPush(task))
                    {
                        continue;
                    }

                    /*
                     * Same P12 policy for a full receiving local queue:
                     * execute the runnable task inline.
                     */
                    ++stats.overflowInline;

                    executeTask(
                        task,
                        stats,
                        completed);
                }

                gotWork = true;
                break;
            }

            if (gotWork)
                continue;

            if (
                atomicLoad!(
                    MemoryOrder.acq)(
                        *producerDone) &&
                atomicLoad!(
                    MemoryOrder.acq)(
                        *completed) ==
                    Tasks)
            {
                break;
            }

            Thread.yield();
        }

        /*
         * Each worker owns exactly one stats slot.
         * Publication happens after all local writes.
         */
        publishedStats[
            workerIndex] =
            cast(shared)
                stats;
    });
}

void main()
{
    writeln(
        "R0.1 P13a minimal scheduler");

    writefln(
        "workers=%s capacity=%s batch=%s tasks=%s work=%s",
        Workers,
        Capacity,
        BatchSize,
        Tasks,
        WorkRounds);

    auto queues =
        new Queue[Workers];

    shared size_t readyCount;
    shared bool start;
    shared bool producerDone;

    shared ulong completed;

    shared WorkerStats[Workers]
        publishedStats;

    Thread[Workers] threads;

    foreach (worker; 0 .. Workers)
    {
        threads[worker] =
            makeWorker(
                worker,
                queues,
                &readyCount,
                &start,
                &producerDone,
                &completed,
                publishedStats.ptr);

        threads[worker].start();
    }

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                readyCount) !=
        Workers)
    {
        Thread.yield();
    }

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (thread; threads)
        thread.join();

    sw.stop();

    const elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    ulong totalExecuted;

    ulong totalLocalPops;
    ulong totalStolen;
    ulong totalClaims;

    ulong totalFailedSteals;
    ulong totalOverflowInline;

    ulong valueSum;
    ulong valueXor;
    ulong workChecksum;

    foreach (worker; 0 .. Workers)
    {
        const stats =
            cast(WorkerStats)
                publishedStats[
                    worker];

        writefln(
            "worker=%s executed=%s local=%s stolen=%s "
            ~ "claims=%s failedSteals=%s overflowInline=%s",
            worker,
            stats.executed,
            stats.localPops,
            stats.stolenTasks,
            stats.batchClaims,
            stats.failedSteals,
            stats.overflowInline);

        totalExecuted +=
            stats.executed;

        totalLocalPops +=
            stats.localPops;

        totalStolen +=
            stats.stolenTasks;

        totalClaims +=
            stats.batchClaims;

        totalFailedSteals +=
            stats.failedSteals;

        totalOverflowInline +=
            stats.overflowInline;

        valueSum +=
            stats.valueSum;

        valueXor ^=
            stats.valueXor;

        workChecksum ^=
            stats.workChecksum;
    }

    const n =
        cast(ulong) Tasks;

    const expectedSum =
        n * (n + 1) / 2;

    ulong expectedXor;

    final switch (n & 3)
    {
        case 0:
            expectedXor = n;
            break;

        case 1:
            expectedXor = 1;
            break;

        case 2:
            expectedXor = n + 1;
            break;

        case 3:
            expectedXor = 0;
            break;
    }

    if (
        totalExecuted !=
        Tasks)
    {
        throw new Exception(
            "execution count mismatch");
    }

    if (
        atomicLoad!(
            MemoryOrder.acq)(
                completed) !=
        Tasks)
    {
        throw new Exception(
            "completed counter mismatch");
    }

    if (
        valueSum !=
        expectedSum)
    {
        throw new Exception(
            "value sum mismatch");
    }

    if (
        valueXor !=
        expectedXor)
    {
        throw new Exception(
            "value xor mismatch");
    }

    if (
        workChecksum !=
        expectedWorkChecksum())
    {
        throw new Exception(
            "work checksum mismatch");
    }

    foreach (worker; 0 .. Workers)
    {
        if (
            !queues[
                worker]
            .emptySnapshot())
        {
            throw new Exception(
                "worker queue not empty");
        }
    }

    const double nsPerTask =
        cast(double)
            elapsedNs /
            Tasks;

    const double stolenPerClaim =
        totalClaims != 0
        ? cast(double)
            totalStolen /
            totalClaims
        : 0.0;

    writefln(
        "elapsed=%s ns ns/task=%.3f",
        elapsedNs,
        nsPerTask);

    writefln(
        "executed=%s localPops=%s stolenTasks=%s",
        totalExecuted,
        totalLocalPops,
        totalStolen);

    writefln(
        "batchClaims=%s stolen/claim=%.3f",
        totalClaims,
        stolenPerClaim);

    writefln(
        "failedSteals=%s overflowInline=%s",
        totalFailedSteals,
        totalOverflowInline);

    writeln(
        "accounting/checksum PASS");

    writeln(
        "R0.1 P13a PASS");
}
