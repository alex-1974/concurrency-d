// Bounded sustained producer/consumer comparison; diagnostic, no timing gate.
module concurrency.benchmarks.streaming;

import concurrency : Executor, WorkSize, TaskHandle;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, ticksToNSecs;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.parallelism : TaskPool, task;
import std.stdio : writeln;

private struct Work
{
    size_t id;
    uint iterations;

    this(size_t id, uint iterations) @safe nothrow
    {
        this.id = id;
        this.iterations = iterations;
    }

    ulong opCall() const @safe nothrow
    {
        ulong value = cast(ulong) id + 1;
        foreach (i; 0 .. iterations)
            value = value * 1664525UL + 1013904223UL + i;
        return value;
    }
}

private struct BatchWork
{
    size_t first;
    size_t count;
    uint iterations;

    this(size_t first, size_t count, uint iterations) @safe nothrow
    {
        this.first = first;
        this.count = count;
        this.iterations = iterations;
    }

    ulong opCall() const @safe nothrow
    {
        ulong result;
        foreach (id; first .. first + count)
            result += Work(id, iterations)();
        return result;
    }
}

/** Tracks how many tasks from one producer have entered a pool worker. */
private final class ProducerStartSignal
{
    private Mutex _mutex;
    private Condition _changed;
    private bool[] _started;

    this(size_t taskCount)
    {
        _mutex = new Mutex();
        _changed = new Condition(_mutex);
        _started = new bool[taskCount];
    }

    void notifyStarted(size_t taskIndex)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        _started[taskIndex] = true;
        _changed.notifyAll();
    }

    void waitUntilStarted(size_t taskIndex)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        while (!_started[taskIndex])
            _changed.wait();
    }
}

private ulong runPhobosWork(size_t first, size_t count, uint iterations,
    ProducerStartSignal startSignal, size_t producerTaskIndex)
{
    // TaskPool marks a task in progress before entering this function. Once
    // the producer observes this signal, yieldForce can no longer remove and
    // execute that task itself; it only waits for the assigned pool worker.
    if (startSignal !is null)
        startSignal.notifyStarted(producerTaskIndex);
    return BatchWork(first, count, iterations)();
}

private alias PhobosTask = typeof(task!runPhobosWork(cast(size_t) 0,
    cast(size_t) 1, 1U, cast(ProducerStartSignal) null, cast(size_t) 0));

private struct ProducerStats
{
    ulong checksum;
    long producerWaitNs;
}

private long nowTicks() @safe nothrow
{
    return MonoTime.currTime.ticks;
}

private Thread makeExecutorProducer(Executor executor,
    long[][] submittedAt, long[][] submitNs, long[][] latencyNs,
    ProducerStats[] stats,
    size_t producer, size_t firstId, size_t taskCount, size_t window,
    size_t batchSize, uint iterations, WorkSize workSize)
{
    return new Thread({
        auto ring = new TaskHandle!ulong[window];
        auto ringIds = new size_t[window];
        size_t pending;
        size_t oldest;

        foreach (local; 0 .. taskCount)
        {
            if (pending == window)
            {
                const beforeWait = nowTicks();
                stats[producer].checksum += ring[oldest].get();
                stats[producer].producerWaitNs +=
                    ticksToNSecs(nowTicks() - beforeWait);
                latencyNs[producer][ringIds[oldest]] =
                    ticksToNSecs(nowTicks() - submittedAt[producer][ringIds[oldest]]);
                oldest = (oldest + 1) % window;
                --pending;
            }

            const slot = (oldest + pending) % window;
            auto id = firstId + local * batchSize;
            const beforeSubmit = nowTicks();
            ring[slot] = executor.submit(
                BatchWork(id, batchSize, iterations), workSize);
            submitNs[producer][local] = ticksToNSecs(nowTicks() - beforeSubmit);
            submittedAt[producer][local] = nowTicks();
            ringIds[slot] = local;
            ++pending;
        }

        while (pending != 0)
        {
            const beforeWait = nowTicks();
            stats[producer].checksum += ring[oldest].get();
            stats[producer].producerWaitNs +=
                ticksToNSecs(nowTicks() - beforeWait);
            latencyNs[producer][ringIds[oldest]] =
                ticksToNSecs(nowTicks() - submittedAt[producer][ringIds[oldest]]);
            oldest = (oldest + 1) % window;
            --pending;
        }
    });
}

private Thread makePhobosProducer(TaskPool pool, long[][] submittedAt,
    long[][] submitNs, long[][] latencyNs,
    ProducerStats[] stats, size_t producer, size_t firstId,
    size_t taskCount, size_t window, size_t batchSize, uint iterations)
{
    return new Thread({
        auto ring = new PhobosTask[window];
        auto ringIds = new size_t[window];
        auto startSignal = new ProducerStartSignal(taskCount);
        size_t pending;
        size_t oldest;

        foreach (local; 0 .. taskCount)
        {
            if (pending == window)
            {
                const beforeWait = nowTicks();
                startSignal.waitUntilStarted(ringIds[oldest]);
                stats[producer].checksum += ring[oldest].yieldForce;
                stats[producer].producerWaitNs +=
                    ticksToNSecs(nowTicks() - beforeWait);
                latencyNs[producer][ringIds[oldest]] =
                    ticksToNSecs(nowTicks() - submittedAt[producer][ringIds[oldest]]);
                oldest = (oldest + 1) % window;
                --pending;
            }

            const slot = (oldest + pending) % window;
            auto id = firstId + local * batchSize;
            const beforeSubmit = nowTicks();
            auto next = task!runPhobosWork(id, batchSize, iterations,
                startSignal, local);
            pool.put(next);
            ring[slot] = next;
            submitNs[producer][local] = ticksToNSecs(nowTicks() - beforeSubmit);
            submittedAt[producer][local] = nowTicks();
            ringIds[slot] = local;
            ++pending;
        }

        while (pending != 0)
        {
            const beforeWait = nowTicks();
            startSignal.waitUntilStarted(ringIds[oldest]);
            stats[producer].checksum += ring[oldest].yieldForce;
            stats[producer].producerWaitNs +=
                ticksToNSecs(nowTicks() - beforeWait);
            latencyNs[producer][ringIds[oldest]] =
                ticksToNSecs(nowTicks() - submittedAt[producer][ringIds[oldest]]);
            oldest = (oldest + 1) % window;
            --pending;
        }
    });
}

private long percentile(long[] values, size_t percent)
{
    values.sort();
    return values[(values.length - 1) * percent / 100];
}

private long[][] makeLongRows(size_t producers, size_t tasksPerProducer)
{
    auto rows = new long[][](producers);
    foreach (ref row; rows)
        row = new long[tasksPerProducer];
    return rows;
}

private long measureShutdownDrain(string arm, size_t workers,
    size_t capacity, size_t batchSize, uint iterations)
{
    auto drainIterations = iterations * 64;
    ulong expected;
    ulong observed;
    long drainNs;

    if (arm == "concurrency")
    {
        auto executor = new Executor(workers, capacity, capacity);
        auto handles = new TaskHandle!ulong[capacity];
        foreach (id; 0 .. capacity)
            handles[id] = executor.submit(
                BatchWork(id * batchSize, batchSize, drainIterations));
        const start = nowTicks();
        executor.closeAndJoin();
        drainNs = ticksToNSecs(nowTicks() - start);
        foreach (id, handle; handles)
        {
            observed += handle.get();
            expected += BatchWork(id * batchSize, batchSize,
                drainIterations)();
        }
    }
    else
    {
        auto pool = new TaskPool(workers);
        auto tasks = new PhobosTask[capacity];
        foreach (id; 0 .. capacity)
        {
            auto itemId = id;
            tasks[id] = task!runPhobosWork(itemId * batchSize,
                batchSize, drainIterations, cast(ProducerStartSignal) null, id);
            pool.put(tasks[id]);
        }
        const start = nowTicks();
        pool.finish(true);
        drainNs = ticksToNSecs(nowTicks() - start);
        foreach (id, item; tasks)
        {
            observed += item.yieldForce;
            expected += BatchWork(id * batchSize, batchSize,
                drainIterations)();
        }
    }

    enforce(observed == expected, arm ~ " shutdown-drain checksum mismatch");
    return drainNs;
}

private void run(string arm, size_t workers, size_t producers,
    size_t capacity, size_t totalTasks, uint iterations, size_t batchSize,
    WorkSize workSize, size_t sample, size_t warmup)
{
    const logicalTasksPerProducer = totalTasks / producers;
    const tasksPerProducer = logicalTasksPerProducer / batchSize;
    const window = capacity / producers;
    auto submittedAt = makeLongRows(producers, tasksPerProducer);
    auto submitNs = makeLongRows(producers, tasksPerProducer);
    auto latencyNs = makeLongRows(producers, tasksPerProducer);
    auto stats = new ProducerStats[producers];
    Thread[] threads;

    const totalStart = nowTicks();
    Executor executor;
    TaskPool pool;
    if (arm == "concurrency")
        executor = new Executor(workers, capacity, 4096);
    else
        pool = new TaskPool(workers);
    const producerStart = nowTicks();

    foreach (producer; 0 .. producers)
    {
        const firstId = producer * logicalTasksPerProducer;
        if (arm == "concurrency")
            threads ~= makeExecutorProducer(executor, submittedAt,
                submitNs, latencyNs, stats, producer, firstId,
                tasksPerProducer, window, batchSize, iterations, workSize);
        else
            threads ~= makePhobosProducer(pool, submittedAt,
                submitNs, latencyNs, stats, producer, firstId,
                tasksPerProducer, window, batchSize, iterations);
    }
    foreach (thread; threads) thread.start();
    foreach (thread; threads) thread.join();
    const producersDone = nowTicks();

    if (arm == "concurrency")
        executor.closeAndJoin();
    else
        pool.finish(true);
    const stopped = nowTicks();
    const shutdownDrainNs = measureShutdownDrain(arm, workers,
        capacity, batchSize, iterations);

    ulong checksum;
    long totalProducerWaitNs;
    foreach (stat; stats)
    {
        checksum += stat.checksum;
        totalProducerWaitNs += stat.producerWaitNs;
    }
    ulong expected;
    foreach (id; 0 .. totalTasks)
        expected += Work(id, iterations)();
    enforce(checksum == expected, arm ~ " checksum mismatch");

    const submittedTasks = totalTasks / batchSize;
    auto allSubmitNs = new long[submittedTasks];
    auto allLatencyNs = new long[submittedTasks];
    foreach (producer; 0 .. producers)
    {
        allSubmitNs[producer * tasksPerProducer .. (producer + 1) * tasksPerProducer] = submitNs[producer][];
        allLatencyNs[producer * tasksPerProducer .. (producer + 1) * tasksPerProducer] = latencyNs[producer][];
    }

    const hintName = workSize == WorkSize.large ? "large" : "small";
    writeln(warmup ? "warmup" : "measure", ",", sample, ",", arm, ",",
        workers, ",", producers, ",", capacity, ",", totalTasks, ",",
        totalTasks / batchSize, ",", batchSize, ",", hintName, ",", iterations,
        ",", ticksToNSecs(producersDone - producerStart),
        ",", ticksToNSecs(stopped - producersDone),
        ",", shutdownDrainNs,
        ",", ticksToNSecs(stopped - totalStart),
        ",", totalProducerWaitNs,
        ",", percentile(allSubmitNs, 50), ",", percentile(allSubmitNs, 95),
        ",", percentile(allSubmitNs, 99),
        ",", percentile(allLatencyNs, 50), ",", percentile(allLatencyNs, 95),
        ",", percentile(allLatencyNs, 99), ",", checksum);
}

void main(string[] args)
{
    enforce(args.length == 9 || args.length == 10,
        "usage: streaming-benchmark WORKERS PRODUCERS CAPACITY TASKS ITERATIONS BATCH_SIZE SAMPLES WARMUPS [small|large]");
    const workers = to!size_t(args[1]);
    const producers = to!size_t(args[2]);
    const capacity = to!size_t(args[3]);
    const totalTasks = to!size_t(args[4]);
    const iterations = to!uint(args[5]);
    const batchSize = to!size_t(args[6]);
    const samples = to!size_t(args[7]);
    const warmups = to!size_t(args[8]);
    WorkSize workSize = WorkSize.small;
    bool compareHints;
    if (args.length == 10)
    {
        enforce(args[9] == "small" || args[9] == "large" ||
            args[9] == "compare",
            "work size must be small, large, or compare");
        if (args[9] == "large") workSize = WorkSize.large;
        compareHints = args[9] == "compare";
    }
    enforce(workers > 0 && producers > 0 && producers <= workers * 8,
        "workers/producers out of range");
    enforce(capacity >= producers && capacity % producers == 0,
        "capacity must be positive and divisible by producers");
    enforce(batchSize > 0 && totalTasks >= producers * batchSize &&
        totalTasks % (producers * batchSize) == 0,
        "tasks must divide evenly among producers and batches");
    enforce(iterations > 0 && iterations <= 1_000_000 / 64 &&
        samples > 0 && samples <= 1000 && warmups <= 1000,
        "iterations/samples/warmups out of range");

    writeln("phase,sample,arm,workers,producers,in_flight_capacity,tasks,submitted_tasks,batch_size,work_size,iterations,producer_wall_ns,shutdown_ns,shutdown_drain_ns,total_ns,producer_wait_ns,submit_p50_ns,submit_p95_ns,submit_p99_ns,task_latency_p50_ns,task_latency_p95_ns,task_latency_p99_ns,checksum");
    foreach (sample; 0 .. warmups + samples)
    {
        WorkSize[2] hints;
        const hintCount = compareHints ? 2 : 1;
        if (compareHints)
        {
            hints[0] = sample % 2 == 0
                ? WorkSize.small : WorkSize.large;
            hints[1] = sample % 2 == 0
                ? WorkSize.large : WorkSize.small;
        }
        else
            hints[0] = workSize;

        foreach (hintIndex; 0 .. hintCount)
        {
            const hint = hints[hintIndex];
            const first = (sample % 2) == 0 ? "phobos" : "concurrency";
            const second = first == "phobos" ? "concurrency" : "phobos";
            run(first, workers, producers, capacity, totalTasks, iterations,
                batchSize, hint, sample, sample < warmups);
            run(second, workers, producers, capacity, totalTasks, iterations,
                batchSize, hint, sample, sample < warmups);
        }
    }
}
