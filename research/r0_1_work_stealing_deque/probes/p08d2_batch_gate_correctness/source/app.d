module app;

import concurrency.research.modular_bounded_wsq_batch_gate :
    GatedBatchBoundedWorkStealingDeque;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.conv : to;
import std.stdio : writefln, writeln;

alias Queue =
    GatedBatchBoundedWorkStealingDeque!(
        size_t,
        8);

enum size_t BatchSize = 8;
enum size_t defaultRounds = 500;
enum size_t defaultThieves = 4;

final class ThiefState
{
    size_t[] values;
    size_t successfulBatches;
    size_t partialBatches;
    size_t emptyBatches;

    void record(
        scope const(size_t)[] batch,
        size_t count)
    {
        if (count == 0)
        {
            ++emptyBatches;
            return;
        }

        ++successfulBatches;

        if (count != batch.length)
            ++partialBatches;

        values ~= batch[0 .. count];
    }
}

private void sequentialGate()
{
    Queue queue;

    foreach (value; 1 .. 18)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "sequential fill failed");
    }

    size_t[8] a;
    size_t[8] b;
    size_t[8] c;
    size_t[8] d;

    const na = queue.stealBatch(a[]);
    const nb = queue.stealBatch(b[]);
    const nc = queue.stealBatch(c[]);
    const nd = queue.stealBatch(d[]);

    if (
        na != 8 ||
        nb != 8 ||
        nc != 1 ||
        nd != 0)
    {
        throw new Exception(
            "sequential counts incorrect");
    }

    foreach (i; 0 .. 8)
    {
        if (a[i] != i + 1)
            throw new Exception(
                "batch A ordering failure");

        if (b[i] != i + 9)
            throw new Exception(
                "batch B ordering failure");
    }

    if (c[0] != 17)
        throw new Exception(
            "partial batch ordering failure");

    if (!queue.emptySnapshot())
        throw new Exception(
            "sequential queue not empty");
}

private Thread makeThief(
    size_t id,
    ThiefState state,
    Queue* queue,
    Barrier startBarrier,
    Barrier finishBarrier,
    size_t rounds)
{
    return new Thread({
        size_t[BatchSize] buffer;

        foreach (round; 0 .. rounds)
        {
            startBarrier.wait();

            foreach (
                attempt;
                0 .. Queue.capacity)
            {
                if (
                    ((attempt + id + round) & 31) == 0)
                {
                    Thread.yield();
                }

                const count =
                    queue.stealBatch(
                        buffer[]);

                state.record(
                    buffer[],
                    count);
            }

            finishBarrier.wait();
        }
    });
}

void main(string[] args)
{
    sequentialGate();

    size_t rounds =
        defaultRounds;

    size_t thiefCount =
        defaultThieves;

    if (args.length > 1)
        rounds = args[1].to!size_t;

    if (args.length > 2)
        thiefCount = args[2].to!size_t;

    if (
        rounds == 0 ||
        thiefCount == 0)
    {
        throw new Exception(
            "invalid arguments");
    }

    const participants =
        cast(uint)(
            thiefCount + 1);

    const totalSubmitted =
        rounds *
        Queue.capacity;

    enum ulong startIndex =
        ulong.max -
        (Queue.capacity / 2 - 1);

    enum ulong expectedFilledBottom =
        startIndex +
        cast(ulong) Queue.capacity;

    Queue queue;

    auto startBarrier =
        new Barrier(participants);

    auto finishBarrier =
        new Barrier(participants);

    auto states =
        new ThiefState[thiefCount];

    auto threads =
        new Thread[thiefCount];

    foreach (id; 0 .. thiefCount)
    {
        auto state =
            new ThiefState;

        state.values.reserve(
            totalSubmitted /
                thiefCount +
            Queue.capacity);

        states[id] =
            state;

        threads[id] =
            makeThief(
                id,
                state,
                &queue,
                startBarrier,
                finishBarrier,
                rounds);
    }

    foreach (thread; threads)
        thread.start();

    size_t[] ownerValues;
    ownerValues.reserve(
        totalSubmitted);

    size_t pushFailures;
    size_t nonEmptyAfterDrain;
    size_t invalidEmptyState;

    foreach (round; 0 .. rounds)
    {
        queue.researchSetEmptyIndex(
            startIndex);

        const base =
            round *
            Queue.capacity;

        foreach (i; 0 .. Queue.capacity)
        {
            const value =
                base + i + 1;

            if (!queue.tryPush(value))
                ++pushFailures;
        }

        if (
            queue.researchTopSnapshot() !=
                startIndex ||
            queue.researchBottomSnapshot() !=
                expectedFilledBottom)
        {
            throw new Exception(
                "wrap fill state mismatch");
        }

        startBarrier.wait();

        /*
         * Sole owner races from bottom while thieves reserve from top.
         */
        foreach (
            attempt;
            0 .. Queue.capacity * 2)
        {
            if (
                ((attempt + round) & 31) == 0)
            {
                Thread.yield();
            }

            const result =
                queue.pop();

            if (result.found)
                ownerValues ~=
                    result.value;
        }

        finishBarrier.wait();

        /*
         * Quiescent cleanup.
         */
        foreach (_; 0 .. Queue.capacity + 1)
        {
            const result =
                queue.pop();

            if (!result.found)
                break;

            ownerValues ~=
                result.value;
        }

        if (!queue.emptySnapshot())
            ++nonEmptyAfterDrain;

        const top =
            queue.researchTopSnapshot();

        const bottom =
            queue.researchBottomSnapshot();

        const meetingOffset =
            top - startIndex;

        if (
            top != bottom ||
            meetingOffset >
                cast(ulong)
                    Queue.capacity)
        {
            ++invalidEmptyState;
        }
    }

    foreach (thread; threads)
        thread.join();

    auto seen =
        new uint[
            totalSubmitted + 1];

    size_t ownerPopped;
    size_t stolen;
    size_t outOfRange;
    size_t duplicateRecords;
    size_t activeThieves;

    size_t successfulBatches;
    size_t partialBatches;
    size_t emptyBatches;

    foreach (value; ownerValues)
    {
        ++ownerPopped;

        if (
            value == 0 ||
            value > totalSubmitted)
        {
            ++outOfRange;
            continue;
        }

        ++seen[value];

        if (seen[value] > 1)
            ++duplicateRecords;
    }

    foreach (state; states)
    {
        if (state.values.length != 0)
            ++activeThieves;

        successfulBatches +=
            state.successfulBatches;

        partialBatches +=
            state.partialBatches;

        emptyBatches +=
            state.emptyBatches;

        foreach (value; state.values)
        {
            ++stolen;

            if (
                value == 0 ||
                value > totalSubmitted)
            {
                ++outOfRange;
                continue;
            }

            ++seen[value];

            if (seen[value] > 1)
                ++duplicateRecords;
        }
    }

    size_t missing;
    size_t duplicateValues;

    foreach (
        value;
        1 .. totalSubmitted + 1)
    {
        if (seen[value] == 0)
            ++missing;
        else if (seen[value] > 1)
            ++duplicateValues;
    }

    const returned =
        ownerPopped + stolen;

    writefln(
        "rounds=%s capacity=%s thieves=%s batchSize=%s submitted=%s",
        rounds,
        Queue.capacity,
        thiefCount,
        BatchSize,
        totalSubmitted);

    writefln(
        "ownerPopped=%s stolen=%s returned=%s activeThieves=%s",
        ownerPopped,
        stolen,
        returned,
        activeThieves);

    writefln(
        "successfulBatches=%s partialBatches=%s emptyBatches=%s",
        successfulBatches,
        partialBatches,
        emptyBatches);

    writefln(
        "missing=%s duplicateValues=%s duplicateRecords=%s outOfRange=%s",
        missing,
        duplicateValues,
        duplicateRecords,
        outOfRange);

    writefln(
        "pushFailures=%s nonEmptyAfterDrain=%s invalidEmptyState=%s",
        pushFailures,
        nonEmptyAfterDrain,
        invalidEmptyState);

    if (
        pushFailures != 0 ||
        nonEmptyAfterDrain != 0 ||
        invalidEmptyState != 0)
    {
        throw new Exception(
            "queue state failure");
    }

    if (
        missing != 0 ||
        duplicateValues != 0 ||
        duplicateRecords != 0 ||
        outOfRange != 0)
    {
        throw new Exception(
            "accounting failure");
    }

    if (returned != totalSubmitted)
        throw new Exception(
            "returned count mismatch");

    if (stolen == 0)
        throw new Exception(
            "no batch progress");

    if (
        thiefCount >= 2 &&
        activeThieves < 2)
    {
        throw new Exception(
            "insufficient thief coverage");
    }

    if (successfulBatches == 0)
        throw new Exception(
            "no successful batches");
    
    if (partialBatches == 0)
        throw new Exception(
            "partial-batch path not covered");

    if (!queue.emptySnapshot())
        throw new Exception(
            "final queue not empty");

    writeln(
        "R0.1 P08d2 PASS: gated single-CAS batches preserve accounting");
}
