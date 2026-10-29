module concurrency.benchmarks.batch_tuning;

import concurrency : Executor;
import core.thread : Thread;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private struct WorkRange
{
    ulong[] values;
    bool[] hotFlags;
    size_t first;
    size_t last;
    size_t iterations;
    size_t hotItems;
    size_t extraIterations;
    bool scattered;

    this(ulong[] values, bool[] hotFlags, size_t first, size_t last,
        size_t iterations, size_t hotItems, size_t extraIterations,
        bool scattered) nothrow
    {
        this.values = values;
        this.hotFlags = hotFlags;
        this.first = first;
        this.last = last;
        this.iterations = iterations;
        this.hotItems = hotItems;
        this.extraIterations = extraIterations;
        this.scattered = scattered;
    }

    void opCall() nothrow
    {
        foreach (index; first .. last)
        {
            auto value = cast(ulong) index + 1;
            const count = iterations +
                (hotFlags[index] ? extraIterations : 0);
            foreach (iteration; 0 .. count)
                value = value * 6364136223846793005UL +
                    cast(ulong) iteration + 1442695040888963407UL;
            values[index] = value;
        }
    }
}

private long elapsedNs(MonoTime start) nothrow
{
    return (MonoTime.currTime - start).total!"nsecs";
}

private ulong checksum(ulong[] values) nothrow
{
    ulong result;
    foreach (value; values)
        result += value;
    return result;
}

private ulong expectedChecksum(size_t items, size_t iterations,
    bool[] hotFlags, size_t extraIterations) nothrow
{
    ulong result;
    foreach (index; 0 .. items)
    {
        auto value = cast(ulong) index + 1;
        const count = iterations +
            (hotFlags[index] ? extraIterations : 0);
        foreach (iteration; 0 .. count)
            value = value * 6364136223846793005UL +
                cast(ulong) iteration + 1442695040888963407UL;
        result += value;
    }
    return result;
}

private void submitAndWait(Executor executor, WorkRange[] jobs)
{
    executor.submitBatchAndWait(jobs[]);
}

private Thread makeProducer(Executor executor, WorkRange[] jobs)
{
    return new Thread({ submitAndWait(executor, jobs); });
}

void main(string[] args)
{
    enforce(args.length == 12,
        "usage: batch-tuning SAMPLES WARMUPS ITEMS WORKERS PRODUCERS " ~
        "INGRESS RETAINED ITERATIONS HOT_ITEMS EXTRA_ITERATIONS LAYOUT");
    const samples = to!size_t(args[1]);
    const warmups = to!size_t(args[2]);
    const items = to!size_t(args[3]);
    const workers = to!size_t(args[4]);
    const producers = to!size_t(args[5]);
    const ingress = to!size_t(args[6]);
    const retained = to!size_t(args[7]);
    const iterations = to!size_t(args[8]);
    const hotItems = to!size_t(args[9]);
    const extraIterations = to!size_t(args[10]);
    const scattered = args[11] == "scattered";
    enforce(samples > 0 && samples <= 10000 && warmups <= 10000 &&
        items > 0 && items <= 1_000_000 && workers > 0 && workers <= 256 &&
        producers > 0 && producers <= 256 && producers <= items &&
        ingress > 0 && retained > 0 && iterations <= 100_000 &&
        hotItems > 0 && hotItems <= items && items % hotItems == 0 &&
        extraIterations <= 100_000 &&
        (args[11] == "clustered" || args[11] == "scattered"),
        "invalid benchmark dimensions");

    immutable grains = [1UL, 4UL, 16UL, 64UL, 256UL];
    auto executor = new Executor(workers, ingress, retained);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[items];
    auto hotFlags = new bool[items];
    const stride = items / hotItems;
    foreach (hot; 0 .. hotItems)
        hotFlags[scattered ? hot * stride : hot] = true;
    const expected = expectedChecksum(items, iterations, hotFlags,
        extraIterations);
    WorkRange[][] jobSets;
    size_t[] acceptedGrains;
    foreach (grain; grains)
    {
        const taskCount = items / grain + (items % grain != 0 ? 1 : 0);
        const largestProducerBatch = (taskCount + producers - 1) / producers;
        if (largestProducerBatch > ingress ||
            largestProducerBatch > retained)
            continue;
        auto jobs = new WorkRange[taskCount];
        foreach (task; 0 .. taskCount)
        {
            const first = task * grain;
            const last = first + (items - first < grain
                ? items - first : grain);
            jobs[task] = WorkRange(values, hotFlags, first, last, iterations,
                hotItems, extraIterations, scattered);
        }
        jobSets ~= jobs;
        acceptedGrains ~= grain;
    }
    enforce(jobSets.length > 0, "no grain fits the configured capacities");

    writeln("phase,sample,order,grain,iterations,workers,producers,items," ~
        "ingress,retained,tasks,hot_items,extra_iterations,layout,total_ns," ~
        "checksum");
    foreach (sample; 0 .. warmups + samples)
    {
        foreach (order; 0 .. acceptedGrains.length)
        {
            const grainIndex = (sample + order) % acceptedGrains.length;
            auto jobs = jobSets[grainIndex];
            values[] = 0;
            const started = MonoTime.currTime;
            if (producers == 1)
                submitAndWait(executor, jobs);
            else
            {
                Thread[] threads;
                foreach (producer; 0 .. producers)
                {
                    const first = jobs.length * producer / producers;
                    const last = jobs.length * (producer + 1) / producers;
                    threads ~= makeProducer(executor, jobs[first .. last]);
                }
                foreach (thread; threads) thread.start();
                foreach (thread; threads) thread.join();
            }
            const totalNs = elapsedNs(started);
            const actual = checksum(values);
            enforce(totalNs > 0 && actual == expected,
                "checksum or timing mismatch");
            writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                ",", order, ",", acceptedGrains[grainIndex], ",", iterations,
                ",", workers, ",", producers, ",", items, ",", ingress,
                ",", retained, ",", jobs.length, ",", hotItems, ",",
                extraIterations, ",", args[11], ",", totalNs, ",", actual);
        }
    }
}
