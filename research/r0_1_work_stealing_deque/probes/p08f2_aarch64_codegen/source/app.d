module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

alias Queue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        8);

pragma(inline, false)
extern(C)
size_t p08f2_pop(
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
size_t p08f2_batch(
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
size_t p08f2_steal(
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

/*
 * No main is required for the assembly-only cross-target probe.
 */
