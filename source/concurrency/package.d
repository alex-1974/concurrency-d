/**
 * Explicit CPU task execution with typed results and bounded admission.
 *
 * Version-zero API candidate: import this module for Executor, TaskHandle and
 * executor-use exceptions. Submission is @system and does not prove safe
 * arbitrary captures. Keep the executor rooted and explicitly closeAndJoin it
 * before releasing task referents. Native worker-lifetime uncertainty is fatal.
 */
module concurrency;

public import concurrency.executor : Executor;
public import concurrency.task : TaskHandle;
public import concurrency.errors : ExecutorClosedException, WorkerSelfJoinException;
