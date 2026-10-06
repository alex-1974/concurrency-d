module app;

import concurrency.research.modular_bounded_wsq_batch_full64_marked_top :
    Full64DistanceMarkedBoundedWorkStealingDeque;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.conv : to;
import std.stdio : writefln, writeln;

alias SmallQueue =
    Full64DistanceMarkedBoundedWorkStealingDeque!(
        size_t,
        3);

alias Queue =
    Full64DistanceMarkedBoundedWorkStealingDeque!(
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

    void record(
        scope const(size_t)[] buffer,
        size_t count)
    {
        if (count == 0)
            return;

        ++successfulBatches;

        if (count != buffer.length)
            ++partialBatches;

        values ~= buffer[0 .. count];
    }
}

/*
 * Deterministically recreate the dangerous P08d0 shape:
 *
 * - thief has marked top busy but has not yet read bottom;
 * - owner attempts pop while the batch is in progress;
 * - owner must observe busy, restore its speculative bottom movement,
 *   and retry only after the batch publishes its new top.
 */
private void forcedOverlapGate()
{
    SmallQueue queue;

    foreach (value; 1 .. 9)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "forced-overlap fill failed");
    }

    queue.researchEnableBatchPause();

    size_t[4] batch;
    size_t batchCount;

    auto thief =
        new Thread({
            batchCount =
                queue.stealBatch(
                    batch[]);
        });

    thief.start();

    while (
        !queue.researchBatchMarkedSnapshot())
    {
        Thread.yield();
    }

    size_t ownerValue;
    bool ownerFound;

    auto owner =
        new Thread({
            const result =
                queue.pop();

            ownerFound =
                result.found;

            ownerValue =
                result.value;
        });

    owner.start();

    /*
     * Do not release the batch until the owner has definitely reached the
     * busy-state path at least once.
     */
    while (
        queue.researchOwnerBusyRetriesSnapshot() == 0)
    {
        Thread.yield();
    }

    const busyRetries =
        queue.researchOwnerBusyRetriesSnapshot();

    queue.researchReleaseBatchPause();

    thief.join();
    owner.join();

    writefln(
        "forced batch=%s,%s,%s,%s count=%s",
        batch[0],
        batch[1],
        batch[2],
        batch[3],
        batchCount);

    writefln(
        "forced ownerFound=%s ownerValue=%s busyRetries=%s",
        ownerFound,
        ownerValue,
        busyRetries);

    writefln(
        "forced finalTop=%s finalBottom=%s busy=%s",
        queue.researchTopSnapshot(),
        queue.researchBottomSnapshot(),
        queue.researchBatchBusy());

    if (batchCount != 4)
        throw new Exception(
            "forced batch count failure");

    foreach (i; 0 .. 4)
    {
        if (batch[i] != i + 1)
            throw new Exception(
                "forced batch ordering failure");
    }

    if (
        !ownerFound ||
        ownerValue != 8)
    {
        throw new Exception(
            "forced owner result failure");
    }

    if (busyRetries == 0)
        throw new Exception(
            "owner busy path not exercised");

    foreach (value; batch)
    {
        if (value == ownerValue)
            throw new Exception(
                "forced overlap duplicate");
    }

    if (queue.researchBatchBusy())
        throw new Exception(
            "busy marker leaked");

    /*
     * Remaining queue must be 5,6,7.
     */
    foreach (expected; [7UL, 6UL, 5UL])
    {
        const result =
            queue.pop();

        if (
            !result.found ||
            result.value != expected)
        {
            throw new Exception(
                "forced remainder failure");
        }
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "forced queue not empty");
}

private Thread makeBatchThief(
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

private void wrapStress(
    size_t rounds,
    size_t thiefCount)
{
    if (
        rounds == 0 ||
        thiefCount == 0)
    {
        throw new Exception(
            "invalid stress arguments");
    }

    const participants =
        cast(uint)(
            thiefCount + 1);

    const totalSubmitted =
        rounds *
        Queue.capacity;

    /*
     * Start four positions before the full 64-bit counter maximum.
     * Filling the queue crosses ulong.max -> 0 on every round.
     */
    const startIndex =
        ulong.max -
        3;

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
            makeBatchThief(
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
    size_t leakedBusyState;

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
            queue.sizeSnapshot() !=
            Queue.capacity)
        {
            throw new Exception(
                "stress fill size mismatch");
        }

        startBarrier.wait();

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

        if (queue.researchBatchBusy())
            ++leakedBusyState;

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
        ownerPopped +
        stolen;

    writefln(
        "rounds=%s capacity=%s thieves=%s batch=%s submitted=%s",
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
        "successfulBatches=%s partialBatches=%s",
        successfulBatches,
        partialBatches);

    writefln(
        "missing=%s duplicateValues=%s duplicateRecords=%s outOfRange=%s",
        missing,
        duplicateValues,
        duplicateRecords,
        outOfRange);

    writefln(
        "pushFailures=%s nonEmptyAfterDrain=%s invalidEmptyState=%s leakedBusy=%s",
        pushFailures,
        nonEmptyAfterDrain,
        invalidEmptyState,
        leakedBusyState);

    if (
        pushFailures != 0 ||
        nonEmptyAfterDrain != 0 ||
        invalidEmptyState != 0 ||
        leakedBusyState != 0)
    {
        throw new Exception(
            "stress queue state failure");
    }

    if (
        missing != 0 ||
        duplicateValues != 0 ||
        duplicateRecords != 0 ||
        outOfRange != 0)
    {
        throw new Exception(
            "stress accounting failure");
    }

    if (returned != totalSubmitted)
        throw new Exception(
            "stress returned mismatch");

    if (stolen == 0)
        throw new Exception(
            "stress no thief progress");

    if (
        thiefCount >= 2 &&
        activeThieves < 2)
    {
        throw new Exception(
            "stress insufficient thief coverage");
    }

    if (successfulBatches == 0)
        throw new Exception(
            "stress no successful batches");

    if (!queue.emptySnapshot())
        throw new Exception(
            "stress final queue not empty");
}

void main(string[] args)
{
    size_t rounds =
        defaultRounds;

    size_t thiefCount =
        defaultThieves;

    if (args.length > 1)
        rounds =
            args[1].to!size_t;

    if (args.length > 2)
        thiefCount =
            args[2].to!size_t;

    forcedOverlapGate();

    wrapStress(
        rounds,
        thiefCount);

    writeln(
        "R0.1 P08g1 PASS: full64 marked-top survives forced overlap and full wrap stress");
}
