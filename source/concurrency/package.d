/**
 * Explicit CPU task execution with typed results and bounded admission.
 *
 * Version-zero API candidate: import this module for Executor, TaskHandle,
 * TaskScope, CancellationToken and executor-use exceptions. Submission is
 * @system and does not prove safe arbitrary captures. Keep the executor rooted
 * and explicitly closeAndJoin it before releasing task referents. Native
 * worker-lifetime uncertainty is fatal.
 */
module concurrency;

public import concurrency.executor : Executor, JoinResult;
public import concurrency.cancellation : CancellationToken;
public import concurrency.task : TaskHandle;
public import concurrency.work_size : WorkSize;
public import concurrency.taskscope : TaskScope;
public import concurrency.errors : ExecutorClosedException, WorkerSelfJoinException;
