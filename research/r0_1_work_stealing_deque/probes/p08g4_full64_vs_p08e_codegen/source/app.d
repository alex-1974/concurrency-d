module app;

import concurrency.research.modular_bounded_wsq_batch_marked_top :
    MarkedTopBatchBoundedWorkStealingDeque;

import concurrency.research.modular_bounded_wsq_batch_full64_marked_top :
    Full64DistanceMarkedBoundedWorkStealingDeque;

import std.stdio : writefln;

alias P08eQueue =
    MarkedTopBatchBoundedWorkStealingDeque!(
        size_t,
        8);

alias Full64Queue =
    Full64DistanceMarkedBoundedWorkStealingDeque!(
        size_t,
        8);

/*
 * Stable C symbols keep the comparison independent of D mangling.
 *
 * The wrappers themselves are not inlined. The queue operations are free
 * to inline into them, which exposes the actual optimized hot-path code.
 */

pragma(inline, false)
extern(C)
size_t p08g4_p08e_batch(
    P08eQueue* queue,
    size_t* output,
    size_t count)
{
    if (count > P08eQueue.capacity)
        count =
            P08eQueue.capacity;

    return queue.stealBatch(
        output[0 .. count]);
}

pragma(inline, false)
extern(C)
size_t p08g4_full64_batch(
    Full64Queue* queue,
    size_t* output,
    size_t count)
{
    if (count > Full64Queue.capacity)
        count =
            Full64Queue.capacity;

    return queue.stealBatch(
        output[0 .. count]);
}

pragma(inline, false)
extern(C)
size_t p08g4_p08e_pop(
    P08eQueue* queue,
    size_t* output)
{
    const result =
        queue.pop();

    if (!result.found)
        return 0;

    *output = result.value;
    return 1;
}

pragma(inline, false)
extern(C)
size_t p08g4_full64_pop(
    Full64Queue* queue,
    size_t* output)
{
    const result =
        queue.pop();

    if (!result.found)
        return 0;

    *output = result.value;
    return 1;
}

pragma(inline, false)
extern(C)
size_t p08g4_p08e_steal(
    P08eQueue* queue,
    size_t* output)
{
    const result =
        queue.steal();

    if (!result.found)
        return 0;

    *output = result.value;
    return 1;
}

pragma(inline, false)
extern(C)
size_t p08g4_full64_steal(
    Full64Queue* queue,
    size_t* output)
{
    const result =
        queue.steal();

    if (!result.found)
        return 0;

    *output = result.value;
    return 1;
}

void main()
{
    P08eQueue p08e;
    Full64Queue full64;

    foreach (i; 0 .. 32)
    {
        if (!p08e.tryPush(i + 1))
            throw new Exception(
                "P08e probe fill failed");

        if (!full64.tryPush(i + 1))
            throw new Exception(
                "Full64 probe fill failed");
    }

    size_t[8] p08eBatch;
    size_t[8] full64Batch;

    size_t p08ePop;
    size_t full64Pop;

    size_t p08eSteal;
    size_t full64Steal;

    const p08eBatchCount =
        p08g4_p08e_batch(
            &p08e,
            p08eBatch.ptr,
            p08eBatch.length);

    const full64BatchCount =
        p08g4_full64_batch(
            &full64,
            full64Batch.ptr,
            full64Batch.length);

    const p08ePopCount =
        p08g4_p08e_pop(
            &p08e,
            &p08ePop);

    const full64PopCount =
        p08g4_full64_pop(
            &full64,
            &full64Pop);

    const p08eStealCount =
        p08g4_p08e_steal(
            &p08e,
            &p08eSteal);

    const full64StealCount =
        p08g4_full64_steal(
            &full64,
            &full64Steal);

    ulong p08eChecksum;
    ulong full64Checksum;

    foreach (
        value;
        p08eBatch[0 .. p08eBatchCount])
    {
        p08eChecksum += value;
    }

    foreach (
        value;
        full64Batch[0 .. full64BatchCount])
    {
        full64Checksum += value;
    }

    if (p08ePopCount)
        p08eChecksum += p08ePop;

    if (full64PopCount)
        full64Checksum += full64Pop;

    if (p08eStealCount)
        p08eChecksum += p08eSteal;

    if (full64StealCount)
        full64Checksum += full64Steal;

    writefln(
        "p08e batch=%s pop=%s steal=%s checksum=%s",
        p08eBatchCount,
        p08ePopCount,
        p08eStealCount,
        p08eChecksum);

    writefln(
        "full64 batch=%s pop=%s steal=%s checksum=%s",
        full64BatchCount,
        full64PopCount,
        full64StealCount,
        full64Checksum);
}
