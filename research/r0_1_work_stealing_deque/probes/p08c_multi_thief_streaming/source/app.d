module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

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

enum size_t LogSize = 12;

alias Queue =
    ModularRmwPaddedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

enum size_t maxThieves = 8;

enum size_t defaultItems =
    4_000_000;

enum size_t defaultWarmups = 4;
enum size_t defaultSamples = 15;

immutable size_t[maxThieves] thiefCpuPool =
[
    3,  // core 3
    4,  // core 4
    1,  // core 1
    5,  // core 5
    0,  // core 0
    9,  // SMT sibling of CPU 3
    10, // SMT sibling of CPU 4
    7   // SMT sibling of CPU 1
];

struct RunResult
{
    ulong elapsedNs;
    ulong checksum;
    size_t stolen;
    size_t pushRetries;
    size_t stealRetries;
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
    }
    else
    {
        throw new Exception(
            "P08c affinity probe requires Linux");
    }
}

private size_t currentCpu()
{
    version (linux)
    {
        const cpu =
            sched_getcpu();

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

private RunResult runConcurrent(
    size_t items,
    size_t thiefCount,
    size_t ownerCpu)
{
    if (
        thiefCount == 0 ||
        thiefCount > maxThieves)
    {
        throw new Exception(
            "invalid thief count");
    }

    auto queue =
        new Queue;

    shared bool start;
    shared bool ownerDone;

    shared size_t nextThiefIndex;

    shared ulong[maxThieves] thiefChecksums;
    shared size_t[maxThieves] thiefCounts;
    shared size_t[maxThieves] thiefRetries;

    auto thieves =
        new Thread[thiefCount];

    foreach (i; 0 .. thiefCount)
    {
        thieves[i] =
            new Thread({
                const index =
                    atomicFetchAdd!(
                        MemoryOrder.raw)(
                            nextThiefIndex,
                            1);

                if (index >= thiefCount)
                    throw new Exception(
                        "thief index overflow");

                const cpu =
                    thiefCpuPool[index];

                pinCurrentThread(cpu);

                if (currentCpu() != cpu)
                    throw new Exception(
                        "thief affinity verification failed");

                while (
                    !atomicLoad!(
                        MemoryOrder.acq)(
                            start))
                {
                    Thread.yield();
                }

                ulong localChecksum;
                size_t localCount;
                size_t localRetries;

                for (;;)
                {
                    const result =
                        queue.steal();

                    if (result.found)
                    {
                        localChecksum +=
                            cast(ulong)
                                result.value;

                        ++localCount;
                        continue;
                    }

                    ++localRetries;

                    if (
                        atomicLoad!(
                            MemoryOrder.acq)(
                                ownerDone))
                    {
                        /*
                         * No producer can add more work after ownerDone.
                         *
                         * A failed steal after observing ownerDone therefore
                         * means this thief can terminate. Other thieves may
                         * still hold or remove already claimed items, which
                         * are accounted independently after join.
                         */
                        break;
                    }

                    if (
                        (localRetries & 255) == 0)
                    {
                        Thread.yield();
                    }
                }

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefChecksums[index],
                        localChecksum);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefCounts[index],
                        localCount);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefRetries[index],
                        localRetries);
            });

        thieves[i].start();
    }

    pinCurrentThread(ownerCpu);

    if (currentCpu() != ownerCpu)
        throw new Exception(
            "owner affinity verification failed");

    /*
     * Wait until every thief has claimed a stable index and reached at
     * least the affinity/start phase before releasing the benchmark.
     */
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

    ulong checksum;
    size_t stolen;
    size_t aggregateStealRetries;

    foreach (i; 0 .. thiefCount)
    {
        checksum +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefChecksums[i]);

        stolen +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefCounts[i]);

        aggregateStealRetries +=
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefRetries[i]);
    }

    const expectedChecksum =
        cast(ulong) items *
        cast(ulong)(items + 1) /
        2;

    if (stolen != items)
        throw new Exception(
            "P08c accounting failure");

    if (checksum != expectedChecksum)
        throw new Exception(
            "P08c checksum failure");

    if (!queue.emptySnapshot())
        throw new Exception(
            "P08c queue not empty");

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.checksum =
        checksum;

    result.stolen =
        stolen;

    result.pushRetries =
        pushRetries;

    result.stealRetries =
        aggregateStealRetries;

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

    const p10Index =
        (n - 1) * 10 / 100;

    const p90Index =
        (n - 1) * 90 / 100;

    Stats result;

    result.medianNs =
        median / items;

    result.p10Ns =
        cast(double)
            times[p10Index] /
        items;

    result.p90Ns =
        cast(double)
            times[p90Index] /
        items;

    return result;
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
        runConcurrent(
            items,
            thiefCount,
            ownerCpu);
    }

    auto times =
        new ulong[samples];

    ulong aggregateChecksum;
    size_t aggregatePushRetries;
    size_t aggregateStealRetries;

    foreach (i; 0 .. samples)
    {
        const result =
            runConcurrent(
                items,
                thiefCount,
                ownerCpu);

        times[i] =
            result.elapsedNs;

        aggregateChecksum +=
            result.checksum;

        aggregatePushRetries +=
            result.pushRetries;

        aggregateStealRetries +=
            result.stealRetries;
    }

    const stats =
        calculateStats(
            times,
            items);

    writefln(
        "thieves=%s median=%8.3f ns/item p10/p90=%8.3f/%8.3f",
        thiefCount,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns);

    writefln(
        "           retries push=%s steal=%s",
        aggregatePushRetries,
        aggregateStealRetries);

    writefln(
        "           checksum=%s",
        aggregateChecksum);
}

private void printTopology(
    size_t ownerCpu,
    size_t thiefCount)
{
    write(
        "ownerCpu=",
        ownerCpu,
        " thieves=");

    foreach (i; 0 .. thiefCount)
    {
        if (i != 0)
            write(",");

        write(
            thiefCpuPool[i]);
    }

    writeln();
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

    if (args.length > 1)
        items = args[1].to!size_t;

    if (args.length > 2)
        warmups = args[2].to!size_t;

    if (args.length > 3)
        samples = args[3].to!size_t;

    if (args.length > 4)
        ownerCpu = args[4].to!size_t;

    if (
        items == 0 ||
        samples < 5)
    {
        throw new Exception(
            "invalid benchmark arguments");
    }

    writeln(
        "R0.1 P08c one-owner multi-thief streaming");

    writefln(
        "items=%s capacity=%s warmups=%s samples=%s",
        items,
        Queue.capacity,
        warmups,
        samples);

    foreach (
        thiefCount;
        [1UL, 2UL, 4UL, 8UL])
    {
        printTopology(
            ownerCpu,
            thiefCount);

        benchmark(
            items,
            thiefCount,
            ownerCpu,
            warmups,
            samples);
    }

    writeln(
        "R0.1 P08c PASS");
}
