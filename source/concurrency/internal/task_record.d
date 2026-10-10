/**
 * Internal, non-owning task transport for the M0 execution core.
 *
 * The queue transports TaskRef values; the caller owns the actual records
 * until every worker that might reference them has joined. This module does
 * not provide a public task-lifetime or exception contract.
 */
module concurrency.internal.task_record;

import core.atomic :
    MemoryOrder,
    atomicLoad;

/**
 * The first member of any record submitted to the internal worker batch.
 * A concrete record installs a matching execute thunk before publication.
 */
package(concurrency) struct TaskHeader
{
    alias ExecuteFn =
        void function(shared(TaskHeader)*)
        @safe nothrow;

    ExecuteFn execute;
}

/** Non-owning one-word handle for queues and worker handoff. */
package(concurrency) struct TaskRef
{
    shared(TaskHeader)* ptr;
}

static assert(size_t.sizeof == 8,
    "The qualified work-stealing transport currently requires 64-bit targets.");
static assert(TaskHeader.sizeof == 8);
static assert(TaskRef.sizeof == 8);

/**
 * The queued record must have been fully initialized before publication and
 * must remain alive until the synchronous worker batch has completed.
 */
package(concurrency) void dispatchTask(TaskRef task)
    @safe nothrow
{
    assert(task.ptr !is null);

    const execute =
        atomicLoad!(MemoryOrder.raw)(task.ptr.execute);

    assert(execute !is null);
    execute(task.ptr);
}
