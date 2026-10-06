module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_safe_ref :
    SafeReferenceBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_gate :
    GatedBatchBoundedWorkStealingDeque;

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

alias RefQueue =
    SafeReferenceBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias GateQueue =
    GatedBatchBoundedWorkStealingDeque!(
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

enum QueueKind
{
    stealOne,
    repeatedBatch,
    gatedBatch,
    markedBatch
}

struct RunResult
{
    ulong elapsedNs;
    ulong checksum;

    size_t ownerPopped;
    size_t stolen;

    size_t ownerRetries;
    size_t thiefRetries;

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

private RunResult runDrain(
    Queue,
    QueueKind kind)(
    size_t items,
    size_t thiefCount,
    size_t ownerCpu)
{
    if (
        items == 0 ||
        items > Queue.capacity ||
        thiefCount == 0 ||
        thiefCount > MaxThieves)
    {
        throw new Exception(
            "invalid run arguments");
    }

    auto queue =
        new Queue;

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

    shared ulong[MaxThieves] thiefChecksums;
    shared size_t[MaxThieves] thiefCounts;
    shared size_t[MaxThieves] thiefRetries;
    shared size_t[MaxThieves] thiefClaims;

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

                ulong checksum;
                size_t count;
                size_t retries;
                size_t claims;

                size_t[BatchSize] buffer;

                for (;;)
                {
                    static if (
                        kind ==
                        QueueKind.stealOne)
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
                                buffer[]);

                        if (taken != 0)
                        {
                            ++claims;

                            foreach (
                                value;
                                buffer[0 .. taken])
                            {
                                checksum +=
                                    cast(ulong) value;

                                ++count;
                            }

                            continue;
                        }
                    }

                    ++retries;

                    if (queue.emptySnapshot())
                        break;

                    if (
                        (retries & 255) == 0)
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
                        thiefRetries[index],
                        retries);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefClaims[index],
                        claims);
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

    ulong ownerChecksum;
    size_t ownerCount;
    size_t ownerRetries;

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
            ownerChecksum +=
                cast(ulong)
                    result.value;

            ++ownerCount;
            continue;
        }

        ++ownerRetries;

        if (queue.emptySnapshot())
            break;

        if (
            (ownerRetries & 255) == 0)
        {
            Thread.yield();
        }
    }

    foreach (thief; thieves)
        thief.join();

    sw.stop();

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.checksum =
        ownerChecksum;

    result.ownerPopped =
        ownerCount;

    result.ownerRetries =
        ownerRetries;

    foreach (i; 0 .. thiefCount)
    {
        result.checksum +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefChecksums[i]);

        result.stolen +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefCounts[i]);

        result.thiefRetries +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefRetries[i]);

        result.successfulClaims +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefClaims[i]);
    }

    const returned =
        result.ownerPopped +
        result.stolen;

    const expectedChecksum =
        cast(ulong) items *
        cast(ulong)(items + 1) /
        2;

    if (returned != items)
        throw new Exception(
            "returned count mismatch");

    if (
        result.checksum !=
        expectedChecksum)
    {
        throw new Exception(
            "checksum mismatch");
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
            times[p10] /
            items,
        cast(double)
            times[p90] /
            items);
}

private void benchmark(
    Queue,
    QueueKind kind)(
    string name,
    size_t items,
    size_t thiefCount,
    size_t ownerCpu,
    size_t warmups,
    size_t samples)
{
    foreach (_; 0 .. warmups)
    {
        runDrain!(Queue, kind)(
            items,
            thiefCount,
            ownerCpu);
    }

    auto times =
        new ulong[samples];

    ulong aggregateChecksum;

    size_t aggregateOwner;
    size_t aggregateStolen;
    size_t aggregateOwnerRetries;
    size_t aggregateThiefRetries;
    size_t aggregateClaims;

    foreach (i; 0 .. samples)
    {
        const result =
            runDrain!(Queue, kind)(
                items,
                thiefCount,
                ownerCpu);

        times[i] =
            result.elapsedNs;

        aggregateChecksum +=
            result.checksum;

        aggregateOwner +=
            result.ownerPopped;

        aggregateStolen +=
            result.stolen;

        aggregateOwnerRetries +=
            result.ownerRetries;

        aggregateThiefRetries +=
            result.thiefRetries;

        aggregateClaims +=
            result.successfulClaims;
    }

    const stats =
        calculateStats(
            times,
            items);

    const double stolenPerClaim =
        aggregateClaims != 0
            ? cast(double)
                aggregateStolen /
                aggregateClaims
            : 0.0;

    writefln(
        "%-13s median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        name,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns);

    writefln(
        "              owner=%s stolen=%s claims=%s stolen/claim=%.3f",
        aggregateOwner,
        aggregateStolen,
        aggregateClaims,
        stolenPerClaim);

    writefln(
        "              retries owner=%s thief=%s checksum=%s",
        aggregateOwnerRetries,
        aggregateThiefRetries,
        aggregateChecksum);
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
        "R0.1 P08g2 marked-top concurrent owner/thief drain");

    writefln(
        "items=%s capacity=%s thieves=%s batch=%s warmups=%s samples=%s",
        items,
        BaseQueue.capacity,
        thiefCount,
        BatchSize,
        warmups,
        samples);

    benchmark!(
        BaseQueue,
        QueueKind.stealOne)(
            "steal-one",
            items,
            thiefCount,
            ownerCpu,
            warmups,
            samples);

    benchmark!(
        RefQueue,
        QueueKind.repeatedBatch)(
            "repeat-steal",
            items,
            thiefCount,
            ownerCpu,
            warmups,
            samples);

    benchmark!(
        GateQueue,
        QueueKind.gatedBatch)(
            "gated",
            items,
            thiefCount,
            ownerCpu,
            warmups,
            samples);

    benchmark!(
        MarkedQueue,
        QueueKind.markedBatch)(
            "marked-top",
            items,
            thiefCount,
            ownerCpu,
            warmups,
            samples);

    writeln(
        "R0.1 P08g2 PASS");
}
