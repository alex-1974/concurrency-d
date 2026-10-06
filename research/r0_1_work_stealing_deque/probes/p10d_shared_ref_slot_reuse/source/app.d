module app;

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

import std.stdio :
    writefln,
    writeln;

enum size_t LogSize = 12;
enum size_t Capacity = size_t(1) << LogSize;
enum size_t BatchSize = 8;

enum size_t Transfers = 250_000;

enum size_t OwnerCpu = 2;
enum size_t ThiefCpu = 3;

struct TaskRef
{
    shared(ulong)* ptr;
}

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        TaskRef,
        LogSize);

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

private ulong valueOf(
    const TaskRef refValue)
{
    if (refValue.ptr is null)
        throw new Exception(
            "null task reference observed");

    return atomicLoad!(
        MemoryOrder.acq)(
            *refValue.ptr);
}

void main()
{
    writeln(
        "R0.1 P10d shared TaskRef slot reuse");

    const totalValues =
        Capacity +
        Transfers;

    auto records =
        new shared(ulong)[
            totalValues];

    foreach (i; 0 .. totalValues)
    {
        atomicStore!(
            MemoryOrder.raw)(
                records[i],
                cast(ulong) i + 1);
    }

    auto queue =
        new Queue;

    foreach (i; 0 .. Capacity)
    {
        if (!queue.tryPush(
                TaskRef(
                    &records[i])))
        {
            throw new Exception(
                "initial fill failed");
        }
    }

    if (
        queue.sizeSnapshot() !=
        Capacity)
    {
        throw new Exception(
            "initial capacity mismatch");
    }

    shared bool start;

    shared size_t stolenCount;
    shared size_t claimCount;

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

            TaskRef[BatchSize] buffer;

            size_t localCount;
            size_t localClaims;

            ulong localSum;
            ulong localXor;

            while (
                localCount <
                Transfers)
            {
                const remaining =
                    Transfers -
                    localCount;

                const request =
                    remaining < BatchSize
                        ? remaining
                        : BatchSize;

                const taken =
                    queue.stealBatch(
                        buffer[
                            0 ..
                            request]);

                if (taken == 0)
                {
                    Thread.yield();
                    continue;
                }

                ++localClaims;

                foreach (
                    refValue;
                    buffer[0 .. taken])
                {
                    const value =
                        valueOf(
                            refValue);

                    localSum += value;
                    localXor ^= value;

                    ++localCount;
                }
            }

            atomicStore!(
                MemoryOrder.rel)(
                    stolenCount,
                    localCount);

            atomicStore!(
                MemoryOrder.rel)(
                    claimCount,
                    localClaims);

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

    atomicStore!(
        MemoryOrder.rel)(
            start,
            true);

    size_t pushed;

    while (
        pushed <
        Transfers)
    {
        const index =
            Capacity +
            pushed;

        if (queue.tryPush(
                TaskRef(
                    &records[index])))
        {
            ++pushed;
        }
        else
        {
            Thread.yield();
        }
    }

    thief.join();

    if (
        atomicLoad!(
            MemoryOrder.acq)(
                stolenCount) !=
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
            "final capacity mismatch");
    }

    ulong remainingSum;
    ulong remainingXor;

    size_t remainingCount;

    while (true)
    {
        const result =
            queue.pop();

        if (!result.found)
            break;

        const value =
            valueOf(
                result.value);

        remainingSum += value;
        remainingXor ^= value;

        ++remainingCount;
    }

    if (
        remainingCount !=
        Capacity)
    {
        throw new Exception(
            "remaining count mismatch");
    }

    const n =
        cast(ulong)
            totalValues;

    const expectedSum =
        n * (n + 1) / 2;

    ulong expectedXor;

    final switch (n & 3)
    {
        case 0:
            expectedXor = n;
            break;

        case 1:
            expectedXor = 1;
            break;

        case 2:
            expectedXor = n + 1;
            break;

        case 3:
            expectedXor = 0;
            break;
    }

    const actualSum =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenSum) +
        remainingSum;

    const actualXor =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenXor) ^
        remainingXor;

    if (
        actualSum !=
        expectedSum)
    {
        throw new Exception(
            "global sum mismatch");
    }

    if (
        actualXor !=
        expectedXor)
    {
        throw new Exception(
            "global xor mismatch");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "queue not empty after verification");

    const claims =
        atomicLoad!(
            MemoryOrder.acq)(
                claimCount);

    writefln(
        "capacity=%s transfers=%s records=%s",
        Capacity,
        Transfers,
        totalValues);

    writefln(
        "stolen=%s claims=%s stolen/claim=%.3f",
        Transfers,
        claims,
        cast(double)
            Transfers /
            claims);

    writefln(
        "sum=%s xor=%s",
        actualSum,
        actualXor);

    writeln(
        "shared TaskRef lifetime/identity PASS");

    writeln(
        "R0.1 P10d PASS");
}
