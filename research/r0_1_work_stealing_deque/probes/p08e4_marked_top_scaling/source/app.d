module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

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
import std.stdio : write, writefln, writeln;

enum size_t LogSize = 20;
enum size_t BatchSize = 8;
enum size_t MaxThieves = 8;

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

immutable size_t[MaxThieves] thiefCpuPool =
[
    3, 4, 1, 5, 0, 9, 10, 7
];

struct RunResult
{
    ulong elapsedNs;
    ulong checksum;

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

private RunResult runDrain(
    size_t items,
    size_t thiefCount,
    size_t ownerCpu)
{
    auto queue =
        new Queue;

    queue.researchResetOwnerBusyRetries();

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

                ulong checksum;
                size_t count;
                size_t claims;
                size_t retries;

                size_t[BatchSize] buffer;

                for (;;)
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

                    ++retries;

                    if (queue.emptySnapshot())
                        break;

                    if ((retries & 255) == 0)
                        Thread.yield();
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
                ready) != thiefCount)
    {
        Thread.yield();
    }

    ulong ownerChecksum;
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
            ownerChecksum +=
                cast(ulong) result.value;

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

    result.checksum =
        ownerChecksum;

    result.ownerPopped =
        ownerCount;

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

        result.claims +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefClaims[i]);

        result.thiefRetries +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefRetries[i]);
    }

    result.ownerBusyRetries =
        queue.researchOwnerBusyRetriesSnapshot();

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

    if (result.checksum != expectedChecksum)
        throw new Exception(
            "checksum mismatch");

    if (queue.researchBatchBusy())
        throw new Exception(
            "busy marker leaked");

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
    size_t items,
    size_t thiefCount,
    size_t ownerCpu,
    size_t warmups,
    size_t samples)
{
    foreach (_; 0 .. warmups)
    {
        runDrain(
            items,
            thiefCount,
            ownerCpu);
    }

    auto times =
        new ulong[samples];

    ulong aggregateChecksum;
    size_t aggregateOwner;
    size_t aggregateStolen;
    size_t aggregateClaims;
    size_t aggregateThiefRetries;
    ulong aggregateOwnerBusyRetries;

    foreach (i; 0 .. samples)
    {
        const result =
            runDrain(
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
        "thieves=%s median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        thiefCount,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns);

    writefln(
        "          owner=%s stolen=%s ownerShare=%.3f%%",
        aggregateOwner,
        aggregateStolen,
        ownerShare);

    writefln(
        "          claims=%s stolen/claim=%.3f",
        aggregateClaims,
        stolenPerClaim);

    writefln(
        "          ownerBusyRetries=%s thiefRetries=%s",
        aggregateOwnerBusyRetries,
        aggregateThiefRetries);

    writefln(
        "          checksum=%s",
        aggregateChecksum);
}

void main(string[] args)
{
    size_t items =
        Queue.capacity;

    size_t warmups = 4;
    size_t samples = 15;
    size_t ownerCpu = 2;

    if (args.length > 1)
        items =
            args[1].to!size_t;

    if (args.length > 2)
        warmups =
            args[2].to!size_t;

    if (args.length > 3)
        samples =
            args[3].to!size_t;

    if (args.length > 4)
        ownerCpu =
            args[4].to!size_t;

    if (
        items == 0 ||
        items > Queue.capacity ||
        samples < 5)
    {
        throw new Exception(
            "invalid arguments");
    }

    writeln(
        "R0.1 P08e4 marked-top scaling and owner progress");

    writefln(
        "items=%s capacity=%s batch=%s warmups=%s samples=%s",
        items,
        Queue.capacity,
        BatchSize,
        warmups,
        samples);

    foreach (
        thiefCount;
        [1UL, 2UL, 4UL, 8UL])
    {
        benchmark(
            items,
            thiefCount,
            ownerCpu,
            warmups,
            samples);
    }

    writeln(
        "R0.1 P08e4 PASS");
}
