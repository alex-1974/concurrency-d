module app;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.conv : to;
import std.stdio : writefln, writeln;

alias Queue = ModularBoundedWorkStealingDeque!(size_t, 8);

enum size_t defaultRounds = 500;
enum size_t defaultThieves = 4;

final class ThiefState
{
    size_t[] values;

    void record(size_t value)
    {
        values ~= value;
    }
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
        foreach (round; 0 .. rounds)
        {
            startBarrier.wait();

            foreach (attempt; 0 .. Queue.capacity * 2)
            {
                if (((attempt + id + round) & 31) == 0)
                    Thread.yield();

                const result = queue.steal();

                if (result.found)
                    state.record(result.value);
            }

            finishBarrier.wait();
        }
    });
}

void main(string[] args)
{
    size_t rounds = defaultRounds;
    size_t thiefCount = defaultThieves;

    if (args.length > 1)
        rounds = args[1].to!size_t;

    if (args.length > 2)
        thiefCount = args[2].to!size_t;

    assert(rounds > 0);
    assert(thiefCount > 0);
    assert(thiefCount < uint.max);

    const barrierParticipants =
        cast(uint)(thiefCount + 1);

    const totalSubmitted =
        rounds * Queue.capacity;

    /*
     * Start each round half a capacity before ulong.max.
     *
     * For capacity 256:
     *
     *     start = ulong.max - 127
     *
     * Filling 256 elements necessarily crosses:
     *
     *     ulong.max -> 0
     *
     * while leaving a completely valid bounded queue.
     */
    enum ulong startIndex =
        ulong.max - (Queue.capacity / 2 - 1);

    enum ulong expectedFilledBottom =
        startIndex + cast(ulong) Queue.capacity;

    Queue queue;

    auto startBarrier =
        new Barrier(barrierParticipants);

    auto finishBarrier =
        new Barrier(barrierParticipants);

    auto states =
        new ThiefState[thiefCount];

    auto threads =
        new Thread[thiefCount];

    foreach (thiefId; 0 .. thiefCount)
    {
        auto state = new ThiefState;

        state.values.reserve(
            (rounds * Queue.capacity) /
                thiefCount +
            Queue.capacity);

        states[thiefId] = state;

        threads[thiefId] = makeThiefThread(
            thiefId,
            state,
            &queue,
            startBarrier,
            finishBarrier,
            rounds);
    }

    foreach (thread; threads)
        thread.start();

    size_t[] ownerValues;
    ownerValues.reserve(totalSubmitted);

    size_t pushFailures;
    size_t nonEmptyAfterDrain;
    size_t invalidEmptyState;

    foreach (round; 0 .. rounds)
    {
        /*
         * All thieves are still waiting at startBarrier here.
         * The main thread is the sole owner.
         */
        queue.researchSetEmptyIndex(startIndex);

        const base =
            round * Queue.capacity;

        foreach (i; 0 .. Queue.capacity)
        {
            const value =
                base + i + 1;

            if (!queue.tryPush(value))
                ++pushFailures;
        }

        /*
         * Verify that the fill really crossed the modular boundary.
         */
        assert(
            queue.researchTopSnapshot() ==
            startIndex);

        assert(
            queue.researchBottomSnapshot() ==
            expectedFilledBottom);

        assert(
            queue.sizeSnapshot() ==
            Queue.capacity);

        startBarrier.wait();

        /*
         * Main thread remains the unique owner and races from the bottom.
         */
        foreach (attempt; 0 .. Queue.capacity * 2)
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
         * Thieves are now quiescent for this round.
         * Drain anything that survived the concurrent phase.
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

        /*
         * A mixed pop/steal drain does NOT have one predetermined final
         * absolute index.
         *
         * Thieves advance top from the front while the owner moves bottom
         * backwards from the rear. The valid empty state is the point where
         * both sides meet somewhere inside the original occupied interval.
         */
        const finalTop =
            queue.researchTopSnapshot();

        const finalBottom =
            queue.researchBottomSnapshot();

        const meetingOffset =
            finalTop - startIndex;

        if (
            finalTop != finalBottom ||
            meetingOffset > cast(ulong) Queue.capacity)
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

    size_t activeThieves;

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
        "rounds=%s capacity=%s thieves=%s submitted=%s",
        rounds,
        Queue.capacity,
        thiefCount,
        totalSubmitted);

    writefln(
        "startIndex=%s expectedFilledBottom=%s",
        startIndex,
        expectedFilledBottom);

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

    assert(pushFailures == 0);
    assert(nonEmptyAfterDrain == 0);
    assert(invalidEmptyState == 0);

    assert(outOfRange == 0);
    assert(missing == 0);
    assert(duplicateValues == 0);
    assert(duplicateRecords == 0);

    assert(returned == totalSubmitted);

    if (thiefCount >= 2)
        assert(activeThieves >= 2);

    assert(stolen != 0);
    assert(queue.emptySnapshot());

    writeln(
        "R0.1 P03b PASS: modular multi-thief accounting survives ulong wrap");
}
