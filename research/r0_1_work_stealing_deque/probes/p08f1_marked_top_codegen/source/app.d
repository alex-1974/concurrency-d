module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import std.stdio : writefln;

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        8);

/*
 * Stable C symbols deliberately prevent the probe from depending on
 * D mangling. The wrapper itself is not inlined, while the queue operation
 * may still be optimized into it exactly as in production-style code.
 */

pragma(inline, false)
extern(C)
size_t p08f1_pop(
    Queue* queue,
    size_t* output)
{
    const result =
        queue.pop();

    if (!result.found)
        return 0;

    *output =
        result.value;

    return 1;
}

pragma(inline, false)
extern(C)
size_t p08f1_batch(
    Queue* queue,
    size_t* output,
    size_t count)
{
    if (count > Queue.capacity)
        count =
            Queue.capacity;

    return queue.stealBatch(
        output[0 .. count]);
}

pragma(inline, false)
extern(C)
size_t p08f1_steal(
    Queue* queue,
    size_t* output)
{
    const result =
        queue.steal();

    if (!result.found)
        return 0;

    *output =
        result.value;

    return 1;
}

void main()
{
    Queue queue;

    foreach (i; 0 .. 32)
    {
        if (!queue.tryPush(i + 1))
            throw new Exception(
                "probe fill failed");
    }

    size_t[8] batch;
    size_t popped;
    size_t stolen;

    const batchCount =
        p08f1_batch(
            &queue,
            batch.ptr,
            batch.length);

    const popCount =
        p08f1_pop(
            &queue,
            &popped);

    const stealCount =
        p08f1_steal(
            &queue,
            &stolen);

    ulong checksum;

    foreach (
        value;
        batch[0 .. batchCount])
    {
        checksum +=
            cast(ulong) value;
    }

    if (popCount != 0)
        checksum +=
            cast(ulong) popped;

    if (stealCount != 0)
        checksum +=
            cast(ulong) stolen;

    writefln(
        "batch=%s pop=%s steal=%s checksum=%s",
        batchCount,
        popCount,
        stealCount,
        checksum);
}
