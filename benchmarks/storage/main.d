/**
 * Research benchmark for record placement/reuse with equivalent TaskRef work.
 * It does not benchmark the public generic OwnedTaskExecutor or TaskScope.
 */
module concurrency.benchmarks.storage;

import concurrency.internal.task_record : TaskHeader, TaskRef;
import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;
import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.stdc.stdlib : abort;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

enum size_t MaxRecords = 16_384;
enum size_t DefaultIngress = 64;

private struct Record
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

private Record* fromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    return cast(Record*) raw;
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = fromHeader(raw);
    record.result = kernel(record.input);
}

private void markReturned(TaskRef task) @trusted nothrow
{
    auto record = cast(shared(Record)*) task.ptr;
    atomicStore!(MemoryOrder.rel)(record.returned, 1u);
}

private void closeOrAbort(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
    {
        // A failed join cannot prove that a worker stopped using stack storage.
        abort();
    }
}

private long elapsed(long startTicks, long endTicks)
{
    enforce(endTicks >= startTicks, "monotonic clock moved backwards");
    return ticksToNSecs(endTicks - startTicks);
}

private struct Sample
{
    string mode;
    size_t count;
    size_t workers;
    size_t waves;
    size_t retries;
    long storageNs;
    long prepareNs;
    long startNs;
    long submitJoinNs;
    long verifyNs;
    long totalNs;
    long checksum;
}

private void prepare(Record[] records, size_t count) @system
{
    foreach (i; 0 .. count)
    {
        records[i].header.execute = &execute;
        atomicStore!(MemoryOrder.raw)(records[i].returned, 0u);
        records[i].input = cast(int)(i * 3) - 300;
        records[i].result = 0;
    }
}

private size_t submitWave(
    SubmissionWorkerPool pool,
    Record[] records,
    size_t count,
    ref size_t retries) @system
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
                throw new Exception("storage benchmark pool unexpectedly closed");
            if (admission != SubmissionResult.full)
                throw new Exception("storage benchmark admission failed");
            ++retries;
            Thread.yield();
        }
    }

    // This is the reuse fence: result readiness or an empty inbox is not enough.
    const deadline = MonoTime.currTime + dur!"seconds"(30);
    foreach (i; 0 .. count)
    {
        while (atomicLoad!(MemoryOrder.acq)(records[i].returned) == 0u)
        {
            enforce(MonoTime.currTime < deadline,
                "storage benchmark timed out waiting for post-dispatch return");
            Thread.yield();
        }
    }
    return pool.completedCount();
}

private long verifyWave(Record[] records, size_t count) @system
{
    long checksum;
    foreach (i; 0 .. count)
    {
        const input = cast(int)(i * 3) - 300;
        const result = kernel(input);
        enforce(records[i].input == input && records[i].result == result,
            "storage benchmark task result mismatch");
        checksum += records[i].result;
    }
    return checksum;
}

private Sample process(
    string mode,
    Record[] records,
    bool freshEachWave,
    long totalStart,
    long storageNs,
    size_t count,
    size_t workers,
    size_t waves) @system
{
    Sample sample;
    sample.mode = mode;
    sample.count = count;
    sample.workers = workers;
    sample.waves = waves;
    sample.storageNs = storageNs;

    auto pool = new SubmissionWorkerPool(workers, DefaultIngress, &markReturned);
    const poolStarted = MonoTime.currTime.ticks;
    sample.startNs = elapsed(totalStart, poolStarted) - storageNs;

    long expected;
    long preparedTotal;
    long submittedTotal;
    long verifiedTotal;
    long closeJoinNs;
    size_t cumulativeCompleted;
    try
    {
        foreach (_; 0 .. waves)
        {
            const prepareStart = MonoTime.currTime.ticks;
            if (freshEachWave)
                records = new Record[MaxRecords];
            prepare(records, count);
            const prepared = MonoTime.currTime.ticks;
            preparedTotal += elapsed(prepareStart, prepared);

            cumulativeCompleted = submitWave(pool, records, count, sample.retries);
            const submitted = MonoTime.currTime.ticks;
            submittedTotal += elapsed(prepared, submitted);

            const waveChecksum = verifyWave(records, count);
            sample.checksum += waveChecksum;
            expected += waveChecksum;
            const verified = MonoTime.currTime.ticks;
            verifiedTotal += elapsed(submitted, verified);
        }
    }
    finally
    {
        const closeStart = MonoTime.currTime.ticks;
        closeOrAbort(pool);
        closeJoinNs = elapsed(closeStart, MonoTime.currTime.ticks);
    }

    enforce(pool.acceptedCount() == count * waves &&
            pool.completedCount() == count * waves &&
            cumulativeCompleted == count * waves,
        "storage benchmark accepted/completed count mismatch");
    enforce(sample.checksum == expected, "storage benchmark checksum mismatch");

    sample.prepareNs = preparedTotal;
    sample.submitJoinNs = submittedTotal + closeJoinNs;
    sample.verifyNs = verifiedTotal;
    const end = MonoTime.currTime.ticks;
    sample.totalNs = elapsed(totalStart, end);
    return sample;
}

private Sample runStack(size_t count, size_t workers, size_t waves) @system
{
    const start = MonoTime.currTime.ticks;
    Record[MaxRecords] records;
    const storageReady = MonoTime.currTime.ticks;
    return process("stack_reuse", records[], false, start,
        elapsed(start, storageReady),
        count, workers, waves);
}

private Sample runGcFresh(size_t count, size_t workers, size_t waves) @system
{
    const start = MonoTime.currTime.ticks;
    return process("gc_fresh", null, true, start, 0,
        count, workers, waves);
}

private Sample runGcReuse(size_t count, size_t workers, size_t waves) @system
{
    const start = MonoTime.currTime.ticks;
    auto records = new Record[MaxRecords];
    const allocated = MonoTime.currTime.ticks;
    return process("gc_reuse", records, false, start,
        elapsed(start, allocated), count, workers, waves);
}

private void print(Sample sample, size_t pair, string phase)
{
    writeln(phase, ",", pair, ",", sample.mode, ",", sample.count, ",",
        sample.workers, ",", sample.waves, ",", sample.storageNs, ",",
        sample.prepareNs, ",",
        sample.startNs, ",", sample.submitJoinNs, ",", sample.verifyNs, ",",
        sample.totalNs, ",", sample.retries, ",", sample.checksum);
}

void main(string[] args)
{
    enforce(args.length == 5 || args.length == 6,
        "usage: task-storage-benchmark COUNT WORKERS WAVES ROUNDS [WARMUPS]");
    const count = to!size_t(args[1]);
    const workers = to!size_t(args[2]);
    const waves = to!size_t(args[3]);
    const rounds = to!size_t(args[4]);
    const warmups = args.length == 6 ? to!size_t(args[5]) : 2;
    enforce(count > 0 && count <= MaxRecords && workers > 0 &&
        waves > 0 && rounds > 0, "invalid benchmark dimensions");

    writeln("phase,pair,mode,count,workers,waves,storage_setup_ns,prepare_ns,pool_start_ns,",
        "submit_join_ns,verify_ns,total_ns,retries,checksum");
    foreach (pair; 0 .. warmups + rounds)
    {
        Sample[3] samples;
        // Balanced cyclic order reduces drift between storage modes.
        final switch (pair % 3)
        {
            case 0:
                samples = [runStack(count, workers, waves),
                    runGcFresh(count, workers, waves),
                    runGcReuse(count, workers, waves)];
                break;
            case 1:
                samples = [runGcFresh(count, workers, waves),
                    runGcReuse(count, workers, waves),
                    runStack(count, workers, waves)];
                break;
            case 2:
                samples = [runGcReuse(count, workers, waves),
                    runStack(count, workers, waves),
                    runGcFresh(count, workers, waves)];
                break;
        }
        const phase = pair < warmups ? "warmup" : "measure";
        const samplePair = pair < warmups ? pair : pair - warmups;
        foreach (sample; samples)
        {
            if (sample.checksum != samples[0].checksum)
                throw new Exception("storage modes produced unequal checksums");
            print(sample, samplePair, phase);
        }
    }
}
