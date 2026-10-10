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

enum size_t Workers = 4;

enum size_t Capacity = 1024;
enum size_t BatchSize = 8;

enum uint MaxDepth = 18;

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
    ulong path;

    ubyte depth;
    ubyte rounds;
    ubyte childCount;
    ubyte reserved;

    uint[4] childIndex;
}

struct TaskRef
{
    shared(TaskHeader)* ptr;
}

struct Graph
{
    shared TaskRecord[] records;
    Expected expected;
}

static assert(
    TaskHeader.sizeof == 8);

static assert(
    TaskRef.sizeof == 8);

alias Queue =
    WorkStealingDeque!(
        TaskRef,
        Capacity);

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
    ulong directContinuations;

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
    ulong directContinuations;
    ulong idleTransitions;

    ulong minWorkerExecuted;
    ulong maxWorkerExecuted;
}

struct Distribution
{
    double median;
    double p10;
    double p90;
}

private shared(TaskRecord*) taskRecord(
    TaskRef task)
    @trusted @nogc nothrow
{
    return
        cast(shared TaskRecord*)
            task.ptr;
}

private TaskRef makeTask(
    uint index,
    shared TaskRecord* records)
    @trusted @nogc nothrow
{
    return TaskRef(
        &records[index]
        .header);
}

private ulong taskPath(
    TaskRef task)
    @safe @nogc nothrow
{
    return atomicLoad!(
        MemoryOrder.raw)(
            taskRecord(task)
            .path);
}

private uint taskDepth(
    TaskRef task)
    @safe @nogc nothrow
{
    return cast(uint)
        atomicLoad!(
            MemoryOrder.raw)(
                taskRecord(task)
                .depth);
}

private size_t taskRounds(
    TaskRef task)
    @safe @nogc nothrow
{
    return cast(size_t)
        atomicLoad!(
            MemoryOrder.raw)(
                taskRecord(task)
                .rounds);
}

private size_t taskChildCount(
    TaskRef task)
    @safe @nogc nothrow
{
    return cast(size_t)
        atomicLoad!(
            MemoryOrder.raw)(
                taskRecord(task)
                .childCount);
}

private uint taskChildIndex(
    TaskRef task,
    size_t child)
    @safe @nogc nothrow
{
    return atomicLoad!(
        MemoryOrder.raw)(
            taskRecord(task)
            .childIndex[child]);
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

private ulong executeRecord(
    shared(TaskHeader)* header)
    @trusted @nogc nothrow
{
    auto record =
        cast(shared TaskRecord*)
            header;

    return doWork(
        atomicLoad!(
            MemoryOrder.raw)(
                record.path),
        cast(size_t)
            atomicLoad!(
                MemoryOrder.raw)(
                    record.rounds));
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
 * Build the exact deterministic graph and stable TaskRecord arena outside
 * benchmark timing.
 */
private uint appendGraphRecord(
    ulong path,
    uint depth,
    ref TaskRecord[] records,
    ref Expected expected)
{
    if (
        records.length >=
        uint.max)
    {
        throw new Exception(
            "graph exceeds uint index domain");
    }

    const index =
        cast(uint)
            records.length;

    records.length =
        records.length + 1;

    records[index].header.execute =
        &executeRecord;

    records[index].path =
        path;

    records[index].depth =
        cast(ubyte) depth;

    records[index].rounds =
        cast(ubyte)
            workRounds(
                path,
                depth);

    ++expected.count;

    expected.valueSum +=
        path;

    expected.valueXor ^=
        path;

    expected.workChecksum ^=
        doWork(
            path,
            records[index].rounds);

    const children =
        fanout(
            path,
            depth);

    records[index].childCount =
        cast(ubyte) children;

    expected.spawned +=
        children;

    foreach (child; 0 .. children)
    {
        const childIndex =
            appendGraphRecord(
                childPath(
                    path,
                    child),
                depth + 1,
                records,
                expected);

        records[index]
            .childIndex[child] =
            childIndex;
    }

    return index;
}

private Graph buildGraph()
{
    TaskRecord[] temporary;
    Expected expected;

    temporary.reserve(
        256_000);

    const root =
        appendGraphRecord(
            1,
            0,
            temporary,
            expected);

    if (root != 0)
    {
        throw new Exception(
            "root index mismatch");
    }

    auto records =
        new shared TaskRecord[
            temporary.length];

    foreach (i; 0 .. temporary.length)
    {
        records[i].header.execute =
            temporary[i]
            .header.execute;

        records[i].path =
            temporary[i].path;

        records[i].depth =
            temporary[i].depth;

        records[i].rounds =
            temporary[i].rounds;

        records[i].childCount =
            temporary[i].childCount;

        foreach (child; 0 .. 4)
        {
            records[i]
                .childIndex[child] =
                temporary[i]
                .childIndex[child];
        }
    }

    return Graph(
        records,
        expected);
}

/*
 * Recursive execution is used only by overflow-inline paths.
 *
 * Descendants are added to outstanding before publication or inline
 * execution, so termination cannot observe zero while descendants exist.
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
    const path =
        taskPath(task);

    ++stats.executed;

    stats.valueSum +=
        path;

    stats.valueXor ^=
        path;

    stats.workChecksum ^=
        executeWork(
            task);

    const children =
        taskChildCount(
            task);

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
            auto next =
                makeTask(
                    taskChildIndex(
                        task,
                        child),
                    records);

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

private void executeTask(
    TaskRef initialTask,
    size_t workerIndex,
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
        const path =
            taskPath(task);

        ++stats.executed;

        stats.valueSum +=
            path;

        stats.valueXor ^=
            path;

        stats.workChecksum ^=
            executeWork(
                task);

        const children =
            taskChildCount(
                task);

        TaskRef direct;
        bool hasDirect;

        if (children != 0)
        {
            atomicFetchAdd!(
                MemoryOrder.rel)(
                    *outstanding,
                    cast(long) children);

            stats.spawned +=
                children;

            const available =
                atomicLoad!(
                    MemoryOrder.raw)(
                        *outstanding);

            if (
                available >=
                cast(long) Workers)
            {
                direct =
                    makeTask(
                        taskChildIndex(
                            task,
                            0),
                        records);

                hasDirect =
                    true;

                ++stats.directContinuations;

                foreach (child; 1 .. children)
                {
                    auto next =
                        makeTask(
                            taskChildIndex(
                                task,
                                child),
                            records);

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
                        completed,
                        records);
                }
            }
            else
            {
                foreach (child; 0 .. children)
                {
                    auto next =
                        makeTask(
                            taskChildIndex(
                                task,
                                child),
                            records);

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
                        0,
                        records)))
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
                idle = false;

                ++stats.localPops;

                executeTask(
                    local.value,
                    workerIndex,
                    queues,
                    stats,
                    outstanding,
                    completed,
                    records);

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

                        idle = false;

                        executeTask(
                            stolen.value,
                            workerIndex,
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

                        idle = false;

                        executeTask(
                            batch[0],
                            workerIndex,
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
    shared TaskRecord[] records,
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
                publishedStats.ptr,
                records.ptr);

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

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

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

        result.directContinuations +=
            stats.directContinuations;

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
    shared TaskRecord[] records,
    Expected expected)
{
    foreach (_; 0 .. Warmups)
    {
        run(
            mode,
            records,
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
    ulong totalDirectContinuations;
    ulong totalIdleTransitions;

    ulong minWorkerExecuted =
        ulong.max;

    ulong maxWorkerExecuted;

    foreach (sample; 0 .. Samples)
    {
        const result =
            run(
                mode,
                records,
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

        totalDirectContinuations +=
            result.directContinuations;

        totalIdleTransitions +=
            result.idleTransitions;

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
    auto graph =
        buildGraph();

    const expected =
        graph.expected;

    writeln(
        "R0.3 P04d saturation-gated irregular continuation");

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
        graph.records,
        expected);

    benchmark(
        StealMode.batch,
        graph.records,
        expected);

    writeln();

    writeln(
        "R0.3 P04d PASS");
}
