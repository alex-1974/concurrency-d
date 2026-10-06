module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import std.stdio :
    writefln,
    writeln;

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        3);

private void sequentialGate()
{
    Queue queue;

    foreach (value; 1 .. 9)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "sequential fill failed");
    }

    size_t[4] first;
    size_t[4] second;

    const n1 =
        queue.stealBatch(
            first[]);

    const n2 =
        queue.stealBatch(
            second[]);

    if (n1 != 4 || n2 != 4)
        throw new Exception(
            "sequential batch counts incorrect");

    foreach (i; 0 .. 4)
    {
        if (first[i] != i + 1)
            throw new Exception(
                "first batch order failure");

        if (second[i] != i + 5)
            throw new Exception(
                "second batch order failure");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "sequential queue not empty");
}

private void ownerBatchSeparationGate()
{
    Queue queue;

    foreach (value; 1 .. 9)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "separation fill failed");
    }

    size_t[4] batch;

    const stolen =
        queue.stealBatch(
            batch[]);

    if (stolen != 4)
        throw new Exception(
            "batch claim failed");

    /*
     * Once 1..4 have been batch-claimed, owner pops must consume only
     * the opposite remaining range.
     */
    size_t[4] owner;

    foreach (i; 0 .. 4)
    {
        const result =
            queue.pop();

        if (!result.found)
            throw new Exception(
                "owner pop failed");

        owner[i] =
            result.value;
    }

    writefln(
        "batch=%s,%s,%s,%s",
        batch[0],
        batch[1],
        batch[2],
        batch[3]);

    writefln(
        "owner=%s,%s,%s,%s",
        owner[0],
        owner[1],
        owner[2],
        owner[3]);

    foreach (a; batch)
    {
        foreach (b; owner)
        {
            if (a == b)
                throw new Exception(
                    "batch/owner duplicate");
        }
    }

    if (
        batch !=
        [1UL, 2UL, 3UL, 4UL])
    {
        throw new Exception(
            "batch ordering mismatch");
    }

    if (
        owner !=
        [8UL, 7UL, 6UL, 5UL])
    {
        throw new Exception(
            "owner ordering mismatch");
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "separation queue not empty");
}

private void modularWrapGate()
{
    Queue queue;

    const start =
        Queue.researchCounterMask - 3;

    queue.researchSetEmptyIndex(
        start);

    foreach (value; 1 .. 9)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "wrap fill failed");
    }

    size_t[4] batch;

    const stolen =
        queue.stealBatch(
            batch[]);

    if (stolen != 4)
        throw new Exception(
            "wrap batch failed");

    foreach (i; 0 .. 4)
    {
        if (batch[i] != i + 1)
            throw new Exception(
                "wrap batch order failure");
    }

    foreach (expected; [8UL, 7UL, 6UL, 5UL])
    {
        const result =
            queue.pop();

        if (
            !result.found ||
            result.value != expected)
        {
            throw new Exception(
                "wrap owner order failure");
        }
    }

    if (!queue.emptySnapshot())
        throw new Exception(
            "wrap queue not empty");

    writefln(
        "wrap finalTop=%s finalBottom=%s",
        queue.researchTopSnapshot(),
        queue.researchBottomSnapshot());
}

void main()
{
    sequentialGate();
    ownerBatchSeparationGate();
    modularWrapGate();

    writeln(
        "R0.1 P08e0 PASS: marked-top batch preserves basic semantics");
}
