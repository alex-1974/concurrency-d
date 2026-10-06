module app;

import concurrency.research.modular_bounded_wsq_rmw :
    ModularRmwBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
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

alias CompactQueue =
    ModularRmwBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias PaddedQueue =
    ModularRmwPaddedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

enum size_t defaultItems =
    4_000_000;

enum size_t defaultWarmups = 4;
enum size_t defaultSamples = 15;

struct Stats
{
    double medianNs;
    double p10Ns;
    double p90Ns;
}

struct RunResult
{
    ulong elapsedNs;
    ulong checksum;
    size_t pushRetries;
    size_t stealRetries;
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
    }
    else
    {
        throw new Exception(
            "P08 affinity probe requires Linux");
    }
}

private size_t currentCpu()
{
    version (linux)
    {
        const cpu = sched_getcpu();

        if (cpu < 0)
            throw new Exception(
                "sched_getcpu failed");

        return cast(size_t) cpu;
    }
    else
    {
        return size_t.max;
    }
}

private RunResult runConcurrent(Q)(
    size_t items,
    size_t ownerCpu,
    size_t thiefCpu)
{
    auto queue = new Q;

    shared bool start;
    shared bool ownerDone;

    shared ulong thiefChecksum;
    shared size_t thiefCount;
    shared size_t thiefRetries;

    auto thief = new Thread({
        pinCurrentThread(thiefCpu);

        if (currentCpu() != thiefCpu)
            throw new Exception(
                "thief affinity verification failed");

        while (!atomicLoad!(MemoryOrder.acq)(start))
            Thread.yield();

        ulong localChecksum;
        size_t localCount;
        size_t localRetries;

        while (localCount < items)
        {
            const result = queue.steal();

            if (result.found)
            {
                localChecksum +=
                    cast(ulong) result.value;

                ++localCount;
            }
            else
            {
                ++localRetries;

                /*
                 * Keep the retry path realistic without adding a blocking
                 * synchronization primitive to the deque benchmark.
                 */
                if ((localRetries & 255) == 0)
                    Thread.yield();
            }
        }

        atomicStore!(MemoryOrder.rel)(
            thiefChecksum,
            localChecksum);

        atomicStore!(MemoryOrder.rel)(
            thiefCount,
            localCount);

        atomicStore!(MemoryOrder.rel)(
            thiefRetries,
            localRetries);
    });

    thief.start();

    pinCurrentThread(ownerCpu);

    if (currentCpu() != ownerCpu)
        throw new Exception(
            "owner affinity verification failed");

    StopWatch sw;

    size_t pushRetries;

    atomicStore!(MemoryOrder.rel)(
        start,
        true);

    sw.start();

    foreach (i; 0 .. items)
    {
        const value = i + 1;

        while (!queue.tryPush(value))
        {
            ++pushRetries;

            if ((pushRetries & 255) == 0)
                Thread.yield();
        }
    }

    atomicStore!(MemoryOrder.rel)(
        ownerDone,
        true);

    thief.join();

    sw.stop();

    const count =
        atomicLoad!(MemoryOrder.acq)(
            thiefCount);

    const checksum =
        atomicLoad!(MemoryOrder.acq)(
            thiefChecksum);

    const stealRetries =
        atomicLoad!(MemoryOrder.acq)(
            thiefRetries);

    const expectedChecksum =
        cast(ulong) items *
        cast(ulong)(items + 1) / 2;

    if (count != items)
        throw new Exception(
            "P08 accounting failure");

    if (checksum != expectedChecksum)
        throw new Exception(
            "P08 checksum failure");

    if (!queue.emptySnapshot())
        throw new Exception(
            "P08 queue not empty");

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.checksum =
        checksum;

    result.pushRetries =
        pushRetries;

    result.stealRetries =
        stealRetries;

    return result;
}

private Stats calculateStats(
    ulong[] times,
    size_t items)
{
    times.sort();

    const n = times.length;

    const median =
        n % 2
            ? cast(double) times[n / 2]
            : (
                cast(double) times[n / 2 - 1] +
                cast(double) times[n / 2]
              ) / 2.0;

    const p10Index =
        (n - 1) * 10 / 100;

    const p90Index =
        (n - 1) * 90 / 100;

    Stats result;

    result.medianNs =
        median / items;

    result.p10Ns =
        cast(double) times[p10Index] /
        items;

    result.p90Ns =
        cast(double) times[p90Index] /
        items;

    return result;
}

private void runWarmup(Q)(
    size_t items,
    size_t warmups,
    size_t ownerCpu,
    size_t thiefCpu)
{
    foreach (_; 0 .. warmups)
        runConcurrent!Q(items, ownerCpu, thiefCpu);
}

private ulong[] measure(Q)(
    size_t items,
    size_t samples,
    size_t ownerCpu,
    size_t thiefCpu,
    ref ulong aggregateChecksum,
    ref size_t aggregatePushRetries,
    ref size_t aggregateStealRetries)
{
    auto times =
        new ulong[samples];

    foreach (i; 0 .. samples)
    {
        const result =
            runConcurrent!Q(items, ownerCpu, thiefCpu);

        times[i] =
            result.elapsedNs;

        aggregateChecksum +=
            result.checksum;

        aggregatePushRetries +=
            result.pushRetries;

        aggregateStealRetries +=
            result.stealRetries;
    }

    return times;
}

void main(string[] args)
{
    size_t items =
        defaultItems;

    size_t warmups =
        defaultWarmups;

    size_t samples =
        defaultSamples;

    size_t ownerCpu = 2;
    size_t thiefCpu = 3;

    if (args.length > 1)
        items = args[1].to!size_t;

    if (args.length > 2)
        warmups = args[2].to!size_t;

    if (args.length > 3)
        samples = args[3].to!size_t;

    if (args.length > 4)
        ownerCpu = args[4].to!size_t;

    if (args.length > 5)
        thiefCpu = args[5].to!size_t;

    if (items == 0 || samples < 5)
        throw new Exception(
            "invalid benchmark arguments");

    writeln(
        "R0.1 P08 layout / false-sharing control");

    writefln(
        "items=%s capacity=%s warmups=%s samples=%s",
        items,
        CompactQueue.capacity,
        warmups,
        samples);

    writefln(
        "ownerCpu=%s thiefCpu=%s",
        ownerCpu,
        thiefCpu);

    writefln(
        "compact sizeof=%s alignof=%s",
        CompactQueue.sizeof,
        CompactQueue.alignof);

    writefln(
        "padded  sizeof=%s alignof=%s",
        PaddedQueue.sizeof,
        PaddedQueue.alignof);

    /*
     * Alternate warm-up order.
     */
    foreach (i; 0 .. warmups)
    {
        if ((i & 1) == 0)
        {
            runConcurrent!CompactQueue(items, ownerCpu, thiefCpu);
            runConcurrent!PaddedQueue(items, ownerCpu, thiefCpu);
        }
        else
        {
            runConcurrent!PaddedQueue(items, ownerCpu, thiefCpu);
            runConcurrent!CompactQueue(items, ownerCpu, thiefCpu);
        }
    }

    auto compactTimes =
        new ulong[samples];

    auto paddedTimes =
        new ulong[samples];

    ulong compactChecksum;
    ulong paddedChecksum;

    size_t compactPushRetries;
    size_t compactStealRetries;
    size_t paddedPushRetries;
    size_t paddedStealRetries;

    foreach (i; 0 .. samples)
    {
        if ((i & 1) == 0)
        {
            const compact =
                runConcurrent!CompactQueue(items, ownerCpu, thiefCpu);

            const padded =
                runConcurrent!PaddedQueue(items, ownerCpu, thiefCpu);

            compactTimes[i] =
                compact.elapsedNs;

            paddedTimes[i] =
                padded.elapsedNs;

            compactChecksum +=
                compact.checksum;

            paddedChecksum +=
                padded.checksum;

            compactPushRetries +=
                compact.pushRetries;

            compactStealRetries +=
                compact.stealRetries;

            paddedPushRetries +=
                padded.pushRetries;

            paddedStealRetries +=
                padded.stealRetries;
        }
        else
        {
            const padded =
                runConcurrent!PaddedQueue(items, ownerCpu, thiefCpu);

            const compact =
                runConcurrent!CompactQueue(items, ownerCpu, thiefCpu);

            compactTimes[i] =
                compact.elapsedNs;

            paddedTimes[i] =
                padded.elapsedNs;

            compactChecksum +=
                compact.checksum;

            paddedChecksum +=
                padded.checksum;

            compactPushRetries +=
                compact.pushRetries;

            compactStealRetries +=
                compact.stealRetries;

            paddedPushRetries +=
                padded.pushRetries;

            paddedStealRetries +=
                padded.stealRetries;
        }
    }

    const compactStats =
        calculateStats(
            compactTimes,
            items);

    const paddedStats =
        calculateStats(
            paddedTimes,
            items);

    writefln(
        "compact median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        compactStats.medianNs,
        compactStats.p10Ns,
        compactStats.p90Ns);

    writefln(
        "padded  median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        paddedStats.medianNs,
        paddedStats.p10Ns,
        paddedStats.p90Ns);

    writefln(
        "ratio padded/compact=%6.3fx",
        paddedStats.medianNs /
            compactStats.medianNs);

    writefln(
        "compact retries push=%s steal=%s",
        compactPushRetries,
        compactStealRetries);

    writefln(
        "padded  retries push=%s steal=%s",
        paddedPushRetries,
        paddedStealRetries);

    writefln(
        "checksums compact=%s padded=%s",
        compactChecksum,
        paddedChecksum);

    if (compactChecksum != paddedChecksum)
        throw new Exception(
            "variant checksum mismatch");

    writeln("R0.1 P08 PASS");
}
