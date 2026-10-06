module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_safe_ref :
    SafeReferenceBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_gate :
    GatedBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_full64_marked_top :
    Full64DistanceMarkedBoundedWorkStealingDeque;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln, writeln;

enum size_t LogSize = 18;

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

struct Result
{
    ulong elapsedNs;
    ulong checksum;
}

struct Stats
{
    double medianNs;
    double p10Ns;
    double p90Ns;
}

private Result popMany(Queue)()
{
    auto queue =
        new Queue;

    foreach (i; 0 .. Queue.capacity)
    {
        const pushed =
            queue.tryPush(i + 1);

        if (!pushed)
            throw new Exception(
                "pop-many preparation push failed");
    }

    if (
        queue.sizeSnapshot() !=
        Queue.capacity)
    {
        throw new Exception(
            "pop-many preparation size mismatch");
    }

    ulong checksum;

    StopWatch sw;
    sw.start();

    foreach (_; 0 .. Queue.capacity)
    {
        const result =
            queue.pop();

        if (!result.found)
            throw new Exception(
                "pop-many unexpected empty");

        checksum +=
            cast(ulong)
                result.value;
    }

    sw.stop();

    if (!queue.emptySnapshot())
        throw new Exception(
            "pop-many queue not empty");

    return Result(
        cast(ulong)
            sw.peek.total!"nsecs",
        checksum);
}

private Result pushPopPair(
    Queue)(
    size_t operations)
{
    auto queue =
        new Queue;

    ulong checksum;

    StopWatch sw;
    sw.start();

    foreach (i; 0 .. operations)
    {
        const value =
            i + 1;

        if (!queue.tryPush(value))
            throw new Exception(
                "pair push failed");

        const result =
            queue.pop();

        if (!result.found)
            throw new Exception(
                "pair pop failed");

        checksum +=
            cast(ulong)
                result.value;
    }

    sw.stop();

    if (!queue.emptySnapshot())
        throw new Exception(
            "pair queue not empty");

    return Result(
        cast(ulong)
            sw.peek.total!"nsecs",
        checksum);
}

private Stats calculateStats(
    ulong[] times,
    size_t operations)
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
        median / operations,
        cast(double)
            times[p10] /
            operations,
        cast(double)
            times[p90] /
            operations);
}

private void benchmarkPopMany(
    Queue)(
    string name,
    size_t warmups,
    size_t samples)
{
    foreach (_; 0 .. warmups)
        popMany!Queue();

    auto times =
        new ulong[samples];

    ulong checksum;

    foreach (i; 0 .. samples)
    {
        const result =
            popMany!Queue();

        times[i] =
            result.elapsedNs;

        checksum +=
            result.checksum;
    }

    const result =
        calculateStats(
            times,
            Queue.capacity);

    writefln(
        "%-12s pop-many median=%8.3f ns/op p10/p90=%8.3f/%8.3f checksum=%s",
        name,
        result.medianNs,
        result.p10Ns,
        result.p90Ns,
        checksum);
}

private void benchmarkPair(
    Queue)(
    string name,
    size_t operations,
    size_t warmups,
    size_t samples)
{
    foreach (_; 0 .. warmups)
    {
        pushPopPair!Queue(
            operations);
    }

    auto times =
        new ulong[samples];

    ulong checksum;

    foreach (i; 0 .. samples)
    {
        const result =
            pushPopPair!Queue(
                operations);

        times[i] =
            result.elapsedNs;

        checksum +=
            result.checksum;
    }

    const result =
        calculateStats(
            times,
            operations);

    writefln(
        "%-12s pair     median=%8.3f ns/op p10/p90=%8.3f/%8.3f checksum=%s",
        name,
        result.medianNs,
        result.p10Ns,
        result.p90Ns,
        checksum);
}

void main(string[] args)
{
    size_t operations =
        4_000_000;

    size_t warmups = 6;
    size_t samples = 24;

    if (args.length > 1)
        operations =
            args[1].to!size_t;

    if (args.length > 2)
        warmups =
            args[2].to!size_t;

    if (args.length > 3)
        samples =
            args[3].to!size_t;

    if (
        operations == 0 ||
        samples < 5)
    {
        throw new Exception(
            "invalid arguments");
    }

    writeln(
        "R0.1 P08g2 marked-top owner hot-path cost");

    writefln(
        "capacity=%s operations=%s warmups=%s samples=%s",
        BaseQueue.capacity,
        operations,
        warmups,
        samples);

    benchmarkPopMany!BaseQueue(
        "baseline",
        warmups,
        samples);

    benchmarkPopMany!RefQueue(
        "safe-ref",
        warmups,
        samples);

    benchmarkPopMany!GateQueue(
        "gated",
        warmups,
        samples);

    benchmarkPopMany!MarkedQueue(
        "marked-top",
        warmups,
        samples);

    benchmarkPair!BaseQueue(
        "baseline",
        operations,
        warmups,
        samples);

    benchmarkPair!RefQueue(
        "safe-ref",
        operations,
        warmups,
        samples);

    benchmarkPair!GateQueue(
        "gated",
        operations,
        warmups,
        samples);

    benchmarkPair!MarkedQueue(
        "marked-top",
        operations,
        warmups,
        samples);

    writeln(
        "R0.1 P08g2 PASS");
}
