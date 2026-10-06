module app;

import concurrency.research.bounded_wsq :
    BoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln, writeln;

enum size_t LogSize = 18;

alias SignedQueue =
    BoundedWorkStealingDeque!(size_t, LogSize);

alias ModularQueue =
    ModularBoundedWorkStealingDeque!(size_t, LogSize);

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
        assert(queue.tryPush(i + 1));

    assert(queue.sizeSnapshot() == Q.capacity);
}

private void prepare(Q, Workload workload)(ref Q queue)
{
    static if (workload == Workload.pushOnly)
    {
        reset(queue);
    }
    else static if (workload == Workload.popMany)
    {
        fill(queue);
    }
    else static if (workload == Workload.pushPopPair)
    {
        reset(queue);

        assert(queue.tryPush(1));
        assert(queue.tryPush(2));

        assert(queue.sizeSnapshot() == 2);
    }
    else static if (workload == Workload.emptySteal)
    {
        reset(queue);
    }
    else static if (workload == Workload.successfulSteal)
    {
        fill(queue);
    }
}

private ulong timedRun(Q, Workload workload)(
    ref Q queue,
    ref ulong checksum)
{
    StopWatch sw;

    ulong localChecksum;

    sw.start();

    static if (workload == Workload.pushOnly)
    {
        foreach (i; 0 .. Q.capacity)
        {
            const ok = queue.tryPush(i + 1);

            localChecksum += cast(ulong) ok;
        }
    }
    else static if (workload == Workload.popMany)
    {
        /*
         * Leave one item behind so the timed region measures the common
         * owner-pop path, not the special last-item CAS path.
         */
        foreach (_; 0 .. Q.capacity - 1)
        {
            const result = queue.pop();

            localChecksum += result.value;
            localChecksum += cast(ulong) result.found;
        }
    }
    else static if (workload == Workload.pushPopPair)
    {
        /*
         * Maintain occupancy=2.
         *
         * Every timed pop therefore uses the ordinary multi-item owner path,
         * not the last-item race protocol.
         */
        foreach (i; 0 .. Q.capacity)
        {
            const ok = queue.tryPush(i + 3);
            const result = queue.pop();

            localChecksum += cast(ulong) ok;
            localChecksum += result.value;
            localChecksum += cast(ulong) result.found;
        }
    }
    else static if (workload == Workload.emptySteal)
    {
        foreach (_; 0 .. Q.capacity)
        {
            const result = queue.steal();

            localChecksum += cast(ulong) result.found;
            localChecksum += result.value;
        }
    }
    else static if (workload == Workload.successfulSteal)
    {
        foreach (_; 0 .. Q.capacity)
        {
            const result = queue.steal();

            localChecksum += cast(ulong) result.found;
            localChecksum += result.value;
        }
    }

    sw.stop();

    checksum += localChecksum;

    return cast(ulong) sw.peek.total!"nsecs";
}

private size_t operationsPerSample(Workload workload)
{
    final switch (workload)
    {
        case Workload.pushOnly:
            return SignedQueue.capacity;

        case Workload.popMany:
            return SignedQueue.capacity - 1;

        case Workload.pushPopPair:
            /*
             * One logical benchmark operation is one push+pop pair.
             */
            return SignedQueue.capacity;

        case Workload.emptySteal:
            return SignedQueue.capacity;

        case Workload.successfulSteal:
            return SignedQueue.capacity;
    }
}

private string workloadName(Workload workload)
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

private ulong runOne(Q, Workload workload)(
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
                cast(double) times[n / 2 - 1] +
                cast(double) times[n / 2]
              ) / 2.0;

    const p10Index =
        (n - 1) * 10 / 100;

    const p90Index =
        (n - 1) * 90 / 100;

    Stats result;

    result.medianNs =
        median / operations;

    result.p10Ns =
        cast(double) times[p10Index] /
        operations;

    result.p90Ns =
        cast(double) times[p90Index] /
        operations;

    return result;
}

private void report(
    string name,
    Stats signedStats,
    Stats modularStats)
{
    const ratio =
        modularStats.medianNs /
        signedStats.medianNs;

    writefln(
        "%-18s signed=%8.3f ns/op  modular=%8.3f ns/op  ratio=%6.3fx",
        name,
        signedStats.medianNs,
        modularStats.medianNs,
        ratio);

    writefln(
        "%-18s signed p10/p90=%8.3f/%8.3f  modular p10/p90=%8.3f/%8.3f",
        "",
        signedStats.p10Ns,
        signedStats.p90Ns,
        modularStats.p10Ns,
        modularStats.p90Ns);
}

private void benchmarkWorkload(Workload workload)(
    ref SignedQueue signedQueue,
    ref ModularQueue modularQueue,
    size_t warmups,
    size_t samples,
    ref ulong checksum)
{
    /*
     * Warm-up with alternating order.
     */
    foreach (i; 0 .. warmups)
    {
        if ((i & 1) == 0)
        {
            runOne!(SignedQueue, workload)(
                signedQueue,
                checksum);

            runOne!(ModularQueue, workload)(
                modularQueue,
                checksum);
        }
        else
        {
            runOne!(ModularQueue, workload)(
                modularQueue,
                checksum);

            runOne!(SignedQueue, workload)(
                signedQueue,
                checksum);
        }
    }

    auto signedTimes =
        new ulong[samples];

    auto modularTimes =
        new ulong[samples];

    foreach (i; 0 .. samples)
    {
        if ((i & 1) == 0)
        {
            signedTimes[i] =
                runOne!(SignedQueue, workload)(
                    signedQueue,
                    checksum);

            modularTimes[i] =
                runOne!(ModularQueue, workload)(
                    modularQueue,
                    checksum);
        }
        else
        {
            modularTimes[i] =
                runOne!(ModularQueue, workload)(
                    modularQueue,
                    checksum);

            signedTimes[i] =
                runOne!(SignedQueue, workload)(
                    signedQueue,
                    checksum);
        }
    }

    const operations =
        operationsPerSample(workload);

    const signedStats =
        calculateStats(
            signedTimes,
            operations);

    const modularStats =
        calculateStats(
            modularTimes,
            operations);

    report(
        workloadName(workload),
        signedStats,
        modularStats);
}

void main(string[] args)
{
    size_t warmups =
        defaultWarmups;

    size_t samples =
        defaultSamples;

    if (args.length > 1)
        warmups = args[1].to!size_t;

    if (args.length > 2)
        samples = args[2].to!size_t;

    assert(samples >= 5);

    auto signedQueue =
        new SignedQueue;

    auto modularQueue =
        new ModularQueue;

    ulong checksum;

    writeln(
        "R0.1 P06 single-thread hot-path benchmark");

    writefln(
        "capacity=%s warmups=%s samples=%s",
        SignedQueue.capacity,
        warmups,
        samples);

    benchmarkWorkload!(Workload.pushOnly)(
        *signedQueue,
        *modularQueue,
        warmups,
        samples,
        checksum);

    benchmarkWorkload!(Workload.popMany)(
        *signedQueue,
        *modularQueue,
        warmups,
        samples,
        checksum);

    benchmarkWorkload!(Workload.pushPopPair)(
        *signedQueue,
        *modularQueue,
        warmups,
        samples,
        checksum);

    benchmarkWorkload!(Workload.emptySteal)(
        *signedQueue,
        *modularQueue,
        warmups,
        samples,
        checksum);

    benchmarkWorkload!(Workload.successfulSteal)(
        *signedQueue,
        *modularQueue,
        warmups,
        samples,
        checksum);

    /*
     * Observable sink so result values remain part of the benchmark program.
     */
    writefln(
        "checksum=%s",
        checksum);

    writeln(
        "R0.1 P06 PASS");
}
