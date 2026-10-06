module app;

import concurrency.research.modular_bounded_wsq_batch_safe_ref :
    SafeReferenceBatchBoundedWorkStealingDeque;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.stdio : writefln, writeln;

alias Queue =
    SafeReferenceBatchBoundedWorkStealingDeque!(
        size_t,
        8);

enum size_t defaultRounds = 500;
enum size_t defaultThieves = 4;
enum size_t BatchSize = 8;

final class ThiefState
{
    size_t[] values;

    void recordBatch(
        scope const(size_t)[] batch)
    {
        values ~= batch;
    }
}

private void sequentialGate()
{
    Queue queue;

    foreach (value; 1 .. 17)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "sequential fill failed");
    }

    size_t[8] first;
    size_t[8] second;
    size_t[8] third;

    const n1 =
        queue.stealBatch(first[]);

    const n2 =
        queue.stealBatch(second[]);

    const n3 =
        queue.stealBatch(third[]);

    if (n1 != 8 || n2 != 8 || n3 != 0)
        throw new Exception(
            "sequential batch count failure");

    foreach (i; 0 .. 8)
    {
        if (first[i] != i + 1)
            throw new Exception(
                "first batch ordering failure");

        if (second[i] != i + 9)
            throw new Exception(
                "second batch ordering failure");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "sequential queue not empty");
}

private Thread makeThiefThread(
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
                0 .. Queue.capacity / BatchSize * 4)
            {
                if (
                    ((attempt + id + round) & 31) == 0)
                {
                    Thread.yield();
                }

                const count =
                    queue.stealBatch(
                        buffer[]);

                if (count != 0)
                {
                    state.recordBatch(
                        buffer[0 .. count]);
                }
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

    if (rounds == 0 || thiefCount == 0)
        throw new Exception(
            "invalid arguments");

    const participants =
        cast(uint)(thiefCount + 1);

    const totalSubmitted =
        rounds * Queue.capacity;

    /*
     * Cross ulong.max on every round.
     */
    enum ulong startIndex =
        ulong.max -
        (Queue.capacity / 2 - 1);

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
            makeThiefThread(
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
            round * Queue.capacity;

        foreach (i; 0 .. Queue.capacity)
        {
            const value =
                base + i + 1;

            if (!queue.tryPush(value))
                ++pushFailures;
        }

        startBarrier.wait();

        /*
         * Owner races from bottom while thieves steal oldest-first
         * in batches implemented as repeated qualified single steals.
         */
        foreach (
            attempt;
            0 .. Queue.capacity * 2)
        {
            if (((attempt + round) & 31) == 0)
                Thread.yield();

            const result =
                queue.pop();

            if (result.found)
                ownerValues ~= result.value;
        }

        finishBarrier.wait();

        /*
         * Thieves are quiescent now.
         * Drain any remainder from owner side.
         */
        foreach (_; 0 .. Queue.capacity + 1)
        {
            const result =
                queue.pop();

            if (!result.found)
                break;

            ownerValues ~= result.value;
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
                cast(ulong) Queue.capacity)
        {
            ++invalidEmptyState;
        }
    }

    foreach (thread; threads)
        thread.join();

    auto seen =
        new uint[totalSubmitted + 1];

    size_t ownerPopped;
    size_t stolen;
    size_t outOfRange;
    size_t duplicateRecords;
    size_t activeThieves;

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

    if (pushFailures != 0)
        throw new Exception(
            "push failure");

    if (nonEmptyAfterDrain != 0)
        throw new Exception(
            "non-empty after drain");

    if (invalidEmptyState != 0)
        throw new Exception(
            "invalid empty state");

    if (
        outOfRange != 0 ||
        missing != 0 ||
        duplicateValues != 0 ||
        duplicateRecords != 0)
    {
        throw new Exception(
            "accounting failure");
    }

    if (returned != totalSubmitted)
        throw new Exception(
            "returned count mismatch");

    if (
        thiefCount >= 2 &&
        activeThieves < 2)
    {
        throw new Exception(
            "insufficient thief coverage");
    }

    if (stolen == 0)
        throw new Exception(
            "no thief progress");

    if (!queue.emptySnapshot())
        throw new Exception(
            "final queue not empty");

    writeln(
        "R0.1 P08d1 PASS: safe batch reference preserves accounting");
}
