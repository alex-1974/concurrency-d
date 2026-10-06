module app;

import concurrency.research.bounded_wsq :
    BoundedWorkStealingDeque;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.conv : to;
import std.stdio : writefln, writeln;

alias Queue = BoundedWorkStealingDeque!(size_t, 8);

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
    /*
     * Each call creates a distinct closure activation.
     *
     * This is deliberate: constructing the delegate directly inside the
     * foreach that creates all threads can cause loop-local capture state to
     * be shared in ways that make the probe itself racy.
     */
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

    const totalSubmitted = rounds * Queue.capacity;

    Queue queue;

    /*
     * Main thread is the unique owner for the entire probe:
     *
     * - tryPush
     * - pop
     * - final drain
     *
     * Worker threads call only steal.
     */
    assert(thiefCount < uint.max);

    const barrierParticipants = cast(uint)(thiefCount + 1);

    auto startBarrier = new Barrier(barrierParticipants);
    auto finishBarrier = new Barrier(barrierParticipants);

    auto states = new ThiefState[thiefCount];
    auto threads = new Thread[thiefCount];

    foreach (thiefId; 0 .. thiefCount)
    {
        auto state = new ThiefState;

        /*
         * Each thief owns its result buffer exclusively while running.
         */
        state.values.reserve(
            (rounds * Queue.capacity) / thiefCount + Queue.capacity);

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

    size_t pushFailures;
    size_t nonEmptyAfterDrain;

    foreach (round; 0 .. rounds)
    {
        const base = round * Queue.capacity;

        /*
         * Fill the bounded deque completely before thieves are released.
         */
        foreach (i; 0 .. Queue.capacity)
        {
            const value = base + i + 1;

            if (!queue.tryPush(value))
                ++pushFailures;
        }

        startBarrier.wait();

        /*
         * Owner races from the bottom while all thieves race from the top.
         */
        foreach (attempt; 0 .. Queue.capacity * 2)
        {
            if (((attempt + round) & 31) == 0)
                Thread.yield();

            const result = queue.pop();

            if (result.found)
                ownerValues ~= result.value;
        }

        finishBarrier.wait();

        /*
         * No thieves access the deque after finishBarrier for this round.
         *
         * Drain any work that survived the concurrent phase. Use a bounded
         * number of calls so a broken deque cannot hang the probe.
         */
        foreach (_; 0 .. Queue.capacity + 1)
        {
            const result = queue.pop();

            if (!result.found)
                break;

            ownerValues ~= result.value;
        }

        if (!queue.emptySnapshot())
            ++nonEmptyAfterDrain;
    }

    foreach (thread; threads)
        thread.join();

    /*
     * Merge results only after all thief threads have terminated.
     * No synchronization is required for the accounting phase itself.
     */
    auto seen = new uint[totalSubmitted + 1];

    size_t ownerPopped;
    size_t stolen;
    size_t outOfRange;
    size_t duplicateRecords;

    foreach (value; ownerValues)
    {
        ++ownerPopped;

        if (value == 0 || value > totalSubmitted)
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

            if (value == 0 || value > totalSubmitted)
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

    foreach (value; 1 .. totalSubmitted + 1)
    {
        if (seen[value] == 0)
            ++missing;
        else if (seen[value] > 1)
            ++duplicateValues;
    }

    const returned = ownerPopped + stolen;

    writefln(
        "rounds=%s capacity=%s thieves=%s submitted=%s",
        rounds,
        Queue.capacity,
        thiefCount,
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
        "pushFailures=%s nonEmptyAfterDrain=%s",
        pushFailures,
        nonEmptyAfterDrain);

    assert(pushFailures == 0);
    assert(nonEmptyAfterDrain == 0);

    assert(outOfRange == 0);
    assert(missing == 0);
    assert(duplicateValues == 0);
    assert(duplicateRecords == 0);

    assert(returned == totalSubmitted);

    /*
     * Coverage gate:
     * with multiple thief threads and hundreds of rounds, at least two
     * thieves must actually have succeeded for this to count as a
     * multi-thief execution.
     */
    if (thiefCount >= 2)
        assert(activeThieves >= 2);

    assert(stolen != 0);
    assert(queue.emptySnapshot());

    writeln(
        "R0.1 P03 PASS: multi-thief accounting and uniqueness");
}
