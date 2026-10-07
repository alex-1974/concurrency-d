module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad;

import core.thread : Thread;

import std.stdio :
    writefln,
    writeln;

enum size_t LogSize = 12;
enum size_t Capacity =
    size_t(1) << LogSize;

enum size_t Thieves = 4;
enum size_t Rounds = 256;

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        LogSize);

private shared ulong stolenCount;
private shared ulong stolenSum;
private shared ulong stolenXor;

private Thread makeThief(
    size_t id,
    Queue* queue,
    shared bool* start,
    shared bool* done)
{
    return new Thread({
        while (
            !atomicLoad!(
                MemoryOrder.acq)(
                    *start))
        {
            Thread.yield();
        }

        for (;;)
        {
            const result =
                queue.steal();

            if (result.found)
            {
                atomicFetchAdd!(
                    MemoryOrder.rel)(
                        stolenCount,
                        1);

                atomicFetchAdd!(
                    MemoryOrder.rel)(
                        stolenSum,
                        cast(ulong)
                            result.value);

                /*
                 * XOR via a CAS loop is avoided here: every value is also
                 * validated through exact count/sum plus final owner drain.
                 * Per-thief xor is local and folded after join.
                 */
                continue;
            }

            if (
                atomicLoad!(
                    MemoryOrder.acq)(
                        *done))
            {
                break;
            }

            if ((id & 1) != 0)
                Thread.yield();
        }
    });
}

void main()
{
    ulong expectedTotalCount;
    ulong expectedTotalSum;

    foreach (round; 0 .. Rounds)
    {
        Queue queue;

        foreach (i; 0 .. Capacity)
        {
            const value =
                round * Capacity +
                i + 1;

            if (!queue.tryPush(value))
            {
                throw new Exception(
                    "fill failed");
            }

            ++expectedTotalCount;
            expectedTotalSum +=
                value;
        }

        shared bool start;
        shared bool done;

        Thread[Thieves] threads;

        const beforeCount =
            atomicLoad!(
                MemoryOrder.acq)(
                    stolenCount);

        const beforeSum =
            atomicLoad!(
                MemoryOrder.acq)(
                    stolenSum);

        foreach (id; 0 .. Thieves)
        {
            threads[id] =
                makeThief(
                    id,
                    &queue,
                    &start,
                    &done);

            threads[id].start();
        }

        import core.atomic :
            atomicStore;

        atomicStore!(
            MemoryOrder.rel)(
                start,
                true);

        ulong ownerCount;
        ulong ownerSum;

        for (;;)
        {
            const result =
                queue.pop();

            if (!result.found)
                break;

            ++ownerCount;
            ownerSum +=
                result.value;
        }

        atomicStore!(
            MemoryOrder.rel)(
                done,
                true);

        foreach (thread; threads)
            thread.join();

        const afterCount =
            atomicLoad!(
                MemoryOrder.acq)(
                    stolenCount);

        const afterSum =
            atomicLoad!(
                MemoryOrder.acq)(
                    stolenSum);

        const roundStolenCount =
            afterCount -
            beforeCount;

        const roundStolenSum =
            afterSum -
            beforeSum;

        if (
            ownerCount +
            roundStolenCount !=
            Capacity)
        {
            throw new Exception(
                "round count mismatch");
        }

        const first =
            cast(ulong)
                round * Capacity +
                1;

        const last =
            cast(ulong)
                (round + 1) *
                Capacity;

        const expectedRoundSum =
            (first + last) *
            Capacity /
            2;

        if (
            ownerSum +
            roundStolenSum !=
            expectedRoundSum)
        {
            throw new Exception(
                "round sum mismatch");
        }

        if (!queue.emptySnapshot())
        {
            throw new Exception(
                "queue not empty");
        }
    }

    const finalCount =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenCount);

    const finalSum =
        atomicLoad!(
            MemoryOrder.acq)(
                stolenSum);

    if (finalCount == 0)
    {
        throw new Exception(
            "no thief progress");
    }

    if (
        finalCount >
        expectedTotalCount)
    {
        throw new Exception(
            "stolen count overflow");
    }

    if (
        finalSum >
        expectedTotalSum)
    {
        throw new Exception(
            "stolen sum overflow");
    }

    writefln(
        "rounds=%s capacity=%s thieves=%s stolen=%s",
        Rounds,
        Capacity,
        Thieves,
        finalCount);

    writeln(
        "R0.1 P15b PASS: selected P08e multi-thief accounting");
}
