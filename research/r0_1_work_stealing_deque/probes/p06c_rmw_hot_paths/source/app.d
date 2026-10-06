module app;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_rmw :
    ModularRmwBoundedWorkStealingDeque;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln, writeln;

enum size_t LogSize = 18;

alias BaselineQueue =
    ModularBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias RmwQueue =
    ModularRmwBoundedWorkStealingDeque!(
        size_t,
        LogSize);

enum Workload
{
    pushOnly,
    popMany,
    pushPopPair,
    emptySteal,
    successfulSteal
}

enum size_t defaultWarmups = 6;
enum size_t defaultSamples = 24;

struct Stats
{
    double medianNs;
    double p10Ns;
    double p90Ns;
}

private void reset(Q)(ref Q queue)
{
    queue.researchSetEmptyIndex(0);
}

private void fill(Q)(ref Q queue)
{
    reset(queue);

    foreach (i; 0 .. Q.capacity)
    {
        const pushed =
            queue.tryPush(i + 1);

        if (!pushed)
            throw new Exception(
                "benchmark preparation push failed");
    }

    if (queue.sizeSnapshot() != Q.capacity)
        throw new Exception(
            "benchmark preparation size mismatch");
}

private void prepare(
    Q,
    Workload workload)(
    ref Q queue)
{
    static if (
        workload ==
        Workload.pushOnly)
    {
        reset(queue);
    }
    else static if (
        workload ==
        Workload.popMany)
    {
        fill(queue);
    }
    else static if (
        workload ==
        Workload.pushPopPair)
    {
        reset(queue);

        const first =
            queue.tryPush(1);

        const second =
            queue.tryPush(2);

        if (!first || !second)
            throw new Exception(
                "benchmark pair preparation push failed");

        if (queue.sizeSnapshot() != 2)
            throw new Exception(
                "benchmark pair preparation size mismatch");

    }
    else static if (
        workload ==
        Workload.emptySteal)
    {
        reset(queue);
    }
    else static if (
        workload ==
        Workload.successfulSteal)
    {
        fill(queue);
    }
}

private ulong timedRun(
    Q,
    Workload workload)(
    ref Q queue,
    ref ulong checksum)
{
    StopWatch sw;
    ulong localChecksum;

    sw.start();

    static if (
        workload ==
        Workload.pushOnly)
    {
        foreach (i; 0 .. Q.capacity)
        {
            const ok =
                queue.tryPush(i + 1);

            localChecksum +=
                cast(ulong) ok;
        }
    }
    else static if (
        workload ==
        Workload.popMany)
    {
        foreach (_; 0 .. Q.capacity - 1)
        {
            const result =
                queue.pop();

            localChecksum +=
                result.value;

            localChecksum +=
                cast(ulong) result.found;
        }
    }
    else static if (
        workload ==
        Workload.pushPopPair)
    {
        foreach (i; 0 .. Q.capacity)
        {
            const ok =
                queue.tryPush(i + 3);

            const result =
                queue.pop();

            localChecksum +=
                cast(ulong) ok;

            localChecksum +=
                result.value;

            localChecksum +=
                cast(ulong) result.found;
        }
    }
    else static if (
        workload ==
        Workload.emptySteal)
    {
        foreach (_; 0 .. Q.capacity)
        {
            const result =
                queue.steal();

            localChecksum +=
                cast(ulong) result.found;

            localChecksum +=
                result.value;
        }
    }
    else static if (
        workload ==
        Workload.successfulSteal)
    {
        foreach (_; 0 .. Q.capacity)
        {
            const result =
                queue.steal();

            localChecksum +=
                cast(ulong) result.found;

            localChecksum +=
                result.value;
        }
    }

    sw.stop();

    checksum += localChecksum;

    return cast(ulong)
        sw.peek.total!"nsecs";
}

private size_t operationsPerSample(
    Workload workload)
{
    final switch (workload)
    {
        case Workload.pushOnly:
            return BaselineQueue.capacity;

        case Workload.popMany:
            return BaselineQueue.capacity - 1;

        case Workload.pushPopPair:
            return BaselineQueue.capacity;

        case Workload.emptySteal:
            return BaselineQueue.capacity;

        case Workload.successfulSteal:
            return BaselineQueue.capacity;
    }
}

private string workloadName(
    Workload workload)
{
    final switch (workload)
    {
        case Workload.pushOnly:
            return "push";

        case Workload.popMany:
            return "pop-many";

        case Workload.pushPopPair:
            return "push-pop-pair";

        case Workload.emptySteal:
            return "empty-steal";

        case Workload.successfulSteal:
            return "successful-steal";
    }
}

private ulong runOne(
    Q,
    Workload workload)(
    ref Q queue,
    ref ulong checksum)
{
    prepare!(Q, workload)(queue);

    return timedRun!(Q, workload)(
        queue,
        checksum);
}

private Stats calculateStats(
    ulong[] times,
    size_t operations)
{
    times.sort();

    const n = times.length;

    const median =
        n % 2
            ? cast(double) times[n / 2]
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
        median / operations;

    result.p10Ns =
        cast(double)
            times[p10Index] /
        operations;

    result.p90Ns =
        cast(double)
            times[p90Index] /
        operations;

    return result;
}

private void report(
    string name,
    Stats baseline,
    Stats rmw)
{
    const ratio =
        rmw.medianNs /
        baseline.medianNs;

    writefln(
        "%-18s baseline=%8.3f ns/op  rmw=%8.3f ns/op  ratio=%6.3fx",
        name,
        baseline.medianNs,
        rmw.medianNs,
        ratio);

    writefln(
        "%-18s baseline p10/p90=%8.3f/%8.3f  rmw p10/p90=%8.3f/%8.3f",
        "",
        baseline.p10Ns,
        baseline.p90Ns,
        rmw.p10Ns,
        rmw.p90Ns);
}

private void benchmarkWorkload(
    Workload workload)(
    ref BaselineQueue baselineQueue,
    ref RmwQueue rmwQueue,
    size_t warmups,
    size_t samples,
    ref ulong checksum)
{
    foreach (i; 0 .. warmups)
    {
        if ((i & 1) == 0)
        {
            runOne!(
                BaselineQueue,
                workload)(
                    baselineQueue,
                    checksum);

            runOne!(
                RmwQueue,
                workload)(
                    rmwQueue,
                    checksum);
        }
        else
        {
            runOne!(
                RmwQueue,
                workload)(
                    rmwQueue,
                    checksum);

            runOne!(
                BaselineQueue,
                workload)(
                    baselineQueue,
                    checksum);
        }
    }

    auto baselineTimes =
        new ulong[samples];

    auto rmwTimes =
        new ulong[samples];

    foreach (i; 0 .. samples)
    {
        if ((i & 1) == 0)
        {
            baselineTimes[i] =
                runOne!(
                    BaselineQueue,
                    workload)(
                        baselineQueue,
                        checksum);

            rmwTimes[i] =
                runOne!(
                    RmwQueue,
                    workload)(
                        rmwQueue,
                        checksum);
        }
        else
        {
            rmwTimes[i] =
                runOne!(
                    RmwQueue,
                    workload)(
                        rmwQueue,
                        checksum);

            baselineTimes[i] =
                runOne!(
                    BaselineQueue,
                    workload)(
                        baselineQueue,
                        checksum);
        }
    }

    const operations =
        operationsPerSample(workload);

    const baselineStats =
        calculateStats(
            baselineTimes,
            operations);

    const rmwStats =
        calculateStats(
            rmwTimes,
            operations);

    report(
        workloadName(workload),
        baselineStats,
        rmwStats);
}

void main(string[] args)
{
    size_t warmups =
        defaultWarmups;

    size_t samples =
        defaultSamples;

    if (args.length > 1)
        warmups =
            args[1].to!size_t;

    if (args.length > 2)
        samples =
            args[2].to!size_t;

    assert(samples >= 5);

    auto baselineQueue =
        new BaselineQueue;

    auto rmwQueue =
        new RmwQueue;

    ulong checksum;

    writeln(
        "R0.1 P06c modular baseline versus RMW hot paths");

    writefln(
        "capacity=%s warmups=%s samples=%s",
        BaselineQueue.capacity,
        warmups,
        samples);

    benchmarkWorkload!(
        Workload.pushOnly)(
            *baselineQueue,
            *rmwQueue,
            warmups,
            samples,
            checksum);

    benchmarkWorkload!(
        Workload.popMany)(
            *baselineQueue,
            *rmwQueue,
            warmups,
            samples,
            checksum);

    benchmarkWorkload!(
        Workload.pushPopPair)(
            *baselineQueue,
            *rmwQueue,
            warmups,
            samples,
            checksum);

    benchmarkWorkload!(
        Workload.emptySteal)(
            *baselineQueue,
            *rmwQueue,
            warmups,
            samples,
            checksum);

    benchmarkWorkload!(
        Workload.successfulSteal)(
            *baselineQueue,
            *rmwQueue,
            warmups,
            samples,
            checksum);

    writefln(
        "checksum=%s",
        checksum);

    writeln(
        "R0.1 P06c PASS");
}
