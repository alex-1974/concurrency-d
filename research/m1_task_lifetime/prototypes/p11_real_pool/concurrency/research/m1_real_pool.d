/++
 M1 P11 RESEARCH ONLY — a real M0 SubmissionWorkerPool over the actual
 containers-d work-stealing deques, receiving CT-specialized TaskRefs.

 IMPORTANT: This module is deliberately @system. The real M0 scheduler
 does NOT qualify abnormal worker death, native Thread.start/Thread.join
 failure or general borrowed-scoped TaskRef lifetime. This prototype
 tests normal successful execution only; compile acceptance does not
 promote a public @safe scheduler.
+/
module concurrency.research.m1_real_pool;

import concurrency.internal.task_record :
    TaskHeader, TaskRef;
import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;
import concurrency.research.m1_inline_transfer :
    isInlineTransfer;
import core.atomic :
    MemoryOrder, atomicLoad, atomicStore;
import core.thread : Thread;
import core.stdc.stdlib : abort;

enum size_t RealPoolCapacity = 256;

struct PoolResults(R) if (isInlineTransfer!R)
{
    size_t count;
    size_t accepted;
    size_t completed;
    size_t returned;
    size_t backpressureRetries;
    R[RealPoolCapacity] values;
}

/++
 Shared prefix allows the real M0 afterExecution hook to mark worker
 return AFTER dispatch and scheduler completion accounting. This is
 not a native-join replacement on error paths.
+/
private struct CompletionPrefix
{
    TaskHeader header;
    shared uint returned;
}

private void markReturned(TaskRef task) @trusted nothrow
{
    // Every task in this research pool is a header-first TypedRecord
    // with CompletionPrefix at offset zero. The pool's callback runs
    // only after the scheduler's final access to the TaskRef.
    auto prefix = cast(shared(CompletionPrefix)*) task.ptr;
    atomicStore!(MemoryOrder.rel)(prefix.returned, 1u);
}

private struct TypedRecord(P, R)
    if (isInlineTransfer!P && isInlineTransfer!R)
{
    @disable this(this);

    alias Operation = R function(P) @safe pure nothrow @nogc;
    CompletionPrefix prefix;
    Operation operation;
    P input;
    R output;

    static assert(prefix.offsetof == 0);

    void prepare(Operation fn, P copied) @safe
    {
        prefix.header.execute = &execute;
        atomicStore!(MemoryOrder.raw)(prefix.returned, 0u);
        operation = fn;
        input = copied;
    }

    TaskRef reference() @system
    {
        return TaskRef(cast(shared(TaskHeader)*) &prefix.header);
    }

    private static TypedRecord* fromHeader(shared(TaskHeader)* raw)
        @trusted nothrow @nogc
    {
        return cast(TypedRecord*) raw;
    }

    private static void execute(shared(TaskHeader)* raw) @safe nothrow
    {
        auto record = fromHeader(raw);
        record.output = record.operation(record.input);
    }
}

static assert(!__traits(compiles, {
    TypedRecord!(int, int) original;
    TypedRecord!(int, int) copied = original;
}));

// D does not permit a catch inside a finally block. Keep the
// fail-closed join policy in an independent private @system helper.
private void joinOrFailStop(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
    {
        // The unchanged M0 pool may throw before all native workers joined.
        // This must never unwind our caller-frame TaskRefs.
        abort();
    }
}

/++
 Real M0 SubmissionWorkerPool, bounded fixed-address typed records.

 This is *intentionally @system*: a successful native join makes this
 particular call's record lifetime well defined, but the underlying M0
 pool can throw before fully joining on worker/native failure. Do not
 wrap this in @trusted or export as @safe.

 Fail-closed research fallback: if closeAndJoin() throws after some
 records have been published, terminate the process rather than
 returning through a stack frame that might still be in use.
+/
PoolResults!R evaluateWithRealPool(P, R)(
    scope P[] input,
    R function(P) @safe pure nothrow @nogc fn,
    size_t workerCount = 2,
    size_t ingressCapacity = 4) @system
    if (isInlineTransfer!P && isInlineTransfer!R)
{
    if (input.length > RealPoolCapacity)
        throw new Exception("P11 too many values");
    if (fn is null)
        throw new Exception("P11 null operation");
    if (workerCount == 0 || ingressCapacity == 0)
        throw new Exception("P11 invalid pool shape");

    PoolResults!R results;
    results.count = input.length;
    if (input.length == 0)
        return results;

    // Initialize every record BEFORE any record address is published.
    TypedRecord!(P, R)[RealPoolCapacity] records;
    foreach (i, value; input)
        records[i].prepare(fn, value);

    // No record address has escaped before pool construction. M0's
    // partial-native-start uncertainty remains a *pool* safety issue.
    auto pool = new SubmissionWorkerPool(
        workerCount, ingressCapacity, &markReturned);

    try
    {
        foreach (i; 0 .. input.length)
        {
            for (;;)
            {
                const admitted = pool.trySubmit(records[i].reference());
                if (admitted == SubmissionResult.accepted)
                    break;
                if (admitted == SubmissionResult.closed)
                    throw new Exception("P11 pool unexpectedly closed");

                if (admitted != SubmissionResult.full)
                    throw new Exception("P11 unexpected admission result");
                ++results.backpressureRetries;
                Thread.yield();
            }
        }
    }
    finally
        joinOrFailStop(pool);

    results.accepted = pool.acceptedCount();
    results.completed = pool.completedCount();
    if (results.accepted != input.length ||
        results.completed != input.length)
        throw new Exception("P11 execution obligations mismatch");

    foreach (i; 0 .. input.length)
    {
        if (atomicLoad!(MemoryOrder.acq)(
                records[i].prefix.returned) != 1u)
            throw new Exception("P11 record not returned");
        ++results.returned;
        results.values[i] = records[i].output;
    }
    return results;
}
