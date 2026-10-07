module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

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

enum size_t Workers = 4;

enum size_t LogSize = 10;
enum size_t Capacity = size_t(1) << LogSize;
enum size_t BatchSize = 8;

enum uint MaxDepth = 18;

enum size_t Warmups = 2;
enum size_t Samples = 9;

enum StealMode
{
    single,
    batch
}

/*
 * High byte:
 *     depth
 *
 * Low 56 bits:
 *     deterministic quaternary-tree path id
 */
struct TaskRef
{
    ulong encoded;
}

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        TaskRef,
        LogSize);

struct Expected
{
    ulong count;
    ulong spawned;

    ulong valueSum;
    ulong valueXor;
    ulong workChecksum;
}

struct WorkerStats
{
    ulong executed;
    ulong localPops;

    ulong stolenTasks;
    ulong stealClaims;
    ulong failedSteals;

    ulong spawned;
    ulong overflowInline;

    ulong idleTransitions;

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
    ulong idleTransitions;

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

private TaskRef makeTask(
    ulong path,
    uint depth)
    @safe @nogc nothrow
{
    return TaskRef(
        (cast(ulong) depth << 56) |
        path);
}

private ulong taskPath(
    TaskRef task)
    @safe @nogc nothrow
{
    return
        task.encoded &
        0x00ff_ffff_ffff_ffffUL;
}

private uint taskDepth(
    TaskRef task)
    @safe @nogc nothrow
{
    return
        cast(uint)
            (task.encoded >> 56);
}

private ulong mix(
    ulong x)
    @safe @nogc nothrow
{
    x ^= x >> 30;
    x *=
        0xbf58_476d_1ce4_e5b9UL;

    x ^= x >> 27;
    x *=
        0x94d0_49bb_1331_11ebUL;

    x ^= x >> 31;

    return x;
}

/*
 * Deterministic irregular fan-out.
 *
 * Interior levels deliberately bias toward continued production so the graph
 * remains substantial, while still creating leaves and narrow branches.
 */
private size_t fanout(
    ulong path,
    uint depth)
    @safe @nogc nothrow
{
    if (depth >= MaxDepth)
        return 0;

    const selector =
        mix(
            path ^
            (
                cast(ulong) depth *
                0x9e37_79b9_7f4a_7c15UL
            )) &
        7;

    final switch (
        cast(uint) selector)
    {
        case 0:
            return 0;

        case 1:
        case 2:
            return 1;

        case 3:
        case 4:
        case 5:
            return 2;

        case 6:
        case 7:
            return 4;
    }
}

/*
 * Deterministic heterogeneous task cost.
 *
 * Produces recurring tiny, medium and heavier tasks without randomness.
 */
private size_t workRounds(
    ulong path,
    uint depth)
    @safe @nogc nothrow
{
    const selector =
        mix(
            path +
            (
                cast(ulong) depth *
                0xd1b5_4a32_d192_ed03UL
            )) &
        7;

    final switch (
        cast(uint) selector)
    {
        case 0:
        case 1:
            return 0;

        case 2:
        case 3:
        case 4:
            return 8;

        case 5:
        case 6:
            return 24;

        case 7:
            return 64;
    }
}

private ulong doWork(
    ulong value,
    size_t rounds)
    @safe @nogc nothrow
{
    ulong x =
        value +
        0x9e37_79b9_7f4a_7c15UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;

        x *=
            0x2545_f491_4f6c_dd1dUL;

        x +=
            cast(ulong) i +
            0x9e37_79b9_7f4a_7c15UL;
    }

    return x;
}

private ulong childPath(
    ulong parent,
    size_t child)
    @safe @nogc nothrow
{
    return
        (parent << 2) |
        cast(ulong)
            (child + 1);
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

/*
 * Enumerate the exact deterministic graph outside benchmark timing.
 */
private void accumulateExpected(
    ulong path,
    uint depth,
    ref Expected expected)
{
    ++expected.count;

    expected.valueSum +=
        path;

    expected.valueXor ^=
        path;

    expected.workChecksum ^=
        doWork(
            path,
            workRounds(
                path,
                depth));

    const children =
        fanout(
            path,
            depth);

    expected.spawned +=
        children;

    foreach (child; 0 .. children)
    {
        accumulateExpected(
            childPath(
                path,
                child),
            depth + 1,
            expected);
    }
}

private Expected expectedGraph()
{
    Expected result;

    accumulateExpected(
        1,
        0,
        result);

    return result;
}

/*
 * Cold overflow path.
 *
 * This preserves P12 execute-inline semantics, including recursive
 * descendant production, while keeping recursion out of the normal
 * scheduler hot path.
 */
private void executeOverflowInline(
    TaskRef task,
    size_t workerIndex,
    Queue[] queues,
    ref WorkerStats stats,
    shared long* outstanding,
    shared ulong* completed)
{
    const path =
        taskPath(task);

    const depth =
        taskDepth(task);

    ++stats.executed;

    stats.valueSum +=
        path;

    stats.valueXor ^=
        path;

    stats.workChecksum ^=
        doWork(
            path,
            workRounds(
                path,
                depth));

    const children =
        fanout(
            path,
            depth);

    if (children != 0)
    {
        atomicFetchAdd!(
            MemoryOrder.rel)(
                *outstanding,
                cast(long) children);

        stats.spawned +=
            children;

        foreach (child; 0 .. children)
        {
            const next =
                makeTask(
                    childPath(
                        path,
                        child),
                    depth + 1);

            if (
                queues[
                    workerIndex]
                .tryPush(next))
            {
                continue;
            }

            ++stats.overflowInline;

            executeOverflowInline(
                next,
                workerIndex,
                queues,
                stats,
                outstanding,
                completed);
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
 * Normal irregular-task hot path.
 *
 * Deliberately non-recursive. If the bounded owner-local queue fills,
 * the original P12 semantics continue in executeOverflowInline.
 */
private void executeTask(
    TaskRef task,
    size_t workerIndex,
    Queue[] queues,
    ref WorkerStats stats,
    shared long* outstanding,
    shared ulong* completed)
{
    const path =
        taskPath(task);

    const depth =
        taskDepth(task);

    ++stats.executed;

    stats.valueSum +=
        path;

    stats.valueXor ^=
        path;

    stats.workChecksum ^=
        doWork(
            path,
            workRounds(
                path,
                depth));

    const children =
        fanout(
            path,
            depth);

    if (children != 0)
    {
        atomicFetchAdd!(
            MemoryOrder.rel)(
                *outstanding,
                cast(long) children);

        stats.spawned +=
            children;

        foreach (child; 0 .. children)
        {
            const next =
                makeTask(
                    childPath(
                        path,
                        child),
                    depth + 1);

            if (
                queues[
                    workerIndex]
                .tryPush(next))
            {
                continue;
            }

            ++stats.overflowInline;

            executeOverflowInline(
                next,
                workerIndex,
                queues,
                stats,
                outstanding,
                completed);
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

private Thread makeWorker(
    size_t workerIndex,
    StealMode mode,
    Queue[] queues,
    shared size_t* readyCount,
    shared bool* start,
    shared bool* rootSeeded,
    shared long* outstanding,
    shared ulong* completed,
    shared WorkerStats* publishedStats)
{
    return new Thread({
        pinCurrentThread(
            workerIndex);

        WorkerStats stats;

        TaskRef[BatchSize]
            batch;

        size_t nextVictim =
            (workerIndex + 1) %
            Workers;

        bool idle;

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

        if (workerIndex == 0)
        {
            atomicFetchAdd!(
                MemoryOrder.rel)(
                    *outstanding,
                    cast(long) 1);

            if (
                !queues[0]
                .tryPush(
                    makeTask(
                        1,
                        0)))
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
            const local =
                queues[
                    workerIndex]
                .pop();

            if (local.found)
            {
                idle = false;

                ++stats.localPops;

                executeTask(
                    local.value,
                    workerIndex,
                    queues,
                    stats,
                    outstanding,
                    completed);

                continue;
            }

            bool foundWork;

            foreach (
                _;
                0 ..
                Workers - 1)
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

                        idle = false;

                        executeTask(
                            stolen.value,
                            workerIndex,
                            queues,
                            stats,
                            outstanding,
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

                        idle = false;

                        executeTask(
                            batch[0],
                            workerIndex,
                            queues,
                            stats,
                            outstanding,
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
                                workerIndex,
                                queues,
                                stats,
                                outstanding,
                                completed);
                        }

                        foundWork = true;
                        break;
                    }
                }

                if (foundWork)
                    break;
            }

            if (foundWork)
                continue;

            if (
                atomicLoad!(
                    MemoryOrder.acq)(
                        *rootSeeded) &&
                atomicLoad!(
                    MemoryOrder.acq)(
                        *outstanding) ==
                    0)
            {
                break;
            }

            if (!idle)
            {
                ++stats.idleTransitions;
                idle = true;
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
    StealMode mode,
    Expected expected)
{
    auto queues =
        new Queue[Workers];

    shared size_t readyCount;
    shared bool start;
    shared bool rootSeeded;

    shared long outstanding;
    shared ulong completed;

    shared WorkerStats[Workers]
        publishedStats;

    Thread[Workers]
        threads;

    foreach (worker; 0 .. Workers)
    {
        threads[worker] =
            makeWorker(
                worker,
                mode,
                queues,
                &readyCount,
                &start,
                &rootSeeded,
                &outstanding,
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

    foreach (worker; 0 .. Workers)
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

        result.idleTransitions +=
            stats.idleTransitions;

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
        expected.count)
    {
        throw new Exception(
            "execution count mismatch");
    }

    if (
        result.spawned !=
        expected.spawned)
    {
        throw new Exception(
            "spawn count mismatch");
    }

    if (
        atomicLoad!(
            MemoryOrder.acq)(
                completed) !=
        expected.count)
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
            "outstanding mismatch");
    }

    if (
        valueSum !=
        expected.valueSum)
    {
        throw new Exception(
            "value sum mismatch");
    }

    if (
        valueXor !=
        expected.valueXor)
    {
        throw new Exception(
            "value xor mismatch");
    }

    if (
        workChecksum !=
        expected.workChecksum)
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
    StealMode mode,
    Expected expected)
{
    foreach (_; 0 .. Warmups)
    {
        run(
            mode,
            expected);
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
    ulong totalIdleTransitions;
    ulong totalBusyRetries;

    ulong minWorkerExecuted =
        ulong.max;

    ulong maxWorkerExecuted;

    foreach (sample; 0 .. Samples)
    {
        const result =
            run(
                mode,
                expected);

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

        totalIdleTransitions +=
            result.idleTransitions;

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

    const double nsPerTask =
        d.median /
        expected.count;

    const double tasksPerSecond =
        cast(double)
            expected.count *
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
        "%-6s median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f "
        ~ "tasks/s=%10.1f",
        modeName(mode),
        nsPerTask,
        d.p10 / expected.count,
        d.p90 / expected.count,
        tasksPerSecond);

    writefln(
        "       localRatio=%.3f "
        ~ "claims=%s stolen/claim=%.3f",
        localRatio,
        totalClaims,
        stolenPerClaim);

    writefln(
        "       failedSteals=%s "
        ~ "idleTransitions=%s",
        totalFailedSteals,
        totalIdleTransitions);

    writefln(
        "       spawned=%s overflow/task=%.6f "
        ~ "ownerBusyRetries=%s",
        totalSpawned,
        overflowPerTask,
        totalBusyRetries);

    writefln(
        "       workerExecutedRange=%s..%s",
        minWorkerExecuted,
        maxWorkerExecuted);
}

void main()
{
    const expected =
        expectedGraph();

    writeln(
        "R0.1 P14h irregular cold-overflow workload");

    writefln(
        "workers=%s maxDepth=%s tasks=%s spawned=%s "
        ~ "capacity=%s batch=%s warmups=%s samples=%s",
        Workers,
        MaxDepth,
        expected.count,
        expected.spawned,
        Capacity,
        BatchSize,
        Warmups,
        Samples);

    benchmark(
        StealMode.single,
        expected);

    benchmark(
        StealMode.batch,
        expected);

    writeln();

    writeln(
        "R0.1 P14h PASS");
}
