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

unittest
{
    LocalWorkStealingDeque!(
        ulong,
        8) queue;

    assert(queue.tryPush(10));
    assert(queue.tryPush(20));

    const stolen =
        queue.steal();

    assert(stolen.found);
    assert(stolen.value == 10);

    const owner =
        queue.pop();

    assert(owner.found);
    assert(owner.value == 20);
}
