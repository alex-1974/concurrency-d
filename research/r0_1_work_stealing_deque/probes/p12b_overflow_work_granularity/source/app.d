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

enum size_t LogSize = 10;
enum size_t Capacity = size_t(1) << LogSize;

enum size_t Thieves = 4;
enum size_t BatchSize = 8;

enum size_t Tasks = 262_144;

enum size_t Warmups = 2;
enum size_t Samples = 9;

enum size_t OwnerCpu = 2;

enum OverflowPolicy
{
    retry,
    executeInline
}

struct TaskRef
{
    ulong value;
}

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        TaskRef,
        LogSize);

struct RunResult
{
    ulong elapsedNs;

    size_t localExecuted;
    size_t stolenExecuted;
    size_t inlineExecuted;

    size_t fullEvents;
    size_t retryAttempts;

    size_t batchClaims;

    ulong valueSum;
    ulong valueXor;

    ulong workChecksum;
}

struct Stats
{
    double medianNsPerTask;
    double p10NsPerTask;
    double p90NsPerTask;
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

private RunResult run(
    OverflowPolicy policy,
    size_t rounds)
{
    auto queue =
        new Queue;

    shared bool start;
    shared bool producerDone;

    shared size_t readyCount;
    shared size_t stolenExecuted;
    shared size_t batchClaims;

    shared ulong stolenSum;
    shared ulong stolenXor;
    shared ulong stolenWorkChecksum;

    Thread[Thieves] thieves;

    foreach (thiefIndex; 0 .. Thieves)
    {
        thieves[thiefIndex] =
            new Thread({
                pinCurrentThread(
                    thiefIndex < OwnerCpu
                        ? thiefIndex
                        : thiefIndex + 1);

                atomicFetchAdd!(
                    MemoryOrder.rel)(
                        readyCount,
                        1);

                TaskRef[BatchSize] batch;

                size_t localExecuted;
                size_t localClaims;

                ulong localSum;
                ulong localXor;
                ulong localWork;

                while (
                    !atomicLoad!(
                        MemoryOrder.acq)(
                            start))
                {
                    Thread.yield();
                }

                for (;;)
                {
                    const taken =
                        queue.stealBatch(
                            batch[]);

                    if (taken != 0)
                    {
                        ++localClaims;

                        foreach (
                            task;
                            batch[0 .. taken])
                        {
                            localSum +=
                                task.value;

                            localXor ^=
                                task.value;

                            localWork ^=
                                doWork(
                                    task.value,
                                    rounds);

                            ++localExecuted;
                        }

                        continue;
                    }

                    if (
                        atomicLoad!(
                            MemoryOrder.acq)(
                                producerDone) &&
                        queue.emptySnapshot())
                    {
                        break;
                    }

                    Thread.yield();
                }

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        stolenExecuted,
                        localExecuted);

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        batchClaims,
                        localClaims);

                atomicFetchAdd!(
                    MemoryOrder.raw)(
                        stolenSum,
                        localSum);

                /*
                 * These two atomic XOR updates happen only once per thief,
                 * after that thief has finished queue processing.
                 *
                 * They are measurement aggregation, not part of the
                 * scheduling/overflow hot path.
                 */
                atomicOp!"^="(
                    stolenXor,
                    localXor);

                atomicOp!"^="(
                    stolenWorkChecksum,
                    localWork);
            });

        thieves[thiefIndex].start();
    }

    pinCurrentThread(
        OwnerCpu);

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                readyCount) !=
        Thieves)
    {
        Thread.yield();
    }

    RunResult result;

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (i; 0 .. Tasks)
    {
        const task =
            TaskRef(
                cast(ulong) i + 1);

        if (queue.tryPush(task))
            continue;

        ++result.fullEvents;

        final switch (policy)
        {
            case OverflowPolicy.retry:
            {
                do
                {
                    ++result.retryAttempts;

                    Thread.yield();
                }
                while (
                    !queue.tryPush(
                        task));

                break;
            }

            case OverflowPolicy.executeInline:
            {
                ++result.inlineExecuted;

                result.valueSum +=
                    task.value;

                result.valueXor ^=
                    task.value;

                result.workChecksum ^=
                    doWork(
                                    task.value,
                                    rounds);

                break;
            }
        }
    }

    atomicStore!(
        MemoryOrder.rel)(
            producerDone,
            true);

    for (;;)
    {
        const popped =
            queue.pop();

        if (popped.found)
        {
            ++result.localExecuted;

            result.valueSum +=
                popped.value.value;

            result.valueXor ^=
                popped.value.value;

            result.workChecksum ^=
                doWork(
                    popped.value.value,
                    rounds);

            continue;
        }

        if (queue.emptySnapshot())
            break;
    }

    foreach (thief; thieves)
        thief.join();

    sw.stop();

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.stolenExecuted =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenExecuted);

    result.batchClaims =
        atomicLoad!(
            MemoryOrder.acq)(
                batchClaims);

    result.valueSum +=
        atomicLoad!(
            MemoryOrder.acq)(
                stolenSum);

    result.valueXor ^=
        atomicLoad!(
            MemoryOrder.acq)(
                stolenXor);

    result.workChecksum ^=
        atomicLoad!(
            MemoryOrder.acq)(
                stolenWorkChecksum);

    const totalExecuted =
        result.localExecuted +
        result.stolenExecuted +
        result.inlineExecuted;

    if (totalExecuted != Tasks)
        throw new Exception(
            "execution count mismatch");

    const n =
        cast(ulong) Tasks;

    const expectedSum =
        n * (n + 1) / 2;

    if (result.valueSum != expectedSum)
        throw new Exception(
            "value sum mismatch");

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

    if (result.valueXor != expectedXor)
        throw new Exception(
            "value xor mismatch");

    if (
        result.workChecksum !=
        expectedWorkChecksum(
            rounds))
    {
        throw new Exception(
            "work checksum mismatch");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "queue not empty");

    return result;
}

private Stats stats(
    ulong[] values)
{
    values.sort();

    return Stats(
        cast(double)
            values[values.length / 2] /
            Tasks,
        cast(double)
            values[
                (values.length - 1) *
                10 / 100] /
            Tasks,
        cast(double)
            values[
                (values.length - 1) *
                90 / 100] /
            Tasks);
}

private string policyName(
    OverflowPolicy policy)
{
    final switch (policy)
    {
        case OverflowPolicy.retry:
            return "retry";

        case OverflowPolicy.executeInline:
            return "inline";
    }
}

private void benchmark(
    OverflowPolicy policy,
    size_t rounds)
{
    foreach (_; 0 .. Warmups)
        run(
            policy,
            rounds);

    ulong[Samples] times;

    size_t totalLocal;
    size_t totalStolen;
    size_t totalInline;

    size_t totalFull;
    size_t totalRetries;
    size_t totalClaims;

    foreach (i; 0 .. Samples)
    {
        const result =
            run(
            policy,
            rounds);

        times[i] =
            result.elapsedNs;

        totalLocal +=
            result.localExecuted;

        totalStolen +=
            result.stolenExecuted;

        totalInline +=
            result.inlineExecuted;

        totalFull +=
            result.fullEvents;

        totalRetries +=
            result.retryAttempts;

        totalClaims +=
            result.batchClaims;
    }

    const s =
        stats(
            times[]);

    const double fullPerTask =
        cast(double)
            totalFull /
        (Tasks * Samples);

    const double stolenPerClaim =
        totalClaims != 0
            ? cast(double)
                totalStolen /
                totalClaims
            : 0.0;

    writefln(
        "%-8s work=%2s median=%8.3f ns/task "
        ~ "p10/p90=%8.3f/%8.3f",
        policyName(policy),
        rounds,
        s.medianNsPerTask,
        s.p10NsPerTask,
        s.p90NsPerTask);

    writefln(
        "         local=%s stolen=%s inline=%s",
        totalLocal,
        totalStolen,
        totalInline);

    writefln(
        "         fullEvents=%s full/task=%.6f "
        ~ "retries=%s",
        totalFull,
        fullPerTask,
        totalRetries);

    writefln(
        "         claims=%s stolen/claim=%.3f",
        totalClaims,
        stolenPerClaim);
}

void main()
{
    writeln(
        "R0.1 P12b overflow work granularity");

    writefln(
        "capacity=%s tasks=%s thieves=%s "
        ~ "batch=%s warmups=%s samples=%s",
        Capacity,
        Tasks,
        Thieves,
        BatchSize,
        Warmups,
        Samples);

    foreach (rounds; [0, 16, 64])
    {
        benchmark(
            OverflowPolicy.retry,
            rounds);

        benchmark(
            OverflowPolicy.executeInline,
            rounds);
    }

    writeln(
        "R0.1 P12b PASS");
}
