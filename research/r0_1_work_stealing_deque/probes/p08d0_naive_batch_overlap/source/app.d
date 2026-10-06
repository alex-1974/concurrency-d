module app;

import concurrency.research.modular_bounded_wsq_batch_naive :
    NaiveBatchBoundedWorkStealingDeque;

import std.stdio :
    writefln,
    writeln;

alias Queue =
    NaiveBatchBoundedWorkStealingDeque!(
        size_t,
        3);

void main()
{
    Queue queue;

    queue.researchSetEmptyIndex(0);

    foreach (value; 1 .. Queue.capacity + 1)
    {
        if (!queue.tryPush(value))
            throw new Exception(
                "initial fill failed");
    }

    if (queue.sizeSnapshot() != Queue.capacity)
        throw new Exception(
            "initial size mismatch");

    /*
     * Thief observes:
     *
     *     top    = 0
     *     bottom = 8
     *
     * and plans to reserve slots 0..3.
     */
    const observation =
        queue.researchObserveNaiveBatch(4);

    writefln(
        "observed top=%s count=%s bottom=%s",
        observation.top,
        observation.count,
        queue.researchBottomSnapshot());

    if (
        observation.top != 0 ||
        observation.count != 4)
    {
        throw new Exception(
            "unexpected observation");
    }

    /*
     * Before the thief commits its batch reservation, the sole owner
     * removes five values from the opposite end:
     *
     *     8, 7, 6, 5, 4
     *
     * Value 4 therefore already belongs to the owner.
     */
    size_t[5] ownerValues;

    foreach (i; 0 .. ownerValues.length)
    {
        const result =
            queue.pop();

        if (!result.found)
            throw new Exception(
                "owner pop unexpectedly empty");

        ownerValues[i] =
            result.value;
    }

    writefln(
        "after owner pops top=%s bottom=%s",
        queue.researchTopSnapshot(),
        queue.researchBottomSnapshot());

    writefln(
        "owner values=%s,%s,%s,%s,%s",
        ownerValues[0],
        ownerValues[1],
        ownerValues[2],
        ownerValues[3],
        ownerValues[4]);

    /*
     * The stale observation still has top == 0.
     *
     * Since the owner does not modify top for these ordinary multi-item
     * pops, CAS(0 -> 4) can still succeed even though bottom is now 3.
     */
    size_t[4] batchValues;

    const stolen =
        queue.researchCommitNaiveBatch(
            observation,
            batchValues[]);

    writefln(
        "batch stolen=%s values=%s,%s,%s,%s",
        stolen,
        batchValues[0],
        batchValues[1],
        batchValues[2],
        batchValues[3]);

    writefln(
        "final top=%s bottom=%s sizeSnapshot=%s",
        queue.researchTopSnapshot(),
        queue.researchBottomSnapshot(),
        queue.sizeSnapshot());

    if (stolen != 4)
        throw new Exception(
            "naive batch CAS did not reproduce");

    /*
     * Owner already returned value 4.
     * Batch also returns value 4.
     */
    size_t duplicateCount;

    foreach (ownerValue; ownerValues)
    {
        foreach (batchValue; batchValues)
        {
            if (ownerValue == batchValue)
                ++duplicateCount;
        }
    }

    writefln(
        "duplicateCount=%s",
        duplicateCount);

    if (duplicateCount != 1)
        throw new Exception(
            "expected duplicate not reproduced");

    if (
        ownerValues[4] != 4 ||
        batchValues[3] != 4)
    {
        throw new Exception(
            "expected duplicated value is not 4");
    }

    /*
     * We started with 8 tasks but have now returned:
     *
     *     5 owner + 4 thief = 9
     *
     * and top has advanced beyond bottom.
     */
    if (
        queue.researchTopSnapshot() != 4 ||
        queue.researchBottomSnapshot() != 3)
    {
        throw new Exception(
            "expected invalid counter state not reproduced");
    }

    writeln(
        "R0.1 P08d0 PASS: naive multi-item top CAS is rejected");
}
