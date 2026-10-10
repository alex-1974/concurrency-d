/**
 * Reproducible R0.4 P01 portable parking benchmark.
 *
 * This is an opt-in executable, not a public library module and not a
 * latency gate on shared CI hardware. Records are externally retained
 * through closeAndJoin. Monotonic clock timestamps measure publish->start.
 */
module concurrency.internal.parking_benchmark;

import concurrency.internal.submission_pool :
    SubmissionResult,
    SubmissionWorkerPool;
import concurrency.internal.task_record :
    TaskHeader,
    TaskRef;

import core.atomic :
    MemoryOrder,
    atomicLoad,
    atomicStore;

import core.stdc.time :
    clock,
    CLOCKS_PER_SEC;

import core.thread :
    Thread;

import core.time :
    MonoTime,
    dur,
    ticksToNSecs;

import std.algorithm.sorting :
    sort;

import std.conv :
    to;

import std.stdio :
    writefln;

private struct BenchRecord
{
    TaskHeader header;
    shared long publishedTicks;
    shared long startedTicks;
}

private void runRecord(shared(TaskHeader)* header)
    @trusted @nogc nothrow
{
    auto record = cast(shared(BenchRecord)*) header;

    atomicStore!(MemoryOrder.rel)(
        record.startedTicks,
        MonoTime.currTime.ticks);
}

private long awaitStarted(shared BenchRecord* record)
{
    // No sleeping in the measured publication->start interval.
    // A bounded deadline avoids hanging a measurement indefinitely.
    const deadline = MonoTime.currTime + dur!"seconds"(10);

    for (;;)
    {
        const started = atomicLoad!(MemoryOrder.acq)(
            record.startedTicks);

        if (started != 0)
            return started;

        if (MonoTime.currTime > deadline)
            throw new Exception("task failed to start within 10 seconds");

        Thread.yield();
    }
}

private void awaitInitialParking(SubmissionWorkerPool pool, size_t workers)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);

    while (pool.parkCount() < workers)
    {
        if (MonoTime.currTime > deadline)
            throw new Exception("workers did not park");

        Thread.yield();
    }
}

private long percentile(scope const(long)[] sortedValues, size_t percent)
{
    assert(sortedValues.length > 0);
    assert(percent <= 100);

    return sortedValues[
        (sortedValues.length - 1) * percent / 100];
}

private void measure(size_t workerCount, size_t sampleCount)
{
    auto records = new shared BenchRecord[sampleCount];
    auto latencyNs = new long[sampleCount];

    // Keep the queue deliberately small to exercise the normal admission
    // path rather than hide unbounded buffering in a benchmark.
    auto pool = new SubmissionWorkerPool(workerCount, 8);

    awaitInitialParking(pool, workerCount);

    // CPU time is summed over all process threads by C clock() on the
    // qualified Linux targets. Measure steady idle with no submissions.
    const beforeCpu = clock();
    const beforeIdle = MonoTime.currTime;

    Thread.sleep(dur!"msecs"(300));

    const afterIdle = MonoTime.currTime;
    const afterCpu = clock();

    const idleWallSecs =
        cast(double) ticksToNSecs(
            afterIdle.ticks - beforeIdle.ticks) / 1_000_000_000.0;
    const idleCpuSecs =
        cast(double) (afterCpu - beforeCpu) / CLOCKS_PER_SEC;

    // Each sample is deliberately separated by an idle interval. This is
    // not a saturation-throughput benchmark; it measures parked wakeups.
    foreach (i; 0 .. sampleCount)
    {
        records[i].header.execute = &runRecord;
        atomicStore!(MemoryOrder.raw)(
            records[i].startedTicks,
            cast(long) 0);

        Thread.sleep(dur!"msecs"(2));

        TaskRef task = TaskRef(&records[i].header);
        long published;

        for (;;)
        {
            published = MonoTime.currTime.ticks;

            atomicStore!(MemoryOrder.raw)(
                records[i].publishedTicks,
                published);

            const admission = pool.trySubmit(task);

            if (admission == SubmissionResult.accepted)
                break;

            if (admission == SubmissionResult.closed)
                throw new Exception("pool closed during benchmark");

            assert(admission == SubmissionResult.full);
            Thread.yield();
        }

        const started = awaitStarted(&records[i]);
        if (started < published)
            throw new Exception("negative publication-to-start interval");

        latencyNs[i] = ticksToNSecs(started - published);
    }

    pool.closeAndJoin();

    if (pool.acceptedCount() != sampleCount ||
        pool.completedCount() != sampleCount)
        throw new Exception("benchmark task accounting mismatch");

    latencyNs.sort();

    const double idleCpuCores =
        idleWallSecs > 0 ? idleCpuSecs / idleWallSecs : 0;

    writefln(
        "parking.p01 workers=%s samples=%s idle_wall_s=%.6f "
        ~ "idle_cpu_s=%.6f idle_cpu_cores=%.6f "
        ~ "p50_ns=%s p95_ns=%s p99_ns=%s max_ns=%s parks=%s",
        workerCount,
        sampleCount,
        idleWallSecs,
        idleCpuSecs,
        idleCpuCores,
        percentile(latencyNs, 50),
        percentile(latencyNs, 95),
        percentile(latencyNs, 99),
        latencyNs[$ - 1],
        pool.parkCount());
}

void main(string[] args)
{
    size_t workers = 2;
    size_t samples = 128;

    if (args.length > 1)
        workers = to!size_t(args[1]);

    if (args.length > 2)
        samples = to!size_t(args[2]);

    if (workers == 0 || samples == 0 || workers > 64 ||
        samples > 100_000)
        throw new Exception("worker/sample counts out of bounds");

    writefln(
        "P01 parked-worker baseline: clock=MonoTime, "
        ~ "sample delay=2ms, idle window=300ms");

    measure(workers, samples);
}
