module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicLoad,
    atomicStore;

import core.thread :
    Thread;

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

final class ThiefState
{
    size_t[] values;

    void record(
        size_t value)
    {
        values ~= value;
    }
}

private Thread makeThief(
    size_t id,
    ThiefState state,
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
                state.record(
                    result.value);

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
    ulong totalOwner;
    ulong totalStolen;

    foreach (round; 0 .. Rounds)
    {
        Queue queue;

        const first =
            round * Capacity +
            1;

        const last =
            (round + 1) *
            Capacity;

        foreach (value; first .. last + 1)
        {
            if (
                !queue.tryPush(
                    value))
            {
                throw new Exception(
                    "fill failed");
            }
        }

        shared bool start;
        shared bool done;

        ThiefState[Thieves] states;
        Thread[Thieves] threads;

        foreach (id; 0 .. Thieves)
        {
            states[id] =
                new ThiefState;

            states[id].values.reserve(
                Capacity / Thieves +
                64);

            threads[id] =
                makeThief(
                    id,
                    states[id],
                    &queue,
                    &start,
                    &done);

            threads[id].start();
        }

        atomicStore!(
            MemoryOrder.rel)(
                start,
                true);

        size_t[] ownerValues;
        ownerValues.reserve(
            Capacity);

        for (;;)
        {
            const result =
                queue.pop();

            if (!result.found)
                break;

            ownerValues ~=
                result.value;
        }

        atomicStore!(
            MemoryOrder.rel)(
                done,
                true);

        foreach (thread; threads)
            thread.join();

        bool[Capacity] seen;
        size_t roundOwner;
        size_t roundStolen;

        foreach (value; ownerValues)
        {
            if (
                value < first ||
                value > last)
            {
                throw new Exception(
                    "owner value out of range");
            }

            const index =
                value - first;

            if (seen[index])
            {
                throw new Exception(
                    "duplicate owner value");
            }

            seen[index] = true;
            ++roundOwner;
        }

        foreach (state; states)
        {
            foreach (value; state.values)
            {
                if (
                    value < first ||
                    value > last)
                {
                    throw new Exception(
                        "stolen value out of range");
                }

                const index =
                    value - first;

                if (seen[index])
                {
                    throw new Exception(
                        "duplicate stolen value");
                }

                seen[index] = true;
                ++roundStolen;
            }
        }

        if (
            roundOwner +
            roundStolen !=
            Capacity)
        {
            throw new Exception(
                "round count mismatch");
        }

        foreach (present; seen)
        {
            if (!present)
            {
                throw new Exception(
                    "missing value");
            }
        }

        if (
            !queue.emptySnapshot())
        {
            throw new Exception(
                "queue not empty");
        }

        totalOwner +=
            roundOwner;

        totalStolen +=
            roundStolen;
    }

    if (totalStolen == 0)
    {
        throw new Exception(
            "no thief progress");
    }

    writefln(
        "rounds=%s capacity=%s thieves=%s owner=%s stolen=%s",
        Rounds,
        Capacity,
        Thieves,
        totalOwner,
        totalStolen);

    writeln(
        "R0.1 P15b PASS: selected P08e multi-thief exact accounting");
}
