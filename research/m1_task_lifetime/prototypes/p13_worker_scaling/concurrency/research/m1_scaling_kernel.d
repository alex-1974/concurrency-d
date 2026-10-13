/++
 P13 RESEARCH ONLY: wave-wise M0 worker scaling over real containers-d
 work-stealing deques. Same records, same kernel, same work per wave,
 persistent workers INSIDE each sample (no re-start between waves).

 Scope remains @system. All wave records are distinct and retained until
 closeAndJoin succeeds. A failed native join cannot safely unwind the
 caller's borrowed record storage; this prototype fail-stops instead.
 This is NOT a production API or an accepted general @safe TaskScope.
+/
module concurrency.research.m1_scaling_kernel;

import concurrency.internal.task_record : TaskHeader, TaskRef;
import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad, atomicStore;
import core.stdc.stdlib : abort;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;

enum size_t MaxTasksPerWave = 4096;
enum size_t MaxWaves = 4;

private struct Record
{
    @disable this(this);
    TaskHeader header;
    shared uint returned;
    shared(uint)* waveCompleted;
    uint input;
    uint output;
    size_t iterations;

    static assert(header.offsetof == 0);
}

private uint sourceValue(size_t index) @safe pure nothrow @nogc
{
    return cast(uint)(index * 747796405u + 2891336453u);
}

private uint calculate(uint input, size_t iterations)
    @safe pure nothrow @nogc
{
    uint value = input;
    foreach (index; 0 .. iterations)
    {
        value = value * 1664525u + 1013904223u;
        value ^= value >> 13;
    }
    return value;
}

private Record* fromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    return cast(Record*) raw;
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = fromHeader(raw);
    record.output = calculate(record.input, record.iterations);
}

private void markReturned(TaskRef reference) @trusted nothrow
{
    auto record = cast(shared(Record)*) reference.ptr;
    // This release flag and the counter are written only after the real
    // SubmissionWorkerPool dispatch + completion accounting path.
    atomicStore!(MemoryOrder.rel)(record.returned, 1u);
    atomicFetchAdd!(MemoryOrder.rel)(*record.waveCompleted, 1u);
}

private long elapsed(long start, long finish)
{
    if (finish < start)
        throw new Exception("P13 monotonic clock moved backwards");
    return ticksToNSecs(finish - start);
}

private void closeOrAbort(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
    {
        // Real M0 currently uses throwing joins and cannot prove all
        // workers quiescent on failed native join/worker exceptional exit.
        abort();
    }
}

/++
 A pool stays alive through "waves" of bounded work. Each wave's
 completely distinct record addresses remain fixed until the final join.
 The counter only signals that afterExecution ran; it is NOT considered
 sufficient to reclaim records before native workers have joined.
+/
struct ScalingSample
{
    size_t workers;
    size_t tasksPerWave;
    size_t waves;
    size_t iterations;
    size_t ingress;
    size_t retries;
    size_t parkCount;
    ulong checksum;
    long prepareNs;
    long poolStartNs;
    long wavesNs;
    long joinNs;
    long verifyNs;
    long totalNs;
}

ScalingSample measure(
    size_t workers, size_t tasksPerWave, size_t waves,
    size_t iterations, size_t ingress) @system
{
    if (workers < 1 || workers > 16 ||
        tasksPerWave < 1 || tasksPerWave > MaxTasksPerWave ||
        waves < 1 || waves > MaxWaves ||
        iterations > 2048 ||
        ingress < 1 || ingress > 4096)
        throw new Exception("P13 invalid research workload");

    ScalingSample sample;
    sample.workers = workers;
    sample.tasksPerWave = tasksPerWave;
    sample.waves = waves;
    sample.iterations = iterations;
    sample.ingress = ingress;
    const all = tasksPerWave * waves;

    const begun = MonoTime.currTime.ticks;
    auto records = new Record[all];
    shared uint[MaxWaves] waveReturned;

    foreach (wave; 0 .. waves)
    {
        atomicStore!(MemoryOrder.raw)(waveReturned[wave], 0u);
        foreach (j; 0 .. tasksPerWave)
        {
            const index = wave * tasksPerWave + j;
            records[index].header.execute = &execute;
            records[index].waveCompleted = &waveReturned[wave];
            atomicStore!(MemoryOrder.raw)(records[index].returned, 0u);
            records[index].input = sourceValue(index);
            records[index].output = 0u;
            records[index].iterations = iterations;
        }
    }
    const prepared = MonoTime.currTime.ticks;
    sample.prepareNs = elapsed(begun, prepared);

    auto pool = new SubmissionWorkerPool(workers, ingress, &markReturned);
    const started = MonoTime.currTime.ticks;
    sample.poolStartNs = elapsed(prepared, started);

    long wavesFinished = started;
    try
    {
        foreach (wave; 0 .. waves)
        {
            const deadline = MonoTime.currTime + dur!"seconds"(20);
            foreach (j; 0 .. tasksPerWave)
            {
                const index = wave * tasksPerWave + j;
                for (;;)
                {
                    auto outcome = pool.trySubmit(
                        TaskRef(cast(shared(TaskHeader)*) &records[index].header));
                    if (outcome == SubmissionResult.accepted)
                        break;
                    if (outcome != SubmissionResult.full)
                        throw new Exception("P13 unexpected pool close");
                    ++sample.retries;
                    Thread.yield();
                }
            }

            // Wait until the last post-dispatch hook for this wave.
            // No record is reused or freed here; all stay rooted until
            // native pool join, even while later waves execute.
            while (atomicLoad!(MemoryOrder.acq)(waveReturned[wave]) <
                   tasksPerWave)
            {
                if (MonoTime.currTime > deadline)
                    throw new Exception("P13 completion wave timeout");
                Thread.yield();
            }
        }
        wavesFinished = MonoTime.currTime.ticks;
    }
    finally
        closeOrAbort(pool);

    const joined = MonoTime.currTime.ticks;
    sample.wavesNs = elapsed(started, wavesFinished);
    sample.joinNs = elapsed(wavesFinished, joined);
    if (pool.acceptedCount() != all || pool.completedCount() != all)
        throw new Exception("P13 real pool lost accepted work");
    sample.parkCount = pool.parkCount();

    ulong expected;
    foreach (i; 0 .. all)
    {
        if (atomicLoad!(MemoryOrder.acq)(records[i].returned) != 1u)
            throw new Exception("P13 missing post-dispatch flag");
        const input = sourceValue(i);
        const oracle = calculate(input, iterations);
        if (records[i].input != input || records[i].output != oracle)
            throw new Exception("P13 worker answer mismatch");
        expected += oracle;
        sample.checksum += records[i].output;
    }
    if (sample.checksum != expected)
        throw new Exception("P13 checksum mismatch");
    const verified = MonoTime.currTime.ticks;
    sample.verifyNs = elapsed(joined, verified);
    sample.totalNs = elapsed(begun, verified);
    return sample;
}
