module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import std.algorithm.sorting :
    sort;

import std.datetime.stopwatch :
    AutoStart,
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t LogSize = 16;
enum size_t Operations = 8_000_000;
enum size_t Warmups = 5;
enum size_t Samples = 21;

alias SingleQueue =
    ModularRmwPaddedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias BatchQueue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

static assert(
    SingleQueue.capacity ==
    BatchQueue.capacity);

enum size_t Capacity =
    BatchQueue.capacity;

struct Stats
{
    double medianNs;
    double p10Ns;
    double p90Ns;
}

private Stats calculateStats(
    ulong[] times)
{
    times.sort();

    const n =
        times.length;

    const double median =
        (n & 1)
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
        median / Operations,
        cast(double)
            times[p10] / Operations,
        cast(double)
            times[p90] / Operations);
}

private void fillTo(Q)(
    ref Q queue,
    size_t occupancy)
{
    foreach (i; 0 .. occupancy)
    {
        if (!queue.tryPush(i + 1))
            throw new Exception(
                "fill failed");
    }

    if (
        queue.sizeSnapshot() !=
        occupancy)
    {
        throw new Exception(
            "fill size mismatch");
    }
}

private void qualifyCapacity(Q)(
    string name)
{
    auto queue =
        new Q;

    fillTo(
        *queue,
        Capacity);

    if (
        queue.sizeSnapshot() !=
        Capacity)
    {
        throw new Exception(
            "full size mismatch");
    }

    if (queue.tryPush(
            Capacity + 1))
    {
        throw new Exception(
            "push beyond capacity succeeded");
    }

    const popped =
        queue.pop();

    if (!popped.found)
        throw new Exception(
            "full recovery pop failed");

    if (
        queue.sizeSnapshot() !=
        Capacity - 1)
    {
        throw new Exception(
            "post-pop size mismatch");
    }

    if (!queue.tryPush(
            Capacity + 1))
    {
        throw new Exception(
            "recovery push failed");
    }

    if (
        queue.sizeSnapshot() !=
        Capacity)
    {
        throw new Exception(
            "recovery full size mismatch");
    }

    if (queue.tryPush(
            Capacity + 2))
    {
        throw new Exception(
            "second push beyond capacity succeeded");
    }

    writefln(
        "%-10s capacity-transition PASS",
        name);
}

private ulong runStable(Q)(
    size_t occupancy,
    ref ulong checksum)
{
    auto queue =
        new Q;

    fillTo(
        *queue,
        occupancy);

    size_t nextValue =
        occupancy + 1;

    auto sw =
        StopWatch(
            AutoStart.yes);

    ulong localChecksum;

    foreach (_; 0 .. Operations)
    {
        const popped =
            queue.pop();

        if (!popped.found)
            throw new Exception(
                "stable pop failed");

        localChecksum +=
            cast(ulong)
                popped.value;

        if (!queue.tryPush(
                nextValue))
        {
            throw new Exception(
                "stable recovery push failed");
        }

        ++nextValue;
    }

    sw.stop();

    if (
        queue.sizeSnapshot() !=
        occupancy)
    {
        throw new Exception(
            "stable occupancy changed");
    }

    checksum +=
        localChecksum;

    return cast(ulong)
        sw.peek.total!"nsecs";
}

private void benchmarkOccupancy(Q)(
    string name,
    size_t occupancy)
{
    ulong checksum;

    foreach (_; 0 .. Warmups)
    {
        runStable!Q(
            occupancy,
            checksum);
    }

    ulong[Samples] times;

    foreach (i; 0 .. Samples)
    {
        times[i] =
            runStable!Q(
                occupancy,
                checksum);
    }

    const stats =
        calculateStats(
            times[]);

    writefln(
        "%-10s occupancy=%6s/%6s (%6.2f%%) "
        ~ "median=%8.3f ns/pair p10/p90=%8.3f/%8.3f "
        ~ "checksum=%s",
        name,
        occupancy,
        Capacity,
        100.0 *
            cast(double) occupancy /
            cast(double) Capacity,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns,
        checksum);
}

private void runQueue(Q)(
    string name)
{
    qualifyCapacity!Q(
        name);

    immutable size_t[] occupancies =
    [
        Capacity / 8,
        Capacity / 4,
        Capacity / 2,
        Capacity * 3 / 4,
        Capacity - 1,
        Capacity
    ];

    foreach (occupancy; occupancies)
    {
        benchmarkOccupancy!Q(
            name,
            occupancy);
    }
}

void main()
{
    writeln(
        "R0.1 P09a bounded occupancy / near-capacity");

    writefln(
        "capacity=%s operations=%s warmups=%s samples=%s",
        Capacity,
        Operations,
        Warmups,
        Samples);

    runQueue!SingleQueue(
        "single");

    runQueue!BatchQueue(
        "p08e");

    writeln(
        "R0.1 P09a PASS");
}
