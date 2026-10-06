module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_full64_marked_top :
    Full64DistanceMarkedBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicLoad,
    atomicOp;

import core.thread :
    Thread;

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
    6;

enum size_t samples =
    24;

shared ulong sink;

private void waitMarked(Q)(ref Q queue)
{
    while (!queue.researchBatchMarkedSnapshot())
    {
        Thread.yield();
    }
}

private ulong measureBusyReject(Q)(
    ref Q queue)
{
    size_t[8] output;

    auto sw =
        StopWatch(
            AutoStart.yes);

    ulong localSink;

    foreach (_; 0 .. operations)
    {
        localSink +=
            queue.stealBatch(
                output[]);
    }

    sw.stop();

    atomicOp!"+="(
        sink,
        localSink);

    return cast(ulong)
        sw.peek.total!"nsecs";
}

private double median(ulong[] values)
{
    import std.algorithm :
        sort;

    sort(values);

    const n =
        values.length;

    if ((n & 1) != 0)
        return cast(double)
            values[n / 2];

    return
        (
            cast(double) values[n / 2 - 1] +
            cast(double) values[n / 2]
        ) / 2.0;
}

private double percentile(
    ulong[] values,
    double p)
{
    import std.algorithm :
        sort;

    sort(values);

    const index =
        cast(size_t)(
            p *
            cast(double)(
                values.length - 1));

    return cast(double)
        values[index];
}

private void runOne(Q)(
    string label)
{
    Q queue;

    foreach (i; 0 .. 32)
    {
        if (!queue.tryPush(i + 1))
            throw new Exception(
                "probe fill failed");
    }

    queue.researchEnableBatchPause();

    size_t[8] markerOutput;

    auto marker =
        new Thread(
            {
                const n =
                    queue.stealBatch(
                        markerOutput[]);

                if (n == 0)
                    throw new Exception(
                        "marker batch failed");
            });

    marker.start();

    waitMarked(queue);

    /*
     * The marker thread now owns the busy state and is paused immediately
     * after publishing it. Every measured stealBatch() must reject it.
     */

    foreach (_; 0 .. warmups)
    {
        const elapsed =
            measureBusyReject(queue);

        if (elapsed == 0)
            throw new Exception(
                "invalid warmup");
    }

    ulong[samples] times;

    foreach (i; 0 .. samples)
    {
        times[i] =
            measureBusyReject(queue);
    }

    queue.researchReleaseBatchPause();
    marker.join();

    foreach (value; markerOutput)
    {
        atomicOp!"+="(
            sink,
            value);
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
            0.10);

    const p90 =
        percentile(
            p90Input[],
            0.90);

    writefln(
        "%-8s busy-reject median=%8.3f ns/op p10/p90=%8.3f/%8.3f",
        label,
        med / operations,
        p10 / operations,
        p90 / operations);
}

void main()
{
    writefln(
        "R0.1 P08g5 busy rejection cost");

    writefln(
        "operations=%s warmups=%s samples=%s",
        operations,
        warmups,
        samples);

    runOne!P08eQueue(
        "p08e");

    runOne!Full64Queue(
        "full64");

    writefln(
        "sink=%s",
        sink);
}
