module app;

import containers :
    WorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
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

enum size_t Capacity = 1024;
enum size_t BatchSize = 8;

enum uint MaxDepth = 18;

enum ulong TotalTasks =
    (1UL << (MaxDepth + 1)) - 1;

enum size_t WorkRounds = 16;

enum size_t Warmups = 2;
enum size_t Samples = 9;

enum StealMode
{
    single,
    batch
}

struct TaskHeader
{
    alias ExecuteFn =
        ulong function(
            shared(TaskHeader)*)
            @safe @nogc nothrow;

    ExecuteFn execute;
}

alias ExecuteFn =
    TaskHeader.ExecuteFn;

struct TaskRecord
{
    TaskHeader header;
    ulong id;
    uint depth;
}

struct TaskRef
{
    shared(TaskHeader)* ptr;
}

static assert(
    TaskHeader.sizeof == 8);

static assert(
    TaskRef.sizeof == 8);

alias Queue =
    WorkStealingDeque!(
        TaskRef,
        Capacity);

struct WorkerStats
{
    ulong executed;
    ulong localPops;

    ulong stolenTasks;
    ulong stealClaims;
    ulong failedSteals;

    ulong spawned;
    ulong overflowInline;
    ulong directContinuations;

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

    ulong spawned;
    ulong overflowInline;
    ulong directContinuations;

    ulong minWorkerExecuted;
    ulong maxWorkerExecuted;
}

struct Distribution
{
    double median;
    double p10;
    double p90;
}

private TaskRef makeTask(
    ulong id,
    shared TaskRecord* records)
    @trusted @nogc nothrow
{
    return TaskRef(
        &records[
            cast(size_t) id - 1]
        .header);
}

private TaskRecord* taskRecord(
    TaskRef task)
    @trusted @nogc nothrow
{
    return
        cast(TaskRecord*)
            task.ptr;
}

private ulong taskId(
    TaskRef task)
    @safe @nogc nothrow
{
    return atomicLoad!(
        MemoryOrder.raw)(
            taskRecord(task)
            .id);
}

private uint taskDepth(
    TaskRef task)
    @safe @nogc nothrow
{
    return atomicLoad!(
        MemoryOrder.raw)(
            taskRecord(task)
            .depth);
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

private ulong executeRecord(
    shared(TaskHeader)* header)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared(TaskRecord)*)
            header;

    return doWork(
        atomicLoad!(
            MemoryOrder.raw)(
                record.id));
}

private ulong executeWork(
    TaskRef task)
    @safe @nogc nothrow
{
    const execute =
        atomicLoad!(
            MemoryOrder.raw)(
                task.ptr.execute);

    return execute(
        task.ptr);
}

private ulong expectedWorkChecksum()
{
    ulong result;

    foreach (id; 1UL .. TotalTasks + 1)
    {
        result ^=
            doWork(id);
    }

    return result;
}

/*
 * Cold overflow path.
 *
 * This preserves the original P12 execute-inline semantics exactly, including
 * recursive descendant production, but keeps recursion out of the normal
 * executeTask hot path.
 */
private void executeOverflowInline(
    TaskRef task,
    size_t workerIndex,
    Queue[] queues,
    ref WorkerStats stats,
    shared long* outstanding,
    shared ulong* completed,
    shared TaskRecord* records)
{
    const id =
        taskId(task);

    const depth =
        taskDepth(task);

    ++stats.executed;

    stats.valueSum +=
        id;

    stats.valueXor ^=
        id;

    stats.workChecksum ^=
        executeWork(task);

    if (depth < MaxDepth)
    {
        atomicFetchAdd!(
            MemoryOrder.rel)(
                *outstanding,
                cast(long) 2);

        stats.spawned += 2;

        auto left =
            makeTask(
                id << 1,
                records);

        auto right =
            makeTask(
                (id << 1) | 1,
                records);

        if (
            !queues[
                workerIndex]
            .tryPush(left))
        {
            ++stats.overflowInline;

            executeOverflowInline(
                left,
                workerIndex,
                queues,
                stats,
                outstanding,
                completed,
                records);
        }

        if (
            !queues[
                workerIndex]
            .tryPush(right))
        {
            ++stats.overflowInline;

            executeOverflowInline(
                right,
                workerIndex,
                queues,
                stats,
                outstanding,
                completed,
                records);
        }
    }

    atomicFetchAdd!(
        MemoryOrder.rel)(
            *completed,
            1);

    atomicFetchAdd!(
        MemoryOrder.rel)(
            *outstanding,
            cast(long) -1);
}

/*
 * Normal task hot path.
 *
 * This function itself is deliberately non-recursive. Overflow retains the
 * selected P12 execute-inline semantics through executeOverflowInline.
 */
private void executeTask(
    TaskRef initialTask,
    size_t workerIndex,
    size_t workerCount,
    Queue[] queues,
    ref WorkerStats stats,
    shared long* outstanding,
    shared ulong* completed,
    shared TaskRecord* records)
{
    TaskRef task =
        initialTask;

    for (;;)
    {
        const id =
            taskId(task);

        const depth =
            taskDepth(task);

        ++stats.executed;

        stats.valueSum +=
            id;

        stats.valueXor ^=
            id;

        stats.workChecksum ^=
            executeWork(task);

        TaskRef direct;
        bool hasDirect;

        if (depth < MaxDepth)
        {
            atomicFetchAdd!(
                MemoryOrder.rel)(
                    *outstanding,
                    cast(long) 2);

            stats.spawned += 2;

            auto left =
                makeTask(
                    id << 1,
                    records);

            auto right =
                makeTask(
                    (id << 1) | 1,
                    records);

            const available =
                atomicLoad!(
                    MemoryOrder.raw)(
                        *outstanding);

            if (
                available >=
                cast(long) workerCount)
            {
                /*
                 * Enough scheduler-visible work exists to keep one child as
                 * this worker's continuation.
                 */
                if (
                    !queues[
                        workerIndex]
                    .tryPush(right))
                {
                    ++stats.overflowInline;

                    executeOverflowInline(
                        right,
                        workerIndex,
                        queues,
                        stats,
                        outstanding,
                        completed,
                        records);
                }

                direct =
                    left;

                hasDirect =
                    true;

                ++stats.directContinuations;
            }
            else
            {
                /*
                 * Seed parallelism first: expose both children until the
                 * outstanding set can cover the worker team.
                 */
                if (
                    !queues[
                        workerIndex]
                    .tryPush(left))
                {
                    ++stats.overflowInline;

                    executeOverflowInline(
                        left,
                        workerIndex,
                        queues,
                        stats,
                        outstanding,
                        completed,
                        records);
                }

                if (
                    !queues[
                        workerIndex]
                    .tryPush(right))
                {
                    ++stats.overflowInline;

                    executeOverflowInline(
                        right,
                        workerIndex,
                        queues,
                        stats,
                        outstanding,
                        completed,
                        records);
                }
            }
        }

        atomicFetchAdd!(
            MemoryOrder.rel)(
                *completed,
                1);

        atomicFetchAdd!(
            MemoryOrder.rel)(
                *outstanding,
                cast(long) -1);

        if (!hasDirect)
            break;

        task =
            direct;
    }
}

private Thread makeWorker(
    size_t workerIndex,
    size_t workerCount,
    StealMode mode,
    Queue[] queues,
    shared size_t* readyCount,
    shared bool* start,
    shared bool* rootSeeded,
    shared long* outstanding,
    shared ulong* completed,
    shared WorkerStats* publishedStats,
    shared TaskRecord* records)
{
    return new Thread({
        pinCurrentThread(
            workerIndex);

        WorkerStats stats;

        TaskRef[BatchSize]
            batch;

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
         * Worker 0 is the owner that seeds the root.
         */
        if (workerIndex == 0)
        {
            atomicFetchAdd!(
                MemoryOrder.rel)(
                    *outstanding,
                    cast(long) 1);

            auto root =
                makeTask(
                    1,
                    records);

            if (
                !queues[0]
                .tryPush(root))
            {
                throw new Exception(
                    "root push failed");
            }

            atomicStore!(
                MemoryOrder.rel)(
                    *rootSeeded,
                    true);
        }

        for (;;)
        {
            auto local =
                queues[
                    workerIndex]
                .pop();

            if (local.found)
            {
                ++stats.localPops;

                executeTask(
                    local.value,
                    workerIndex,
                    workerCount,
                    queues,
                    stats,
                    outstanding,
                    completed,
                    records);

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
                            auto stolen =
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
                                workerIndex,
                                workerCount,
                                queues,
                                stats,
                                outstanding,
                                completed,
                                records);

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
                             * Execute one immediately.
                             *
                             * Move the remaining stolen tasks into this
                             * worker's owner-local deque. If that local deque
                             * is full, execute them inline according to P12.
                             */
                            executeTask(
                                batch[0],
                                workerIndex,
                                workerCount,
                                queues,
                                stats,
                                outstanding,
                                completed,
                                records);

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
                                    workerIndex,
                                    workerCount,
                                    queues,
                                    stats,
                                    outstanding,
                                    completed,
                                    records);
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
                        *rootSeeded) &&
                atomicLoad!(
                    MemoryOrder.acq)(
                        *outstanding) == 0)
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
    StealMode mode)
{
    auto records =
        new shared TaskRecord[
            cast(size_t) TotalTasks];

    uint depth;
    ulong nextDepthStart = 2;

    foreach (index; 0 .. cast(size_t) TotalTasks)
    {
        const id =
            cast(ulong) index + 1;

        if (id == nextDepthStart)
        {
            ++depth;
            nextDepthStart <<= 1;
        }

        records[index].header.execute =
            &executeRecord;

        records[index].id =
            id;

        records[index].depth =
            depth;
    }

    auto queues =
        new Queue[MaxWorkers];

    shared size_t readyCount;
    shared bool start;
    shared bool rootSeeded;

    shared long outstanding;
    shared ulong completed;

    shared WorkerStats[MaxWorkers]
        publishedStats;

    Thread[MaxWorkers]
        threads;

    foreach (worker; 0 .. workerCount)
    {
        threads[worker] =
            makeWorker(
                worker,
                workerCount,
                mode,
                queues,
                &readyCount,
                &start,
                &rootSeeded,
                &outstanding,
                &completed,
                publishedStats.ptr,
                records.ptr);

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

        result.spawned +=
            stats.spawned;

        result.overflowInline +=
            stats.overflowInline;

        result.directContinuations +=
            stats.directContinuations;

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
        TotalTasks)
    {
        throw new Exception(
            "execution count mismatch");
    }

    if (
        result.spawned !=
        TotalTasks - 1)
    {
        throw new Exception(
            "spawn count mismatch");
    }

    if (
        atomicLoad!(
            MemoryOrder.acq)(
                completed) !=
        TotalTasks)
    {
        throw new Exception(
            "completed count mismatch");
    }

    if (
        atomicLoad!(
            MemoryOrder.acq)(
                outstanding) !=
        0)
    {
        throw new Exception(
            "outstanding count mismatch");
    }

    const n =
        TotalTasks;

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
        expectedWorkChecksum())
    {
        throw new Exception(
            "work checksum mismatch");
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
    StealMode mode)
{
    foreach (_; 0 .. Warmups)
    {
        run(
            workerCount,
            mode);
    }

    ulong[Samples]
        elapsed;

    ulong totalExecuted;
    ulong totalLocalPops;

    ulong totalStolen;
    ulong totalClaims;
    ulong totalFailedSteals;

    ulong totalSpawned;
    ulong totalOverflow;
    ulong totalDirectContinuations;

    ulong minWorkerExecuted =
        ulong.max;

    ulong maxWorkerExecuted;

    foreach (sample; 0 .. Samples)
    {
        const result =
            run(
                workerCount,
                mode);

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

        totalSpawned +=
            result.spawned;

        totalOverflow +=
            result.overflowInline;

        totalDirectContinuations +=
            result.directContinuations;

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

    const double nsPerTask =
        d.median /
        TotalTasks;

    const double tasksPerSecond =
        cast(double)
            TotalTasks *
        1_000_000_000.0 /
        d.median;

    const double stolenPerClaim =
        totalClaims != 0
        ? cast(double)
            totalStolen /
            totalClaims
        : 0.0;

    const double localRatio =
        cast(double)
            totalLocalPops /
        totalExecuted;

    const double overflowPerTask =
        cast(double)
            totalOverflow /
        totalExecuted;

    writefln(
        "%-6s workers=%s "
        ~ "median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f "
        ~ "tasks/s=%10.1f",
        modeName(mode),
        workerCount,
        nsPerTask,
        d.p10 / TotalTasks,
        d.p90 / TotalTasks,
        tasksPerSecond);

    writefln(
        "       localRatio=%.3f "
        ~ "claims=%s stolen/claim=%.3f "
        ~ "failedSteals=%s",
        localRatio,
        totalClaims,
        stolenPerClaim,
        totalFailedSteals);

    writefln(
        "       spawned=%s overflow/task=%.6f "
        ~ "directContinuations=%s",
        totalSpawned,
        overflowPerTask,
        totalDirectContinuations);

    writefln(
        "       workerExecutedRange=%s..%s",
        minWorkerExecuted,
        maxWorkerExecuted);
}

void main()
{
    writeln(
        "R0.3 P05b saturation-gated recursive continuation");

    writefln(
        "depth=%s totalTasks=%s work=%s "
        ~ "capacity=%s batch=%s "
        ~ "warmups=%s samples=%s",
        MaxDepth,
        TotalTasks,
        WorkRounds,
        Capacity,
        BatchSize,
        Warmups,
        Samples);

    foreach (
        workers;
        [1, 2, 4])
    {
        benchmark(
            workers,
            StealMode.single);

        benchmark(
            workers,
            StealMode.batch);
    }

    writeln();

    writeln(
        "R0.3 P05b PASS");
}
