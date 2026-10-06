module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_full64_marked_top :
    Full64DistanceMarkedBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicLoad;

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
    StopWatch,
    AutoStart;

import std.stdio :
    writefln;

alias P08eQueue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        8);

alias Full64Queue =
    Full64DistanceMarkedBoundedWorkStealingDeque!(
        size_t,
        8);

enum size_t operations =
    8_000_000;

enum size_t warmups =
    4;

enum size_t samples =
    16;

private void pinCurrentThread(
    size_t cpu)
{
    version (linux)
    {
        cpu_set_t mask;

        CPU_SET(
            cpu,
            &mask);

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

private double median(
    ulong[] values)
{
    values.sort();

    const n =
        values.length;

    if ((n & 1) != 0)
        return cast(double)
            values[n / 2];

    return
        (
            cast(double)
                values[n / 2 - 1] +
            cast(double)
                values[n / 2]
        ) / 2.0;
}

private double percentile(
    ulong[] values,
    size_t percent)
{
    values.sort();

    const index =
        (values.length - 1) *
        percent /
        100;

    return cast(double)
        values[index];
}

private ulong measureBusyReject(Q)(
    ref Q queue)
{
    size_t[8] output;

    auto sw =
        StopWatch(
            AutoStart.yes);

    size_t unexpected;

    foreach (_; 0 .. operations)
    {
        const taken =
            queue.stealBatch(
                output[]);

        if (taken != 0)
            ++unexpected;
    }

    sw.stop();

    if (unexpected != 0)
        throw new Exception(
            "busy rejection unexpectedly succeeded");

    return cast(ulong)
        sw.peek.total!"nsecs";
}

private void runSample(Q)(
    ref ulong elapsed,
    ref ulong busyRetries)
{
    auto queue =
        new Q;

    foreach (i; 0 .. 64)
    {
        if (!queue.tryPush(i + 1))
            throw new Exception(
                "prefill failed");
    }

    queue.researchEnableBatchPause();

    size_t[8] markerOutput;

    auto marker =
        new Thread({
            pinCurrentThread(4);

            const n =
                queue.stealBatch(
                    markerOutput[]);

            if (n == 0)
                throw new Exception(
                    "marker batch failed");
        });

    marker.start();

    while (
        !queue.researchBatchMarkedSnapshot())
    {
        Thread.yield();
    }

    /*
     * Owner pop will remain inside its busy-retry loop while the marker is
     * held. That repeatedly touches bottom exactly as in the contested
     * scheduler path.
     */
    auto owner =
        new Thread({
            pinCurrentThread(2);

            const result =
                queue.pop();

            /*
             * It may complete only after the marker is released.
             */
            if (!result.found)
                throw new Exception(
                    "owner pop failed");
        });

    queue.researchResetOwnerBusyRetries();

    owner.start();

    /*
     * Ensure the owner is genuinely exercising the busy rollback loop before
     * timing the thief.
     */
    while (
        queue.researchOwnerBusyRetriesSnapshot() <
        10_000)
    {
        Thread.yield();
    }

    pinCurrentThread(3);

    elapsed =
        measureBusyReject(
            *queue);

    busyRetries =
        queue.researchOwnerBusyRetriesSnapshot();

    queue.researchReleaseBatchPause();

    marker.join();
    owner.join();

    if (queue.researchBatchBusy())
        throw new Exception(
            "busy marker leaked");
}

private void benchmark(Q)(
    string label)
{
    foreach (_; 0 .. warmups)
    {
        ulong elapsed;
        ulong retries;

        runSample!Q(
            elapsed,
            retries);
    }

    ulong[samples] times;

    ulong retryTotal;

    foreach (i; 0 .. samples)
    {
        ulong retries;

        runSample!Q(
            times[i],
            retries);

        retryTotal +=
            retries;
    }

    ulong[samples] medianInput =
        times;

    ulong[samples] p10Input =
        times;

    ulong[samples] p90Input =
        times;

    const med =
        median(
            medianInput[]);

    const p10 =
        percentile(
            p10Input[],
            10);

    const p90 =
        percentile(
            p90Input[],
            90);

    writefln(
        "%-8s contended busy-reject median=%8.3f ns/op "
        ~ "p10/p90=%8.3f/%8.3f ownerBusyRetries=%s",
        label,
        med / operations,
        p10 / operations,
        p90 / operations,
        retryTotal);
}

void main()
{
    writefln(
        "R0.1 P08g6 owner-contended busy rejection");

    writefln(
        "operations=%s warmups=%s samples=%s "
        ~ "ownerCpu=2 thiefCpu=3 markerCpu=4",
        operations,
        warmups,
        samples);

    benchmark!P08eQueue(
        "p08e");

    benchmark!Full64Queue(
        "full64");

    writefln(
        "R0.1 P08g6 PASS");
}
