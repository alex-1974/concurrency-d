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

import std.algorithm.sorting :
    sort;

import std.datetime.stopwatch :
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t MaxWorkers = 4;
enum size_t LogSize = 10;
enum size_t Capacity = size_t(1) << LogSize;
enum size_t BatchSize = 8;

enum size_t Tasks = 262_144;

enum size_t Warmups = 2;
enum size_t Samples = 9;

enum StealMode
{
    single,
    batch
}

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
    ulong stealClaims;
    ulong failedSteals;

    ulong overflowInline;

    ulong valueSum;
    ulong valueXor;
    ulong workChecksum;
}

struct RunResult
{
    ulong elapsedNs;

    ulong executed;
    ulong localPops;

    ulong stolenTasks;
    ulong stealClaims;
    ulong failedSteals;

    ulong overflowInline;
    ulong ownerBusyRetries;

    ulong minWorkerExecuted;
    ulong maxWorkerExecuted;
}

struct Distribution
{
    double median;
    double p10;
    double p90;
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
    ulong value,
    size_t rounds)
    @safe @nogc nothrow
{
    ulong x =
        value +
        0x9e3779b97f4a7c15UL;

    foreach (i; 0 .. rounds)
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

private ulong expectedWorkChecksum(
    size_t rounds)
{
    ulong result;

    foreach (i; 0 .. Tasks)
    {
        result ^=
            doWork(
                cast(ulong) i + 1,
                rounds);
    }

    return result;
}

private void executeTask(
    TaskRef task,
    size_t rounds,
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
            task.value,
            rounds);

    atomicFetchAdd!(
        MemoryOrder.rel)(
            *completed,
            1);
}

private Thread makeWorker(
    size_t workerIndex,
    size_t workerCount,
    StealMode mode,
    size_t rounds,
    Queue[] queues,
    shared size_t* readyCount,
    shared bool* start,
    shared bool* producerDone,
    shared ulong* completed,
    shared WorkerStats* publishedStats)
{
    return new Thread({
        pinCurrentThread(
            workerIndex);

        WorkerStats stats;

        TaskRef[BatchSize] batch;

        size_t nextVictim =
            workerCount > 1
            ? (workerIndex + 1) %
                workerCount
            : workerIndex;

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
         * One deterministic producer.
         *
         * Full local queue follows the selected P12 scheduler policy:
         * execute the runnable task inline.
         */
        if (workerIndex == 0)
        {
            foreach (i; 0 .. Tasks)
            {
                const task =
                    TaskRef(
                        cast(ulong) i + 1);

                if (
                    queues[0]
                    .tryPush(task))
                {
                    continue;
                }

                ++stats.overflowInline;

                executeTask(
                    task,
                    rounds,
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
            const local =
                queues[
                    workerIndex]
                .pop();

            if (local.found)
            {
                ++stats.localPops;

                executeTask(
                    local.value,
                    rounds,
                    stats,
                    completed);

                continue;
            }

            bool foundWork;

            if (workerCount > 1)
            {
                foreach (
                    _;
                    0 ..
                    workerCount - 1)
                {
                    const victim =
                        nextVictim;

                    nextVictim =
                        (nextVictim + 1) %
                        workerCount;

                    if (
                        victim ==
                        workerIndex)
                    {
                        continue;
                    }

                    final switch (mode)
                    {
                        case StealMode.single:
                        {
                            const stolen =
                                queues[victim]
                                .steal();

                            if (!stolen.found)
                            {
                                ++stats.failedSteals;
                                break;
                            }

                            ++stats.stealClaims;
                            ++stats.stolenTasks;

                            executeTask(
                                stolen.value,
                                rounds,
                                stats,
                                completed);

                            foundWork = true;
                            break;
                        }

                        case StealMode.batch:
                        {
                            const taken =
                                queues[victim]
                                .stealBatch(
                                    batch[]);

                            if (taken == 0)
                            {
                                ++stats.failedSteals;
                                break;
                            }

                            ++stats.stealClaims;
                            stats.stolenTasks +=
                                taken;

                            /*
                             * Execute one immediately and transfer the rest
                             * into the thief's owner-local deque.
                             */
                            executeTask(
                                batch[0],
                                rounds,
                                stats,
                                completed);

                            foreach (
                                task;
                                batch[
                                    1 ..
                                    taken])
                            {
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
                                    rounds,
                                    stats,
                                    completed);
                            }

                            foundWork = true;
                            break;
                        }
                    }

                    if (foundWork)
                        break;
                }
            }

            if (foundWork)
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

        publishedStats[
            workerIndex] =
            cast(shared)
                stats;
    });
}

private RunResult run(
    size_t workerCount,
    StealMode mode,
    size_t rounds)
{
    auto queues =
        new Queue[MaxWorkers];

    shared size_t readyCount;
    shared bool start;
    shared bool producerDone;
    shared ulong completed;

    shared WorkerStats[MaxWorkers]
        publishedStats;

    Thread[MaxWorkers] threads;

    foreach (worker; 0 .. workerCount)
    {
        threads[worker] =
            makeWorker(
                worker,
                workerCount,
                mode,
                rounds,
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
        workerCount)
    {
        Thread.yield();
    }

    queues[0]
        .researchResetOwnerBusyRetries();

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (i; 0 .. workerCount)
        threads[i].join();

    sw.stop();

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.ownerBusyRetries =
        queues[0]
        .researchOwnerBusyRetriesSnapshot();

    ulong valueSum;
    ulong valueXor;
    ulong workChecksum;

    result.minWorkerExecuted =
        ulong.max;

    foreach (worker; 0 .. workerCount)
    {
        const stats =
            cast(WorkerStats)
                publishedStats[
                    worker];

        result.executed +=
            stats.executed;

        result.localPops +=
            stats.localPops;

        result.stolenTasks +=
            stats.stolenTasks;

        result.stealClaims +=
            stats.stealClaims;

        result.failedSteals +=
            stats.failedSteals;

        result.overflowInline +=
            stats.overflowInline;

        valueSum +=
            stats.valueSum;

        valueXor ^=
            stats.valueXor;

        workChecksum ^=
            stats.workChecksum;

        if (
            stats.executed <
            result.minWorkerExecuted)
        {
            result.minWorkerExecuted =
                stats.executed;
        }

        if (
            stats.executed >
            result.maxWorkerExecuted)
        {
            result.maxWorkerExecuted =
                stats.executed;
        }
    }

    if (
        result.executed !=
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
            "completed count mismatch");
    }

    const n =
        cast(ulong) Tasks;

    const expectedSum =
        n * (n + 1) / 2;

    if (
        valueSum !=
        expectedSum)
    {
        throw new Exception(
            "value sum mismatch");
    }

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
        valueXor !=
        expectedXor)
    {
        throw new Exception(
            "value xor mismatch");
    }

    if (
        workChecksum !=
        expectedWorkChecksum(
            rounds))
    {
        throw new Exception(
            "work checksum mismatch");
    }

    foreach (worker; 0 .. workerCount)
    {
        if (
            !queues[
                worker]
            .emptySnapshot())
        {
            throw new Exception(
                "queue not empty");
        }
    }

    return result;
}

private Distribution distribution(
    ulong[] values)
{
    values.sort();

    return Distribution(
        cast(double)
            values[
                values.length / 2],
        cast(double)
            values[
                (values.length - 1) *
                10 / 100],
        cast(double)
            values[
                (values.length - 1) *
                90 / 100]);
}

private string modeName(
    StealMode mode)
{
    final switch (mode)
    {
        case StealMode.single:
            return "single";

        case StealMode.batch:
            return "batch";
    }
}

private void benchmark(
    size_t workerCount,
    StealMode mode,
    size_t rounds)
{
    foreach (_; 0 .. Warmups)
    {
        run(
            workerCount,
            mode,
            rounds);
    }

    ulong[Samples] elapsed;

    ulong totalExecuted;
    ulong totalLocalPops;

    ulong totalStolen;
    ulong totalClaims;
    ulong totalFailedSteals;

    ulong totalOverflow;
    ulong totalBusyRetries;

    ulong minWorkerExecuted =
        ulong.max;

    ulong maxWorkerExecuted;

    foreach (sample; 0 .. Samples)
    {
        const result =
            run(
                workerCount,
                mode,
                rounds);

        elapsed[sample] =
            result.elapsedNs;

        totalExecuted +=
            result.executed;

        totalLocalPops +=
            result.localPops;

        totalStolen +=
            result.stolenTasks;

        totalClaims +=
            result.stealClaims;

        totalFailedSteals +=
            result.failedSteals;

        totalOverflow +=
            result.overflowInline;

        totalBusyRetries +=
            result.ownerBusyRetries;

        if (
            result.minWorkerExecuted <
            minWorkerExecuted)
        {
            minWorkerExecuted =
                result.minWorkerExecuted;
        }

        if (
            result.maxWorkerExecuted >
            maxWorkerExecuted)
        {
            maxWorkerExecuted =
                result.maxWorkerExecuted;
        }
    }

    const d =
        distribution(
            elapsed[]);

    const double medianNsPerTask =
        d.median /
        Tasks;

    const double p10NsPerTask =
        d.p10 /
        Tasks;

    const double p90NsPerTask =
        d.p90 /
        Tasks;

    const double tasksPerSecond =
        cast(double)
            Tasks *
        1_000_000_000.0 /
        d.median;

    const double stolenPerClaim =
        totalClaims != 0
        ? cast(double)
            totalStolen /
            totalClaims
        : 0.0;

    const double overflowPerTask =
        cast(double)
            totalOverflow /
        (Tasks * Samples);

    const double localRatio =
        cast(double)
            totalLocalPops /
        totalExecuted;

    const double stealTransferRatio =
        cast(double)
            totalStolen /
        totalExecuted;

    writefln(
        "%-6s workers=%s work=%2s "
        ~ "median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f "
        ~ "tasks/s=%10.1f",
        modeName(mode),
        workerCount,
        rounds,
        medianNsPerTask,
        p10NsPerTask,
        p90NsPerTask,
        tasksPerSecond);

    writefln(
        "       localRatio=%.3f "
        ~ "stealTransferRatio=%.3f "
        ~ "claims=%s stolen/claim=%.3f",
        localRatio,
        stealTransferRatio,
        totalClaims,
        stolenPerClaim);

    writefln(
        "       failedSteals=%s "
        ~ "overflow/task=%.6f "
        ~ "ownerBusyRetries=%s",
        totalFailedSteals,
        overflowPerTask,
        totalBusyRetries);

    writefln(
        "       workerExecutedRange=%s..%s",
        minWorkerExecuted,
        maxWorkerExecuted);
}

void main()
{
    writeln(
        "R0.1 P14a flat granularity scaling");

    writefln(
        "tasks=%s capacity=%s batch=%s "
        ~ "warmups=%s samples=%s",
        Tasks,
        Capacity,
        BatchSize,
        Warmups,
        Samples);

    foreach (
        rounds;
        [0, 16, 64])
    {
        writeln();

        writefln(
            "=== work=%s ===",
            rounds);

        foreach (
            workers;
            [1, 2, 4])
        {
            benchmark(
                workers,
                StealMode.single,
                rounds);

            benchmark(
                workers,
                StealMode.batch,
                rounds);
        }
    }

    writeln();

    writeln(
        "R0.1 P14a PASS");
}
