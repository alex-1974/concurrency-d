module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicStore;

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
    StopWatch;

import std.stdio :
    writefln,
    writeln;

enum size_t LogSize = 16;
enum size_t Capacity = size_t(1) << LogSize;
enum size_t BatchSize = 8;

enum size_t Items = Capacity;
enum size_t Warmups = 4;
enum size_t Samples = 15;

enum size_t OwnerCpu = 2;
enum size_t ThiefCpu = 3;

struct Handle64
{
    ulong id;
}

struct Pair128
{
    ulong id;
    ulong guard;
}

private ulong guardFor(
    ulong id)
    @nogc nothrow
{
    return
        (id ^
            0x9e3779b97f4a7c15UL) *
        0xbf58476d1ce4e5b9UL;
}

private Handle64 makeValue(T : Handle64)(
    ulong id)
{
    return Handle64(id);
}

private Pair128 makeValue(T : Pair128)(
    ulong id)
{
    return Pair128(
        id,
        guardFor(id));
}

private ulong idOf(T)(
    T value)
{
    return value.id;
}

private bool validValue(T : Handle64)(
    T value)
{
    return value.id != 0;
}

private bool validValue(T : Pair128)(
    T value)
{
    return
        value.id != 0 &&
        value.guard ==
            guardFor(value.id);
}

private void pinCurrentThread(
    size_t cpu)
{
    version (linux)
    {
        cpu_set_t mask;

        CPU_SET(
            cpu,
            &mask);

        if (
            sched_setaffinity(
                0,
                cpu_set_t.sizeof,
                &mask) != 0)
        {
            throw new Exception(
                "sched_setaffinity failed");
        }

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

struct RunResult
{
    ulong elapsedNs;

    size_t ownerCount;
    size_t stolenCount;
    size_t claims;

    ulong idSum;

    size_t invalidValues;
}

struct Stats
{
    double median;
    double p10;
    double p90;
}

private RunResult runDrain(T)()
{
    alias Q =
        MarkedTopBatchBoundedWorkStealingDeque!(
            T,
            LogSize);

    auto queue =
        new Q;

    foreach (i; 0 .. Items)
    {
        const id =
            cast(ulong) i + 1;

        if (!queue.tryPush(
                makeValue!T(id)))
        {
            throw new Exception(
                "prefill failed");
        }
    }

    shared bool start;
    shared bool ready;

    shared size_t thiefCount;
    shared size_t thiefClaims;
    shared size_t thiefInvalid;
    shared ulong thiefSum;

    auto thief =
        new Thread({
            pinCurrentThread(
                ThiefCpu);

            atomicStore!(
                MemoryOrder.rel)(
                    ready,
                    true);

            while (
                !atomicLoad!(
                    MemoryOrder.acq)(
                        start))
            {
                Thread.yield();
            }

            T[BatchSize] buffer;

            size_t localCount;
            size_t localClaims;
            size_t localInvalid;

            ulong localSum;

            for (;;)
            {
                const taken =
                    queue.stealBatch(
                        buffer[]);

                if (taken != 0)
                {
                    ++localClaims;

                    foreach (
                        value;
                        buffer[0 .. taken])
                    {
                        if (!validValue(value))
                            ++localInvalid;

                        localSum +=
                            idOf(value);

                        ++localCount;
                    }

                    continue;
                }

                if (queue.emptySnapshot())
                    break;
            }

            atomicStore!(
                MemoryOrder.rel)(
                    thiefCount,
                    localCount);

            atomicStore!(
                MemoryOrder.rel)(
                    thiefClaims,
                    localClaims);

            atomicStore!(
                MemoryOrder.rel)(
                    thiefInvalid,
                    localInvalid);

            atomicStore!(
                MemoryOrder.rel)(
                    thiefSum,
                    localSum);
        });

    thief.start();

    pinCurrentThread(
        OwnerCpu);

    while (
        !atomicLoad!(
            MemoryOrder.acq)(
                ready))
    {
        Thread.yield();
    }

    size_t ownerCount;
    size_t ownerInvalid;

    ulong ownerSum;

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
            if (!validValue(
                    result.value))
            {
                ++ownerInvalid;
            }

            ownerSum +=
                idOf(result.value);

            ++ownerCount;
            continue;
        }

        if (queue.emptySnapshot())
            break;
    }

    thief.join();

    sw.stop();

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.ownerCount =
        ownerCount;

    result.stolenCount =
        atomicLoad!(
            MemoryOrder.acq)(
                thiefCount);

    result.claims =
        atomicLoad!(
            MemoryOrder.acq)(
                thiefClaims);

    result.invalidValues =
        ownerInvalid +
        atomicLoad!(
            MemoryOrder.acq)(
                thiefInvalid);

    result.idSum =
        ownerSum +
        atomicLoad!(
            MemoryOrder.acq)(
                thiefSum);

    const expectedCount =
        Items;

    const expectedSum =
        cast(ulong) Items *
        cast(ulong)(Items + 1) /
        2;

    if (
        result.ownerCount +
        result.stolenCount !=
        expectedCount)
    {
        throw new Exception(
            "count mismatch");
    }

    if (
        result.idSum !=
        expectedSum)
    {
        throw new Exception(
            "sum mismatch");
    }

    if (
        result.invalidValues != 0)
    {
        throw new Exception(
            "invalid/torn element observed");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "queue not empty");
    
    if (queue.researchBatchBusy())
        throw new Exception(
            "busy marker leaked");

    return result;
}

private Stats calculateStats(
    ulong[] times)
{
    times.sort();

    const n =
        times.length;

    return Stats(
        cast(double)
            times[n / 2] /
            Items,
        cast(double)
            times[(n - 1) * 10 / 100] /
            Items,
        cast(double)
            times[(n - 1) * 90 / 100] /
            Items);
}

private void benchmark(T)(
    string name)
{
    foreach (_; 0 .. Warmups)
        runDrain!T();

    ulong[Samples] times;

    size_t totalOwner;
    size_t totalStolen;
    size_t totalClaims;

    foreach (i; 0 .. Samples)
    {
        const result =
            runDrain!T();

        times[i] =
            result.elapsedNs;

        totalOwner +=
            result.ownerCount;

        totalStolen +=
            result.stolenCount;

        totalClaims +=
            result.claims;
    }

    const stats =
        calculateStats(
            times[]);

    const double perClaim =
        totalClaims != 0
            ? cast(double)
                totalStolen /
                totalClaims
            : 0.0;

    writefln(
        "%-10s size=%2s median=%8.3f ns/item "
        ~ "p10/p90=%8.3f/%8.3f",
        name,
        T.sizeof,
        stats.median,
        stats.p10,
        stats.p90);

    writefln(
        "           owner=%s stolen=%s "
        ~ "claims=%s stolen/claim=%.3f",
        totalOwner,
        totalStolen,
        totalClaims,
        perClaim);
}

void main()
{
    writeln(
        "R0.1 P10b trivial element transfer");

    writefln(
        "items=%s batch=%s warmups=%s samples=%s",
        Items,
        BatchSize,
        Warmups,
        Samples);

    benchmark!Handle64(
        "Handle64");

    benchmark!Pair128(
        "Pair128");

    writeln(
        "R0.1 P10b PASS");
}
