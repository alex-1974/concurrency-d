module app;

import concurrency.research.modular_bounded_wsq_rmw_padded :
    ModularRmwPaddedBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
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

enum size_t Transfers = 4_000_000;
enum size_t Warmups = 4;
enum size_t Samples = 15;

enum size_t OwnerCpu = 2;
enum size_t ThiefCpu = 3;

alias SingleQueue =
    ModularRmwPaddedBoundedWorkStealingDeque!(
        size_t,
        LogSize);

alias BatchQueue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

enum Variant
{
    single,
    batch
}

struct RunResult
{
    ulong elapsedNs;

    size_t stolen;
    size_t claims;

    size_t failedPushes;
    size_t thiefRetries;

    ulong stolenSum;
    ulong stolenXor;

    ulong remainingSum;
    ulong remainingXor;

    ulong ownerBusyRetries;
}

struct Stats
{
    double medianNs;
    double p10Ns;
    double p90Ns;
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

private ulong xorTo(
    ulong n)
    @nogc nothrow
{
    final switch (n & 3)
    {
        case 0:
            return n;

        case 1:
            return 1;

        case 2:
            return n + 1;

        case 3:
            return 0;
    }
}

private ulong expectedSum(
    ulong n)
    @nogc nothrow
{
    /*
     * Current probe values are small enough that this does not overflow.
     */
    return
        n * (n + 1) / 2;
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
        median / Transfers,
        cast(double)
            times[p10] / Transfers,
        cast(double)
            times[p90] / Transfers);
}

private RunResult runOnce(
    Queue,
    Variant variant)()
{
    auto queue =
        new Queue;

    static if (
        variant ==
        Variant.batch)
    {
        queue.researchResetOwnerBusyRetries();
    }

    foreach (i; 0 .. Capacity)
    {
        if (!queue.tryPush(i + 1))
            throw new Exception(
                "initial full fill failed");
    }

    if (
        queue.sizeSnapshot() !=
        Capacity)
    {
        throw new Exception(
            "initial capacity mismatch");
    }

    if (queue.tryPush(
            Capacity + 1))
    {
        throw new Exception(
            "initial over-capacity push succeeded");
    }

    shared bool start;

    shared size_t stolenCount;
    shared size_t claimCount;
    shared size_t retryCount;

    shared ulong stolenSum;
    shared ulong stolenXor;

    auto thief =
        new Thread({
            pinCurrentThread(
                ThiefCpu);

            while (
                !atomicLoad!(
                    MemoryOrder.acq)(
                        start))
            {
                Thread.yield();
            }

            size_t localStolen;
            size_t localClaims;
            size_t localRetries;

            ulong localSum;
            ulong localXor;

            size_t[BatchSize] buffer;

            while (
                localStolen <
                Transfers)
            {
                static if (
                    variant ==
                    Variant.single)
                {
                    const result =
                        queue.steal();

                    if (result.found)
                    {
                        const value =
                            result.value;

                        ++localStolen;
                        ++localClaims;

                        localSum +=
                            cast(ulong) value;

                        localXor ^=
                            cast(ulong) value;

                        continue;
                    }
                }
                else
                {
                    const remaining =
                        Transfers -
                        localStolen;

                    const request =
                        remaining < BatchSize
                            ? remaining
                            : BatchSize;

                    const taken =
                        queue.stealBatch(
                            buffer[
                                0 ..
                                request]);

                    if (taken != 0)
                    {
                        ++localClaims;

                        foreach (
                            value;
                            buffer[0 .. taken])
                        {
                            ++localStolen;

                            localSum +=
                                cast(ulong) value;

                            localXor ^=
                                cast(ulong) value;
                        }

                        continue;
                    }
                }

                ++localRetries;

                if (
                    (localRetries & 255) ==
                    0)
                {
                    Thread.yield();
                }
            }

            atomicStore!(
                MemoryOrder.rel)(
                    stolenCount,
                    localStolen);

            atomicStore!(
                MemoryOrder.rel)(
                    claimCount,
                    localClaims);

            atomicStore!(
                MemoryOrder.rel)(
                    retryCount,
                    localRetries);

            atomicStore!(
                MemoryOrder.rel)(
                    stolenSum,
                    localSum);

            atomicStore!(
                MemoryOrder.rel)(
                    stolenXor,
                    localXor);
        });

    thief.start();

    pinCurrentThread(
        OwnerCpu);

    size_t pushed;
    size_t failedPushes;

    StopWatch sw;
    sw.start();

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    size_t nextValue =
        Capacity + 1;

    while (
        pushed <
        Transfers)
    {
        if (queue.tryPush(
                nextValue))
        {
            ++pushed;
            ++nextValue;
            continue;
        }

        ++failedPushes;

        if (
            (failedPushes & 255) ==
            0)
        {
            Thread.yield();
        }
    }

    thief.join();

    sw.stop();

    RunResult result;

    result.elapsedNs =
        cast(ulong)
            sw.peek.total!"nsecs";

    result.stolen =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenCount);

    result.claims =
        atomicLoad!(
            MemoryOrder.acq)(
                claimCount);

    result.thiefRetries =
        atomicLoad!(
            MemoryOrder.acq)(
                retryCount);

    result.stolenSum =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenSum);

    result.stolenXor =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenXor);

    result.failedPushes =
        failedPushes;

    static if (
        variant ==
        Variant.batch)
    {
        result.ownerBusyRetries =
            queue.researchOwnerBusyRetriesSnapshot();

        if (queue.researchBatchBusy())
            throw new Exception(
                "busy marker leaked");
    }

    if (
        result.stolen !=
        Transfers)
    {
        throw new Exception(
            "stolen count mismatch");
    }

    if (
        queue.sizeSnapshot() !=
        Capacity)
    {
        throw new Exception(
            "queue did not return to full");
    }

    if (queue.tryPush(
            nextValue))
    {
        throw new Exception(
            "post-run over-capacity push succeeded");
    }

    size_t remainingCount;

    while (true)
    {
        const item =
            queue.pop();

        if (!item.found)
            break;

        ++remainingCount;

        result.remainingSum +=
            cast(ulong)
                item.value;

        result.remainingXor ^=
            cast(ulong)
                item.value;
    }

    if (
        remainingCount !=
        Capacity)
    {
        throw new Exception(
            "remaining count mismatch");
    }

    const submitted =
        cast(ulong)
            Capacity +
        cast(ulong)
            Transfers;

    const observedSum =
        result.stolenSum +
        result.remainingSum;

    const observedXor =
        result.stolenXor ^
        result.remainingXor;

    if (
        observedSum !=
        expectedSum(
            submitted))
    {
        throw new Exception(
            "global sum mismatch");
    }

    if (
        observedXor !=
        xorTo(
            submitted))
    {
        throw new Exception(
            "global xor mismatch");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "queue not empty after verification drain");

    return result;
}

private void benchmark(
    Queue,
    Variant variant)(
    string name)
{
    foreach (_; 0 .. Warmups)
    {
        runOnce!(
            Queue,
            variant)();
    }

    ulong[Samples] times;

    ulong aggregateStolen;
    ulong aggregateClaims;

    ulong aggregateFailedPushes;
    ulong aggregateThiefRetries;

    ulong aggregateBusyRetries;

    ulong aggregateStolenSum;
    ulong aggregateRemainingSum;

    foreach (i; 0 .. Samples)
    {
        const result =
            runOnce!(
                Queue,
                variant)();

        times[i] =
            result.elapsedNs;

        aggregateStolen +=
            result.stolen;

        aggregateClaims +=
            result.claims;

        aggregateFailedPushes +=
            result.failedPushes;

        aggregateThiefRetries +=
            result.thiefRetries;

        aggregateBusyRetries +=
            result.ownerBusyRetries;

        aggregateStolenSum +=
            result.stolenSum;

        aggregateRemainingSum +=
            result.remainingSum;
    }

    const stats =
        calculateStats(
            times[]);

    const double stolenPerClaim =
        aggregateClaims != 0
            ? cast(double)
                aggregateStolen /
                cast(double)
                    aggregateClaims
            : 0.0;

    writefln(
        "%-8s median=%8.3f ns/transfer "
        ~ "p10/p90=%8.3f/%8.3f",
        name,
        stats.medianNs,
        stats.p10Ns,
        stats.p90Ns);

    writefln(
        "         stolen=%s claims=%s stolen/claim=%.3f",
        aggregateStolen,
        aggregateClaims,
        stolenPerClaim);

    writefln(
        "         failedPushes=%s thiefRetries=%s ownerBusyRetries=%s",
        aggregateFailedPushes,
        aggregateThiefRetries,
        aggregateBusyRetries);

    writefln(
        "         stolenSum=%s remainingSum=%s",
        aggregateStolenSum,
        aggregateRemainingSum);
}

void main()
{
    writeln(
        "R0.1 P09b concurrent near-capacity refill");

    writefln(
        "capacity=%s transfers=%s batch=%s warmups=%s samples=%s",
        Capacity,
        Transfers,
        BatchSize,
        Warmups,
        Samples);

    benchmark!(
        SingleQueue,
        Variant.single)(
            "single");

    benchmark!(
        BatchQueue,
        Variant.batch)(
            "p08e");

    writeln(
        "R0.1 P09b PASS");
}
