/** Exceptions from executor use; ordinary task failures retain their own type. */
module concurrency.errors;

/** Submission observed an executor that is draining or already joined. */
final class ExecutorClosedException : Exception
{
    this() { super("executor is closed"); }
}

/**
 * A worker attempted to close its own executor. The operation is rejected
 * before the lifecycle lock/state transition, including during external drain.
 */
final class WorkerSelfJoinException : Exception
{
    this() { super("an executor worker cannot close and join its own pool"); }
}
