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

/*
 * Production shares in eighths:
 *
 * worker 0: 3/8
 * worker 1: 3/8
 * worker 2: 1/8
 * worker 3: 1/8
 *
 * Every worker is a producer, but workers 2 and 3 finish production earlier
 * and therefore become consumers/thieves while workers 0 and 1 are still
 * producing.
 */
enum size_t ShareUnit = Tasks / 8;

static assert(
    Tasks % 8 == 0);

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
    ulong produced;
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


private size_t productionBegin(
    size_t workerIndex)
    @safe @nogc nothrow
{
    final switch (workerIndex)
    {
        case 0:
            return 0;

        case 1:
            return 3 * ShareUnit;

        case 2:
            return 6 * ShareUnit;

        case 3:
            return 7 * ShareUnit;
    }
}

private size_t productionCount(
    size_t workerIndex)
    @safe @nogc nothrow
{
    final switch (workerIndex)
    {
        case 0:
        case 1:
            return 3 * ShareUnit;

        case 2:
        case 3:
            return ShareUnit;
    }
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
    shared size_t* producersDone,
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
         * Each worker produces a disjoint range.
         *
         * The deliberately uneven 3:3:1:1 split creates a realistic
         * transition where workers 2 and 3 finish production first and can
         * steal from workers 0 and 1 while those are still producing.
         */
        const begin =
            productionBegin(
                workerIndex);

        const count =
            productionCount(
                workerIndex);

        foreach (offset; 0 .. count)
        {
            const task =
                TaskRef(
                    cast(ulong)
                        (begin + offset) +
                    1);

            ++stats.produced;

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

        atomicFetchAdd!(
            MemoryOrder.rel)(
                *producersDone,
                1);

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
                        *producersDone) ==
                    Workers &&
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
        "R0.1 P13b distributed-production scheduler");

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
    shared size_t producersDone;

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
                &producersDone,
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

    /*
     * Research-only observability required by P13.
     *
     * The counter is module-global across P08e queue instances, so resetting
     * through one queue before scheduler start and reading it after all
     * workers join gives the scheduler-wide owner-busy retry count.
     */
    queues[0]
        .researchResetOwnerBusyRetries();

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (thread; threads)
        thread.join();

    sw.stop();

    const ownerBusyRetries =
        queues[0]
        .researchOwnerBusyRetriesSnapshot();

    const elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    ulong totalProduced;
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
            "worker=%s produced=%s executed=%s local=%s stolen=%s "
            ~ "claims=%s failedSteals=%s overflowInline=%s",
            worker,
            stats.produced,
            stats.executed,
            stats.localPops,
            stats.stolenTasks,
            stats.batchClaims,
            stats.failedSteals,
            stats.overflowInline);

        totalProduced +=
            stats.produced;

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
        totalProduced !=
        Tasks)
    {
        throw new Exception(
            "production count mismatch");
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
        "produced=%s executed=%s localPops=%s stolenTasks=%s",
        totalProduced,
        totalExecuted,
        totalLocalPops,
        totalStolen);

    writefln(
        "batchClaims=%s stolen/claim=%.3f",
        totalClaims,
        stolenPerClaim);

    writefln(
        "failedSteals=%s overflowInline=%s ownerBusyRetries=%s",
        totalFailedSteals,
        totalOverflowInline,
        ownerBusyRetries);

    writeln(
        "accounting/checksum PASS");

    writeln(
        "R0.1 P13b PASS");
}
