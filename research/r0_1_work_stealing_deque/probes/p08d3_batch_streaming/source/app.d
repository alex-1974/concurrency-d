module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_safe_ref :
    SafeReferenceBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_gate :
    GatedBatchBoundedWorkStealingDeque;

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

enum size_t LogSize = 12;
enum size_t MaxBatch = 32;
enum size_t MaxThieves = 8;

alias OneQueue =
    ModularRmwPaddedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias RefQueue =
    SafeReferenceBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias GateQueue =
    GatedBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

immutable size_t[MaxThieves] thiefCpuPool =
[
    3, 4, 1, 5, 0, 9, 10, 7
];

enum QueueKind
{
    one,
    referenceBatch,
    gatedBatch
}

struct RunResult
{
    ulong elapsedNs;
    ulong checksum;

    size_t itemsTaken;
    size_t pushRetries;

    size_t emptyAttempts;
    size_t successfulClaims;
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

private RunResult runVariant(
    Queue,
    QueueKind kind)(
    size_t items,
    size_t thiefCount,
    size_t batchSize,
    size_t ownerCpu)
{
    if (
        thiefCount == 0 ||
        thiefCount > MaxThieves ||
        batchSize == 0 ||
        batchSize > MaxBatch)
    {
        throw new Exception(
            "invalid benchmark arguments");
    }

    auto queue =
        new Queue;

    shared bool start;
    shared bool ownerDone;
    shared size_t nextThiefIndex;

    shared ulong[MaxThieves] thiefChecksums;
    shared size_t[MaxThieves] thiefCounts;
    shared size_t[MaxThieves] emptyAttempts;
    shared size_t[MaxThieves] successfulClaims;

    auto thieves =
        new Thread[thiefCount];

    foreach (_; 0 .. thiefCount)
    {
        thieves[_] =
            new Thread({
                const index =
                    atomicFetchAdd!(
                        MemoryOrder.raw)(
                            nextThiefIndex,
                            1);

                const cpu =
                    thiefCpuPool[index];

                pinCurrentThread(cpu);

                while (
                    !atomicLoad!(
                        MemoryOrder.acq)(
                            start))
                {
                    Thread.yield();
                }

                ulong checksum;
                size_t count;
                size_t empties;
                size_t claims;

                size_t[MaxBatch] buffer;

                for (;;)
                {
                    static if (
                        kind ==
                        QueueKind.one)
                    {
                        const result =
                            queue.steal();

                        if (result.found)
                        {
                            checksum +=
                                cast(ulong)
                                    result.value;

                            ++count;
                            ++claims;
                            continue;
                        }
                    }
                    else
                    {
                        const taken =
                            queue.stealBatch(
                                buffer[
                                    0 ..
                                    batchSize]);

                        if (taken != 0)
                        {
                            ++claims;

                            foreach (
                                value;
                                buffer[
                                    0 ..
                                    taken])
                            {
                                checksum +=
                                    cast(ulong) value;

                                ++count;
                            }

                            continue;
                        }
                    }

                    ++empties;

                    if (
                        atomicLoad!(
                            MemoryOrder.acq)(
                                ownerDone))
                    {
                        break;
                    }

                    if (
                        (empties & 255) == 0)
                    {
                        Thread.yield();
                    }
                }

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefChecksums[index],
                        checksum);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefCounts[index],
                        count);

                atomicStore!(
                    MemoryOrder.rel)(
                        emptyAttempts[index],
                        empties);

                atomicStore!(
                    MemoryOrder.rel)(
                        successfulClaims[index],
                        claims);
            });

        thieves[_].start();
    }

    pinCurrentThread(ownerCpu);

    while (
        atomicLoad!(
            MemoryOrder.acq)(
                nextThiefIndex) !=
        thiefCount)
    {
        Thread.yield();
    }

    size_t pushRetries;

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    foreach (i; 0 .. items)
    {
        const value =
            i + 1;

        while (
            !queue.tryPush(value))
        {
            ++pushRetries;

            if (
                (pushRetries & 255) == 0)
            {
                Thread.yield();
            }
        }
    }

    atomicStore!(
        MemoryOrder.rel)(
            ownerDone,
            true);

    foreach (thief; thieves)
        thief.join();

    sw.stop();

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.pushRetries =
        pushRetries;

    foreach (i; 0 .. thiefCount)
    {
        result.checksum +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefChecksums[i]);

        result.itemsTaken +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefCounts[i]);

        result.emptyAttempts +=
            atomicLoad!(
                MemoryOrder.acq)(
                    emptyAttempts[i]);

        result.successfulClaims +=
            atomicLoad!(
                MemoryOrder.acq)(
                    successfulClaims[i]);
    }

    const expectedChecksum =
        cast(ulong) items *
        cast(ulong)(items + 1) /
        2;

    if (result.itemsTaken != items)
        throw new Exception(
            "item accounting failure");

    if (
        result.checksum !=
        expectedChecksum)
    {
        throw new Exception(
            "checksum failure");
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

private void benchmarkVariant(
    Queue,
    QueueKind kind)(
    string name,
    size_t items,
    size_t thiefCount,
    size_t batchSize,
    size_t ownerCpu,
    size_t warmups,
    size_t samples)
{
    foreach (_; 0 .. warmups)
    {
        runVariant!(Queue, kind)(
            items,
            thiefCount,
            batchSize,
            ownerCpu);
    }

    auto times =
        new ulong[samples];

    ulong aggregateChecksum;
    size_t aggregatePushRetries;
    size_t aggregateEmptyAttempts;
    size_t aggregateClaims;
    size_t aggregateItems;

    foreach (i; 0 .. samples)
    {
        const result =
            runVariant!(Queue, kind)(
                items,
                thiefCount,
                batchSize,
                ownerCpu);

        times[i] =
            result.elapsedNs;

        aggregateChecksum +=
            result.checksum;

        aggregatePushRetries +=
            result.pushRetries;

        aggregateEmptyAttempts +=
            result.emptyAttempts;

        aggregateClaims +=
            result.successfulClaims;

        aggregateItems +=
            result.itemsTaken;
    }

    const stats =
        calculateStats(
            times,
            items);

    const double itemsPerClaim =
        aggregateClaims != 0
            ? cast(double)
                aggregateItems /
                aggregateClaims
            : 0.0;

    const double claimsPerItem =
        aggregateItems != 0
            ? cast(double)
                aggregateClaims /
                aggregateItems
            : 0.0;

    writefln(
        "%-14s batch=%2s median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        name,
        batchSize,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns);

    writefln(
        "               claims=%s items/claim=%.3f claims/item=%.5f",
        aggregateClaims,
        itemsPerClaim,
        claimsPerItem);

    writefln(
        "               empty=%s pushRetries=%s checksum=%s",
        aggregateEmptyAttempts,
        aggregatePushRetries,
        aggregateChecksum);
}

void main(string[] args)
{
    size_t items = 4_000_000;
    size_t thiefCount = 4;
    size_t warmups = 4;
    size_t samples = 15;
    size_t ownerCpu = 2;

    if (args.length > 1)
        items = args[1].to!size_t;

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

    writeln(
        "R0.1 P08d3 batch streaming performance");

    writefln(
        "items=%s thieves=%s warmups=%s samples=%s",
        items,
        thiefCount,
        warmups,
        samples);

    benchmarkVariant!(
        OneQueue,
        QueueKind.one)(
            "steal-one",
            items,
            thiefCount,
            1,
            ownerCpu,
            warmups,
            samples);

    foreach (
        batchSize;
        [1UL, 2UL, 4UL, 8UL, 16UL, 32UL])
    {
        benchmarkVariant!(
            RefQueue,
            QueueKind.referenceBatch)(
                "repeat-steal",
                items,
                thiefCount,
                batchSize,
                ownerCpu,
                warmups,
                samples);

        benchmarkVariant!(
            GateQueue,
            QueueKind.gatedBatch)(
                "single-CAS",
                items,
                thiefCount,
                batchSize,
                ownerCpu,
                warmups,
                samples);
    }

    writeln(
        "R0.1 P08d3 PASS");
}
