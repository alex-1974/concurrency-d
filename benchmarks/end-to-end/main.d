// Matched, checksum-verified end-to-end CPU diagnostic; no timing threshold.
module concurrency.benchmarks.end_to_end;

import concurrency : Executor, TaskHandle, WorkSize;
import core.atomic : atomicFetchAdd, MemoryOrder;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.parallelism : TaskPool;
import std.range : iota;
import std.stdio : writeln;

private struct Workload
{
    string name;
    size_t chunks;
    uint iterations;
    bool irregular;
}

private enum reuseWaves = 8;

private struct Job
{
    size_t id;
    uint iterations;
    bool irregular;

    this(size_t id, uint iterations, bool irregular) @safe nothrow
    {
        this.id = id;
        this.iterations = iterations;
        this.irregular = irregular;
    }

    ulong opCall() const @safe nothrow
    {
        // Irregular mode varies chunk cost deterministically while preserving
        // identical per-chunk work across every scheduler arm.
        const count = irregular
            ? iterations + cast(uint)((id * 2654435761UL) % (iterations + 1UL))
            : iterations;
        ulong value = cast(ulong)id + 1;
        foreach (i; 0 .. count)
            value = value * 1664525UL + 1013904223UL + i;
        return value;
    }
}

private struct BatchJob
{
    Workload workload;
    size_t first;
    size_t last;

    this(Workload workload, size_t first, size_t last) @safe nothrow
    {
        this.workload = workload;
        this.first = first;
        this.last = last;
    }

    ulong opCall() const @safe nothrow
    {
        ulong checksum;
        foreach (id; first .. last)
            checksum += Job(id, workload.iterations, workload.irregular)();
        return checksum;
    }
}

private struct DynamicRangeWorker
{
    Workload workload;
    shared size_t* nextIndex;
    size_t grainSize;
    ulong* values;

    this(Workload workload, shared size_t* nextIndex, size_t grainSize,
        ulong* values)
    {
        this.workload = workload;
        this.nextIndex = nextIndex;
        this.grainSize = grainSize;
        this.values = values;
    }

    ulong opCall()
    {
        ulong checksum;
        while (true)
        {
            const first = atomicFetchAdd!(MemoryOrder.rel)(*nextIndex, grainSize);
            if (first >= workload.chunks)
                break;
            const remaining = workload.chunks - first;
            const last = first + (remaining < grainSize ? remaining : grainSize);
            foreach (id; first .. last)
            {
                const value = Job(id, workload.iterations, workload.irregular)();
                values[id] = value;
                checksum += value;
            }
        }
        return checksum;
    }
}

private ulong runSequential(Workload workload)
{
    ulong checksum;
    foreach (id; 0 .. workload.chunks)
        checksum += Job(id, workload.iterations, workload.irregular)();
    return checksum;
}

private ulong runPhobos(Workload workload, size_t workers, size_t batchSize)
{
    // A parallel foreach uses its calling thread while waiting. Give it
    // workers-1 native workers so its total execution budget matches the
    // executor's worker count, including the single-worker case.
    auto pool = new TaskPool(workers - 1);
    scope (exit) pool.finish(true);
    auto values = new ulong[workload.chunks];
    foreach (id; pool.parallel(iota(0, workload.chunks), batchSize))
        values[id] = Job(id, workload.iterations, workload.irregular)();
    ulong checksum;
    foreach (value; values)
        checksum += value;
    return checksum;
}

private ulong runConcurrency(Workload workload, size_t workers, size_t batchSize)
{
    auto executor = new Executor(workers, 256, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    const batchCount = (workload.chunks + batchSize - 1) / batchSize;
    auto handles = new TaskHandle!ulong[batchCount];
    foreach (batch; 0 .. batchCount)
    {
        const first = batch * batchSize;
        const last = first + batchSize < workload.chunks
            ? first + batchSize : workload.chunks;
        handles[batch] = executor.submit(BatchJob(workload, first, last));
    }
    ulong checksum;
    foreach (handle; handles)
        checksum += handle.get();
    executor.closeAndJoin();
    return checksum;
}

private ulong runParallelFor(Workload workload, size_t workers, size_t grainSize)
{
    auto executor = new Executor(workers, 256, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[workload.chunks];
    executor.parallelFor(workload.chunks, grainSize, (size_t id) {
        values[id] = Job(id, workload.iterations, workload.irregular)();
    });
    ulong checksum;
    foreach (value; values)
        checksum += value;
    executor.closeAndJoin();
    return checksum;
}

private ulong runPhobosReused(Workload workload, size_t workers, size_t batchSize)
{
    auto pool = new TaskPool(workers - 1);
    scope (exit) pool.finish(true);
    auto values = new ulong[workload.chunks];
    ulong checksum;
    foreach (_; 0 .. reuseWaves)
    {
        foreach (id; pool.parallel(iota(0, workload.chunks), batchSize))
            values[id] = Job(id, workload.iterations, workload.irregular)();
        foreach (value; values)
            checksum += value;
    }
    return checksum;
}

private ulong runParallelForReused(Workload workload, size_t workers,
    size_t grainSize)
{
    auto executor = new Executor(workers, 256, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[workload.chunks];
    ulong checksum;
    foreach (_; 0 .. reuseWaves)
    {
        executor.parallelFor(workload.chunks, grainSize, (size_t id) {
            values[id] = Job(id, workload.iterations, workload.irregular)();
        });
        foreach (value; values)
            checksum += value;
    }
    executor.closeAndJoin();
    return checksum;
}

private ulong runParallelForAdaptiveReused(Workload workload, size_t workers,
    size_t minGrainSize)
{
    auto executor = new Executor(workers, 256, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[workload.chunks];
    ulong checksum;
    foreach (_; 0 .. reuseWaves)
    {
        executor.parallelForAdaptive(workload.chunks, minGrainSize,
            (size_t id) {
                values[id] = Job(id, workload.iterations, workload.irregular)();
            });
        foreach (value; values)
            checksum += value;
    }
    executor.closeAndJoin();
    return checksum;
}

private ulong runDynamicForWave(Executor executor, Workload workload,
    size_t workers, size_t grainSize, ulong[] values)
{
    shared size_t nextIndex;
    const rangeCount = (workload.chunks + grainSize - 1) / grainSize;
    const workerCount = workers < rangeCount ? workers : rangeCount;
    auto handles = new TaskHandle!ulong[workerCount - 1];
    foreach (worker; 0 .. handles.length)
        handles[worker] = executor.submit(
            DynamicRangeWorker(workload, &nextIndex, grainSize, values.ptr), WorkSize.large);
    auto caller = DynamicRangeWorker(workload, &nextIndex, grainSize, values.ptr);
    caller();
    foreach (handle; handles) executor.waitForScopeTask(handle);
    executor.reclaimCompletedTasks();
    ulong checksum;
    foreach (value; values) checksum += value;
    return checksum;
}

private ulong runDynamicFor(Workload workload, size_t workers, size_t grainSize)
{
    auto executor = new Executor(workers, 256, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[workload.chunks];
    const checksum = runDynamicForWave(executor, workload, workers, grainSize,
        values);
    executor.closeAndJoin();
    return checksum;
}

private ulong runDynamicForReused(Workload workload, size_t workers,
    size_t grainSize)
{
    auto executor = new Executor(workers, 256, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[workload.chunks];
    ulong checksum;
    foreach (_; 0 .. reuseWaves)
        checksum += runDynamicForWave(executor, workload, workers, grainSize,
            values);
    executor.closeAndJoin();
    return checksum;
}

private long measure(string arm, Workload workload, size_t workers,
    size_t batchSize, out ulong checksum, out size_t measuredChunks)
{
    const started = MonoTime.currTime;
    measuredChunks = workload.chunks;
    if (arm == "sequential") checksum = runSequential(workload);
    else if (arm == "phobos") checksum = runPhobos(workload, workers, batchSize);
    else if (arm == "parallelFor") checksum = runParallelFor(workload, workers, batchSize);
    else if (arm == "phobosReused")
    {
        checksum = runPhobosReused(workload, workers, batchSize);
        measuredChunks *= reuseWaves;
    }
    else if (arm == "parallelForReused")
    {
        checksum = runParallelForReused(workload, workers, batchSize);
        measuredChunks *= reuseWaves;
    }
    else if (arm == "parallelForAdaptiveReused")
    {
        checksum = runParallelForAdaptiveReused(workload, workers, batchSize);
        measuredChunks *= reuseWaves;
    }
    else if (arm == "dynamicForReused")
    {
        checksum = runDynamicForReused(workload, workers, batchSize);
        measuredChunks *= reuseWaves;
    }
    else if (arm == "dynamicFor") checksum = runDynamicFor(workload, workers, batchSize);
    else checksum = runConcurrency(workload, workers, batchSize);
    return (MonoTime.currTime - started).total!"nsecs";
}

void main(string[] args)
{
    enforce(args.length == 5,
        "usage: end-to-end MAX_WORKERS SAMPLES WARMUPS BASE_ITERATIONS");
    const maxWorkers = to!size_t(args[1]);
    const samples = to!size_t(args[2]);
    const warmups = to!size_t(args[3]);
    const baseIterations = to!uint(args[4]);
    enforce(maxWorkers > 0 && maxWorkers <= 256, "max workers must be 1..256");
    enforce(samples > 0 && samples <= 1000 && warmups <= 1000,
        "samples must be 1..1000 and warmups 0..1000");
    enforce(baseIterations > 0 && baseIterations <= 1_000_000,
        "base iterations must be 1..1000000");

    immutable workloads = [
        Workload("fine", 1024, baseIterations, false),
        Workload("medium", 256, baseIterations * 8, false),
        Workload("coarse", 32, baseIterations * 64, false),
        Workload("irregular", 256, baseIterations * 4, true),
    ];
    immutable arms = ["sequential", "phobos", "concurrency", "parallelFor",
        "dynamicFor", "phobosReused", "parallelForReused", "dynamicForReused",
        "parallelForAdaptiveReused"];
    immutable batchSizes = [1UL, 4UL, 8UL, 16UL, 32UL, 64UL, 128UL, 256UL,
        512UL];
    size_t[] workerCounts;
    for (size_t count = 1; ; count = count > maxWorkers / 2 ? maxWorkers : count * 2)
    {
        workerCounts ~= count;
        if (count == maxWorkers)
            break;
    }
    writeln("phase,sample,order,workload,arm,workers,batch_size,submitted_tasks,chunks,min_iterations_per_chunk,elapsed_ns,ns_per_chunk,chunks_per_second,checksum");

    foreach (workloadIndex, workload; workloads)
    {
        const expected = runSequential(workload);
        foreach (workerIndex, workers; workerCounts)
        {
            foreach (batchIndex, batchSize; batchSizes)
            {
                foreach (sample; 0 .. warmups + samples)
                {
                    const offset = (sample + workloadIndex + workerIndex + batchIndex) % arms.length;
                    foreach (order; 0 .. arms.length)
                    {
                        const arm = arms[(offset + order) % arms.length];
                        if (arm == "sequential" && (workerIndex != 0 || batchIndex != 0))
                            continue;
                        ulong checksum;
                        size_t measuredChunks;
                        const elapsed = measure(arm, workload, workers,
                            batchSize, checksum, measuredChunks);
                        const waves = (arm == "phobosReused" || arm == "parallelForReused" ||
                            arm == "dynamicForReused" || arm == "parallelForAdaptiveReused")
                            ? reuseWaves : 1;
                        enforce(checksum == expected * waves && elapsed > 0,
                            workload.name ~ "/" ~ arm ~ " checksum/time mismatch");
                        const rangeCount = (workload.chunks + batchSize - 1) / batchSize;
                        const submitted = arm == "sequential" ? 0 :
                            (arm == "dynamicFor" || arm == "parallelFor")
                                ? (workers < rangeCount ? workers : rangeCount) - 1 :
                            arm == "parallelForReused" || arm == "dynamicForReused" ||
                            arm == "parallelForAdaptiveReused"
                                ? ((workers < rangeCount ? workers : rangeCount) - 1) * reuseWaves
                                : arm == "phobosReused" ? rangeCount * reuseWaves : rangeCount;
                        writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                            ",", order, ",", workload.name, ",", arm, ",", workers,
                            ",", batchSize, ",", submitted,
                            ",", measuredChunks, ",", workload.iterations, ",", elapsed,
                            ",", elapsed / measuredChunks, ",",
                            (cast(double)measuredChunks * 1_000_000_000.0) / elapsed,
                            ",", checksum);
                    }
                }
            }
        }
    }
}
