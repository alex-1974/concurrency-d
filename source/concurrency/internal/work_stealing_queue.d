/**
 * Package-internal local work-queue binding.
 *
 * The reusable single-owner / multi-thief deque is owned by containers-d.
 * concurrency-d owns only scheduler policy around the primitive.
 */
module concurrency.internal.work_stealing_queue;

import containers :
    WorkStealingDeque;

/**
 * Selected local worker queue primitive.
 *
 * This is an alias, not a wrapper: no operation, storage, ordering or policy
 * layer is introduced by concurrency-d.
 */
package(concurrency)
alias LocalWorkStealingDeque(
    T,
    size_t Capacity) =
        WorkStealingDeque!(
            T,
            Capacity);

version (unittest)
{
    private struct AdoptionTaskRecord
    {
        ulong id;
    }

    private struct AdoptionTaskRef
    {
        shared(AdoptionTaskRecord)* ptr;
    }

    private shared AdoptionTaskRecord[4]
        adoptionRecords;
}

unittest
{
    LocalWorkStealingDeque!(
        AdoptionTaskRef,
        8) queue;

    foreach (i; 0 .. 4)
    {
        adoptionRecords[i].id =
            cast(ulong) i + 1;

        auto task =
            AdoptionTaskRef(
                &adoptionRecords[i]);

        assert(
            queue.tryPush(
                task));
    }

    const stolen =
        queue.steal();

    assert(stolen.found);
    assert(
        stolen.value.ptr ==
        &adoptionRecords[0]);

    AdoptionTaskRef[2] batch;

    const taken =
        queue.stealBatch(
            batch[]);

    assert(taken == 2);
    assert(
        batch[0].ptr ==
        &adoptionRecords[1]);
    assert(
        batch[1].ptr ==
        &adoptionRecords[2]);

    const owner =
        queue.pop();

    assert(owner.found);
    assert(
        owner.value.ptr ==
        &adoptionRecords[3]);

    assert(
        !queue.pop().found);
}
