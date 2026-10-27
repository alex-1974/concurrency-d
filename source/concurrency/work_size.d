/** Caller-provided scheduling hints for submitted work. */
module concurrency.work_size;

/**
 * Approximate execution cost for one submitted callable.
 *
 * `small` preserves the default inbox batching policy. `large` asks workers to
 * claim that task alone from shared ingress, leaving following tasks visible
 * to other workers. This is only a hint: the executor cannot inspect, split,
 * preempt or predict an opaque callable.
 */
enum WorkSize : ubyte
{
    small,
    large
}
