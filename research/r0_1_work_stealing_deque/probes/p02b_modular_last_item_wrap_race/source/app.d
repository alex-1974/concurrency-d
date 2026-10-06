module app;

import concurrency.research.modular_bounded_wsq :
    ModularBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicLoad,
    atomicStore;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.conv : to;
import std.stdio : writefln, writeln;

alias Queue = ModularBoundedWorkStealingDeque!(size_t, 1);

enum size_t defaultIterations = 100_000;

void main(string[] args)
{
    size_t iterations = defaultIterations;

    if (args.length > 1)
        iterations = args[1].to!size_t;

    Queue queue;

    auto startBarrier  = new Barrier(3);
    auto finishBarrier = new Barrier(3);
    auto gateBarrier   = new Barrier(3);

    shared bool ownerFound;
    shared size_t ownerValue;

    shared bool thiefFound;
    shared size_t thiefValue;

    shared bool pushFailed;

    /*
     * The owner thread performs all owner-side deque operations:
     *
     * - research empty-index setup
     * - tryPush
     * - pop
     *
     * Each iteration starts empty at ulong.max. One push therefore changes:
     *
     *     top    = ulong.max
     *     bottom = 0
     *
     * The last-item pop/steal race consequently happens across the modular
     * counter boundary on every iteration.
     */
    auto owner = new Thread({
        foreach (iteration; 0 .. iterations)
        {
            queue.researchSetEmptyIndex(ulong.max);

            const value = iteration + 1;

            if (!queue.tryPush(value))
                atomicStore!(MemoryOrder.rel)(pushFailed, true);

            startBarrier.wait();

            if ((iteration & 1) != 0)
                Thread.yield();

            const result = queue.pop();

            atomicStore!(MemoryOrder.rel)(ownerValue, result.value);
            atomicStore!(MemoryOrder.rel)(ownerFound, result.found);

            finishBarrier.wait();
            gateBarrier.wait();
        }
    });

    auto thief = new Thread({
        foreach (iteration; 0 .. iterations)
        {
            startBarrier.wait();

            if ((iteration & 1) == 0)
                Thread.yield();

            const result = queue.steal();

            atomicStore!(MemoryOrder.rel)(thiefValue, result.value);
            atomicStore!(MemoryOrder.rel)(thiefFound, result.found);

            finishBarrier.wait();
            gateBarrier.wait();
        }
    });

    owner.start();
    thief.start();

    size_t ownerWins;
    size_t thiefWins;
    size_t violations;
    size_t nonCanonicalEmpty;

    foreach (iteration; 0 .. iterations)
    {
        const expected = iteration + 1;

        atomicStore!(MemoryOrder.rel)(ownerFound, false);
        atomicStore!(MemoryOrder.rel)(ownerValue, 0);
        atomicStore!(MemoryOrder.rel)(thiefFound, false);
        atomicStore!(MemoryOrder.rel)(thiefValue, 0);

        startBarrier.wait();
        finishBarrier.wait();

        const oFound =
            atomicLoad!(MemoryOrder.acq)(ownerFound);
        const oValue =
            atomicLoad!(MemoryOrder.acq)(ownerValue);

        const tFound =
            atomicLoad!(MemoryOrder.acq)(thiefFound);
        const tValue =
            atomicLoad!(MemoryOrder.acq)(thiefValue);

        /*
         * Exactly one contender must receive the single element.
         */
        if (oFound == tFound)
        {
            ++violations;
        }
        else if (oFound)
        {
            ++ownerWins;

            if (oValue != expected)
                ++violations;
        }
        else
        {
            ++thiefWins;

            if (tValue != expected)
                ++violations;
        }

        /*
         * The queue must be logically empty after both contenders finish.
         */
        if (!queue.emptySnapshot())
            ++violations;

        /*
         * Starting at ulong.max and consuming the pushed element should leave
         * both modular counters at zero, regardless of which side won.
         */
        if (queue.researchTopSnapshot() != 0 ||
            queue.researchBottomSnapshot() != 0)
        {
            ++nonCanonicalEmpty;
        }

        gateBarrier.wait();
    }

    owner.join();
    thief.join();

    const failedPush =
        atomicLoad!(MemoryOrder.acq)(pushFailed);

    writefln(
        "iterations=%s ownerWins=%s thiefWins=%s violations=%s",
        iterations,
        ownerWins,
        thiefWins,
        violations);

    writefln(
        "nonCanonicalEmpty=%s finalTop=%s finalBottom=%s",
        nonCanonicalEmpty,
        queue.researchTopSnapshot(),
        queue.researchBottomSnapshot());

    assert(!failedPush);
    assert(violations == 0);
    assert(nonCanonicalEmpty == 0);

    /*
     * Coverage gate: both CAS outcomes must actually occur.
     */
    assert(ownerWins != 0);
    assert(thiefWins != 0);

    assert(queue.emptySnapshot());

    writeln(
        "R0.1 P02b PASS: modular last-item race survives ulong wrap");
}
