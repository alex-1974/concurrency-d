module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_full64_marked_top :
    Full64DistanceMarkedBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicStore;

import core.thread : Thread;

version (linux)
{
    import core.sys.linux.sched :
        CPU_SET,
        cpu_set_t,
        sched_getcpu,
        sched_setaffinity;
}

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln, writeln;

enum size_t LogSize = 20;
enum size_t BatchSize = 8;
enum size_t MaxThieves = 8;

alias BaseQueue =
    ModularRmwPaddedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias MarkedQueue =
    Full64DistanceMarkedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

immutable size_t[MaxThieves] thiefCpuPool =
[
    3, 4, 1, 5, 0, 9, 10, 7
];

enum Variant
{
    stealOne,
    markedBatch
}

struct RunResult
{
    ulong elapsedNs;

    ulong valueChecksum;
    ulong workChecksum;

    size_t ownerPopped;
    size_t stolen;

    size_t claims;
    size_t thiefRetries;

    ulong ownerBusyRetries;
}

struct Stats
{
    double medianNs;
    double p10Ns;
    double p90Ns;
}

private void pinCurrentThread(size_t cpu)
{
    version (linux)
    {
        cpu_set_t mask;

        CPU_SET(cpu, &mask);

        const rc =
            sched_setaffinity(
                0,
                cpu_set_t.sizeof,
                &mask);

        if (rc != 0)
            throw new Exception(
                "sched_setaffinity failed");

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
 * Runtime-selected deterministic task payload.
 *
 * Its result contributes to the final checksum, so the computation cannot
 * simply be discarded by optimized builds.
 */
private ulong performWork(
    size_t value,
    size_t rounds)
    @nogc nothrow
{
    ulong x =
        cast(ulong) value +
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
    size_t items,
    size_t workRounds)
{
    ulong result;

    foreach (value; 1 .. items + 1)
    {
        result +=
            performWork(
                value,
                workRounds);
    }

    return result;
}

private RunResult runDrain(
    Queue,
    Variant variant)(
    size_t items,
    size_t thiefCount,
    size_t ownerCpu,
    size_t workRounds,
    ulong expectedWork)
{
    auto queue =
        new Queue;

    static if (
        variant ==
        Variant.markedBatch)
    {
        queue.researchResetOwnerBusyRetries();
    }

    foreach (i; 0 .. items)
    {
        if (!queue.tryPush(i + 1))
            throw new Exception(
                "prefill failed");
    }

    if (queue.sizeSnapshot() != items)
        throw new Exception(
            "prefill size mismatch");

    shared bool start;
    shared size_t ready;

    shared ulong[MaxThieves] thiefValueChecksums;
    shared ulong[MaxThieves] thiefWorkChecksums;

    shared size_t[MaxThieves] thiefCounts;
    shared size_t[MaxThieves] thiefClaims;
    shared size_t[MaxThieves] thiefRetries;

    auto thieves =
        new Thread[thiefCount];

    foreach (slot; 0 .. thiefCount)
    {
        thieves[slot] =
            new Thread({
                const index =
                    atomicFetchAdd!(
                        MemoryOrder.raw)(
                            ready,
                            1);

                pinCurrentThread(
                    thiefCpuPool[index]);

                while (
                    !atomicLoad!(
                        MemoryOrder.acq)(
                            start))
                {
                    Thread.yield();
                }

                ulong valueChecksum;
                ulong workChecksum;

                size_t count;
                size_t claims;
                size_t retries;

                size_t[BatchSize] buffer;

                for (;;)
                {
                    static if (
                        variant ==
                        Variant.stealOne)
                    {
                        const result =
                            queue.steal();

                        if (result.found)
                        {
                            const value =
                                result.value;

                            valueChecksum +=
                                cast(ulong) value;

                            workChecksum +=
                                performWork(
                                    value,
                                    workRounds);

                            ++count;
                            ++claims;

                            continue;
                        }
                    }
                    else
                    {
                        const taken =
                            queue.stealBatch(
                                buffer[]);

                        if (taken != 0)
                        {
                            ++claims;

                            /*
                             * Scheduler-like behaviour:
                             * consume the stolen local batch before returning
                             * to the victim for another steal attempt.
                             */
                            foreach (
                                value;
                                buffer[0 .. taken])
                            {
                                valueChecksum +=
                                    cast(ulong) value;

                                workChecksum +=
                                    performWork(
                                        value,
                                        workRounds);

                                ++count;
                            }

                            continue;
                        }
                    }

                    ++retries;

                    if (queue.emptySnapshot())
                        break;

                    if ((retries & 255) == 0)
                        Thread.yield();
                }

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefValueChecksums[index],
                        valueChecksum);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefWorkChecksums[index],
                        workChecksum);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefCounts[index],
                        count);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefClaims[index],
                        claims);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefRetries[index],
                        retries);
            });

        thieves[slot].start();
    }

    pinCurrentThread(ownerCpu);

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                ready) !=
        thiefCount)
    {
        Thread.yield();
    }

    ulong ownerValueChecksum;
    ulong ownerWorkChecksum;
    size_t ownerCount;

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    for (;;)
    {
        const result =
            queue.pop();

        if (result.found)
        {
            const value =
                result.value;

            ownerValueChecksum +=
                cast(ulong) value;

            ownerWorkChecksum +=
                performWork(
                    value,
                    workRounds);

            ++ownerCount;

            continue;
        }

        if (queue.emptySnapshot())
            break;
    }

    foreach (thief; thieves)
        thief.join();

    sw.stop();

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.valueChecksum =
        ownerValueChecksum;

    result.workChecksum =
        ownerWorkChecksum;

    result.ownerPopped =
        ownerCount;

    foreach (i; 0 .. thiefCount)
    {
        result.valueChecksum +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefValueChecksums[i]);

        result.workChecksum +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefWorkChecksums[i]);

        result.stolen +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefCounts[i]);

        result.claims +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefClaims[i]);

        result.thiefRetries +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefRetries[i]);
    }

    static if (
        variant ==
        Variant.markedBatch)
    {
        result.ownerBusyRetries =
            queue.researchOwnerBusyRetriesSnapshot();

        if (queue.researchBatchBusy())
            throw new Exception(
                "busy marker leaked");
    }

    const returned =
        result.ownerPopped +
        result.stolen;

    const expectedValueChecksum =
        cast(ulong) items *
        cast(ulong)(items + 1) /
        2;

    if (returned != items)
        throw new Exception(
            "returned count mismatch");

    if (
        result.valueChecksum !=
        expectedValueChecksum)
    {
        throw new Exception(
            "value checksum mismatch");
    }

    if (
        result.workChecksum !=
        expectedWork)
    {
        throw new Exception(
            "work checksum mismatch");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "queue not empty");

    return result;
}

private Stats calculateStats(
    ulong[] times,
    size_t items)
{
    times.sort();

    const n =
        times.length;

    const double median =
        n & 1
            ? cast(double)
                times[n / 2]
            : (
                cast(double)
                    times[n / 2 - 1] +
                cast(double)
                    times[n / 2]
              ) / 2.0;

    const p10 =
        (n - 1) * 10 / 100;

    const p90 =
        (n - 1) * 90 / 100;

    return Stats(
        median / items,
        cast(double)
            times[p10] / items,
        cast(double)
            times[p90] / items);
}

private void benchmark(
    Queue,
    Variant variant)(
    string name,
    size_t items,
    size_t thiefCount,
    size_t ownerCpu,
    size_t workRounds,
    size_t warmups,
    size_t samples)
{
    const expectedWork =
        expectedWorkChecksum(
            items,
            workRounds);

    foreach (_; 0 .. warmups)
    {
        runDrain!(Queue, variant)(
            items,
            thiefCount,
            ownerCpu,
            workRounds,
            expectedWork);
    }

    auto times =
        new ulong[samples];

    ulong aggregateValueChecksum;
    ulong aggregateWorkChecksum;

    size_t aggregateOwner;
    size_t aggregateStolen;
    size_t aggregateClaims;
    size_t aggregateThiefRetries;

    ulong aggregateOwnerBusyRetries;

    foreach (i; 0 .. samples)
    {
        const result =
            runDrain!(Queue, variant)(
                items,
                thiefCount,
                ownerCpu,
                workRounds,
                expectedWork);

        times[i] =
            result.elapsedNs;

        aggregateValueChecksum +=
            result.valueChecksum;

        aggregateWorkChecksum +=
            result.workChecksum;

        aggregateOwner +=
            result.ownerPopped;

        aggregateStolen +=
            result.stolen;

        aggregateClaims +=
            result.claims;

        aggregateThiefRetries +=
            result.thiefRetries;

        aggregateOwnerBusyRetries +=
            result.ownerBusyRetries;
    }

    const stats =
        calculateStats(
            times,
            items);

    const total =
        aggregateOwner +
        aggregateStolen;

    const double ownerShare =
        total != 0
            ? 100.0 *
                cast(double) aggregateOwner /
                total
            : 0.0;

    const double stolenPerClaim =
        aggregateClaims != 0
            ? cast(double)
                aggregateStolen /
                aggregateClaims
            : 0.0;

    writefln(
        "%-11s work=%3s median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        name,
        workRounds,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns);

    writefln(
        "            owner=%s stolen=%s ownerShare=%.3f%%",
        aggregateOwner,
        aggregateStolen,
        ownerShare);

    writefln(
        "            claims=%s stolen/claim=%.3f",
        aggregateClaims,
        stolenPerClaim);

    writefln(
        "            ownerBusyRetries=%s thiefRetries=%s",
        aggregateOwnerBusyRetries,
        aggregateThiefRetries);

    writefln(
        "            valueChecksum=%s workChecksum=%s",
        aggregateValueChecksum,
        aggregateWorkChecksum);
}

void main(string[] args)
{
    size_t items =
        BaseQueue.capacity;

    size_t thiefCount = 4;
    size_t warmups = 4;
    size_t samples = 15;
    size_t ownerCpu = 2;

    if (args.length > 1)
        items =
            args[1].to!size_t;

    if (args.length > 2)
        thiefCount =
            args[2].to!size_t;

    if (args.length > 3)
        warmups =
            args[3].to!size_t;

    if (args.length > 4)
        samples =
            args[4].to!size_t;

    if (args.length > 5)
        ownerCpu =
            args[5].to!size_t;

    if (
        items == 0 ||
        items > BaseQueue.capacity ||
        thiefCount == 0 ||
        thiefCount > MaxThieves ||
        samples < 5)
    {
        throw new Exception(
            "invalid arguments");
    }

    writeln(
        "R0.1 P08g3 scheduler-like local work");

    writefln(
        "items=%s thieves=%s batch=%s warmups=%s samples=%s",
        items,
        thiefCount,
        BatchSize,
        warmups,
        samples);

    foreach (
        workRounds;
        [0UL, 16UL, 64UL])
    {
        benchmark!(
            BaseQueue,
            Variant.stealOne)(
                "steal-one",
                items,
                thiefCount,
                ownerCpu,
                workRounds,
                warmups,
                samples);

        benchmark!(
            MarkedQueue,
            Variant.markedBatch)(
                "marked-top",
                items,
                thiefCount,
                ownerCpu,
                workRounds,
                warmups,
                samples);
    }

    writeln(
        "R0.1 P08g3 PASS");
}
