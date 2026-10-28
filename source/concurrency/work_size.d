/** Caller-provided estimates of work cost for task and range scheduling. */
module concurrency.work_size;

/**
 * Approximate execution cost for one submitted callable or one range item.
 *
 * For submitted callables, `small` preserves the default inbox batching policy
 * and `large` asks workers to claim the task alone from shared ingress. For
 * indexed ranges, the estimate and item count select an inline path or a claim
 * grain. These are hints: the executor cannot inspect, split, preempt or
 * predict work, and the range heuristic may change between releases.
 */
enum WorkSize : ubyte
{
    small,
    large
}
