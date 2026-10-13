/++
 P12 RESEARCH BENCHMARK — two storage modes, IDENTICAL M0 dispatch
 semantics and workload. Both use the real SubmissionWorkerPool and
 containers-d 0.2.0 work-stealing queues, synchronous join, same thunk,
 same one-word TaskRef, same function pointer, same result collection.
 Only record storage changes: stack-fixed array vs GC-fixed array.

 Not the production OwnedTaskExecutor: it offers different async
 TaskHandle/ResultCell semantics and is *not* a matched performance arm.

 IMPORTANT: native join failure may leave borrowed stack records in use.
 The research harness aborts rather than unwinds that state. Not a
 production safety policy. All benchmark timings on shared GitHub CI
 are diagnostic noise, never a performance acceptance verdict.
+/
module concurrency.research.m1_matched_pool_benchmark;

import concurrency.internal.task_record : TaskHeader, TaskRef;
import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;
import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.stdc.stdlib : abort;
import core.thread : Thread;
import core.time : MonoTime, ticksToNSecs;

enum size_t MaxTasks = 16384;

private struct BenchRecord
{
    @disable this(this);
    TaskHeader header;
    shared uint returned;
    int input;
    int result;

    static assert(header.offsetof == 0);
}

private int kernel(int input) @safe pure nothrow @nogc
{
    int value = input;
    foreach (i; 0 .. 32)
        value = (value * 17 + i) ^ (value >>> 3);
    return value;
}

private BenchRecord* fromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    return cast(BenchRecord*) raw;
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = fromHeader(raw);
    record.result = kernel(record.input);
}

private void markReturned(TaskRef task) @trusted nothrow
{
    auto record = cast(shared(BenchRecord)*) task.ptr;
    atomicStore!(MemoryOrder.rel)(record.returned, 1u);
}

private void closeOrAbort(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
    {
        // Default pool join might stop before joining all workers.
        // No caller-frame record may die while it could be accessed.
        abort();
    }
}

private long elapsed(long startTicks, long endTicks)
{
    assert(endTicks >= startTicks);
    return ticksToNSecs(endTicks - startTicks);
}

struct Sample
{
    size_t count;
    size_t retries;
    long checksum;
    long storageAndPrepareNs;
    long workerStartNs;
    long submitAndJoinNs;
    long verifyNs;
    long totalNs;
}

/++
 Exact same record type, function/kernel, pool initialization, ingress,
 dispatch, afterExecution and joined result proof in both storage modes.
 The sample measures (a) allocation/storage preparation, (b) worker
 startup, (c) publication overlapped with execution + close/join,
 (d) checksum verification, and total. Stage (c) is NOT pure dispatch.
+/
private Sample processRecords(
    BenchRecord[] records,
    size_t count,
    size_t workers,
    size_t ingress,
    long begunTicks,
    long preparedTicks) @system
{
    Sample sample;
    sample.count = count;
    sample.storageAndPrepareNs = elapsed(begunTicks, preparedTicks);

    auto pool = new SubmissionWorkerPool(workers, ingress, &markReturned);
    const startedTicks = MonoTime.currTime.ticks;
    sample.workerStartNs = elapsed(preparedTicks, startedTicks);

    try
    {
        foreach (i; 0 .. count)
        {
            for (;;)
            {
                const admission = pool.trySubmit(
                    TaskRef(cast(shared(TaskHeader)*) &records[i].header));
                if (admission == SubmissionResult.accepted)
                    break;
                if (admission == SubmissionResult.closed)
                    throw new Exception("P12 unexpected closed pool");
                if (admission != SubmissionResult.full)
                    throw new Exception("P12 unexpected admission state");
                ++sample.retries;
                Thread.yield();
            }
        }
    }
    finally
        closeOrAbort(pool);

    const joinedTicks = MonoTime.currTime.ticks;
    sample.submitAndJoinNs = elapsed(startedTicks, joinedTicks);
    if (pool.acceptedCount() != count ||
        pool.completedCount() != count)
        throw new Exception("P12 missing accepted/completed task");

    long expected;
    foreach (i; 0 .. count)
    {
        if (atomicLoad!(MemoryOrder.acq)(records[i].returned) != 1u)
            throw new Exception("P12 missing afterExecution return flag");
        const original = cast(int)(i * 3) - 300;
        if (records[i].input != original)
            throw new Exception("P12 corrupted task input");
        const oracle = kernel(original);
        if (records[i].result != oracle)
            throw new Exception("P12 wrong worker result");
        expected += oracle;
        sample.checksum += records[i].result;
    }
    if (sample.checksum != expected)
        throw new Exception("P12 checksum mismatch");
    const verifiedTicks = MonoTime.currTime.ticks;
    sample.verifyNs = elapsed(joinedTicks, verifiedTicks);
    sample.totalNs = elapsed(begunTicks, verifiedTicks);
    return sample;
}

private void prepare(BenchRecord[] records, size_t count) @system
{
    foreach (i; 0 .. count)
    {
        records[i].header.execute = &execute;
        atomicStore!(MemoryOrder.raw)(records[i].returned, 0u);
        records[i].input = cast(int)(i * 3) - 300;
        records[i].result = 0;
    }
}

/++ Records are locally stack-pinned for entire successful pool lifetime. +/
Sample measureStack(size_t count, size_t workers, size_t ingress) @system
{
    assert(count > 0 && count <= MaxTasks);
    const startTicks = MonoTime.currTime.ticks;
    BenchRecord[MaxTasks] records;
    prepare(records[], count);
    const prepared = MonoTime.currTime.ticks;
    return processRecords(records[], count, workers, ingress,
        startTicks, prepared);
}

/++ GC array is strongly reachable throughout *the same* synchronous join. +/
Sample measureHeap(size_t count, size_t workers, size_t ingress) @system
{
    assert(count > 0 && count <= MaxTasks);
    const startTicks = MonoTime.currTime.ticks;
    auto records = new BenchRecord[MaxTasks];
    prepare(records[], count);
    const prepared = MonoTime.currTime.ticks;
    return processRecords(records[], count, workers, ingress,
        startTicks, prepared);
}
