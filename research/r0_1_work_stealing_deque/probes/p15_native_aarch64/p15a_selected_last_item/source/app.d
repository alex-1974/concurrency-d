module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import core.atomic :
    MemoryOrder,
    atomicLoad,
    atomicStore;

import core.sync.barrier : Barrier;
import core.thread : Thread;

import std.conv : to;
import std.stdio : writefln, writeln;

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        1);

enum size_t DefaultIterations = 100_000;

void main(string[] args)
{
    size_t iterations =
        DefaultIterations;

    if (args.length > 1)
        iterations =
            args[1].to!size_t;

    Queue queue;

    auto startBarrier =
        new Barrier(3);

    auto finishBarrier =
        new Barrier(3);

    auto gateBarrier =
        new Barrier(3);

    shared bool ownerFound;
    shared size_t ownerValue;

    shared bool thiefFound;
    shared size_t thiefValue;

    shared bool pushFailed;

    auto owner =
        new Thread({
            foreach (
                iteration;
                0 .. iterations)
            {
                const value =
                    iteration + 1;

                if (
                    !queue.tryPush(
                        value))
                {
                    atomicStore!(
                        MemoryOrder.rel)(
                            pushFailed,
                            true);
                }

                startBarrier.wait();

                if (
                    (iteration & 1) !=
                    0)
                {
                    Thread.yield();
                }

                const result =
                    queue.pop();

                atomicStore!(
                    MemoryOrder.rel)(
                        ownerValue,
                        result.value);

                atomicStore!(
                    MemoryOrder.rel)(
                        ownerFound,
                        result.found);

                finishBarrier.wait();
                gateBarrier.wait();
            }
        });

    auto thief =
        new Thread({
            foreach (
                iteration;
                0 .. iterations)
            {
                startBarrier.wait();

                if (
                    (iteration & 1) ==
                    0)
                {
                    Thread.yield();
                }

                const result =
                    queue.steal();

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefValue,
                        result.value);

                atomicStore!(
                    MemoryOrder.rel)(
                        thiefFound,
                        result.found);

                finishBarrier.wait();
                gateBarrier.wait();
            }
        });

    owner.start();
    thief.start();

    size_t ownerWins;
    size_t thiefWins;
    size_t violations;

    foreach (
        iteration;
        0 .. iterations)
    {
        const expected =
            iteration + 1;

        atomicStore!(
            MemoryOrder.rel)(
                ownerFound,
                false);

        atomicStore!(
            MemoryOrder.rel)(
                ownerValue,
                0);

        atomicStore!(
            MemoryOrder.rel)(
                thiefFound,
                false);

        atomicStore!(
            MemoryOrder.rel)(
                thiefValue,
                0);

        startBarrier.wait();
        finishBarrier.wait();

        const oFound =
            atomicLoad!(
                MemoryOrder.acq)(
                    ownerFound);

        const oValue =
            atomicLoad!(
                MemoryOrder.acq)(
                    ownerValue);

        const tFound =
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefFound);

        const tValue =
            atomicLoad!(
                MemoryOrder.acq)(
                    thiefValue);

        const winners =
            cast(size_t) oFound +
            cast(size_t) tFound;

        if (winners != 1)
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

        gateBarrier.wait();
    }

    owner.join();
    thief.join();

    if (
        atomicLoad!(
            MemoryOrder.acq)(
                pushFailed))
    {
        throw new Exception(
            "push failed");
    }

    if (violations != 0)
    {
        throw new Exception(
            "last-item violation");
    }

    if (
        ownerWins +
        thiefWins !=
        iterations)
    {
        throw new Exception(
            "winner accounting failure");
    }

    writefln(
        "iterations=%s ownerWins=%s thiefWins=%s violations=%s",
        iterations,
        ownerWins,
        thiefWins,
        violations);

    writeln(
        "R0.1 P15a PASS: selected P08e last-item race");
}
