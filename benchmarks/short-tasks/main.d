module concurrency.benchmarks.short_tasks;

import concurrency : Executor, TaskHandle;
import core.thread : Thread;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.string : startsWith;
import std.stdio : writeln;

private struct StoreRange
{
    ulong[] values;
    size_t first;
    size_t last;

    this(ulong[] values, size_t first, size_t last) nothrow
    {
        this.values = values;
        this.first = first;
        this.last = last;
    }

    void opCall() nothrow
    {
        foreach (index; first .. last)
            values[index] = index + 1;
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

private void submitRange(Executor executor, StoreRange[] jobs,
    TaskHandle!void[] handles, size_t first, size_t last, bool batched)
{
    if (!batched)
    {
        foreach (index; first .. last)
            handles[index] = executor.submit(jobs[index]);
        return;
    }

    auto batchHandles = executor.submitBatch(jobs[first .. last]);
    foreach (offset, handle; batchHandles)
        handles[first + offset] = handle;
}

private Thread makeSubmitThread(Executor executor, StoreRange[] jobs,
    TaskHandle!void[] handles, size_t first, size_t last, bool batched)
{
    return new Thread({
        submitRange(executor, jobs, handles, first, last, batched);
    });
}

void main(string[] args)
{
    enforce(args.length == 5 || args.length == 6 || args.length == 7 ||
        args.length == 8,
        "usage: short-tasks SAMPLES WARMUPS ITEMS WORKERS [INGRESS RETAINED [PRODUCERS]] or [PRODUCERS]");
    const samples = to!size_t(args[1]);
    const warmups = to!size_t(args[2]);
    const items = to!size_t(args[3]);
    const workers = to!size_t(args[4]);
    const ingress = args.length >= 7 ? to!size_t(args[5]) : 256UL;
    const retained = args.length >= 7 ? to!size_t(args[6]) : 512UL;
    const producers = args.length == 6 ? to!size_t(args[5])
        : args.length == 8 ? to!size_t(args[7]) : 1UL;
    enforce(samples > 0 && samples <= 10000 && warmups <= 10000 &&
        items > 0 && items <= 1_000_000 && workers > 0 && workers <= 256 &&
        ingress > 0 && retained > 0 && retained <= 10_000_000 &&
        producers > 0 && producers <= 256,
        "invalid benchmark dimensions");

    auto executor = new Executor(workers, ingress, retained);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[items];
    auto handles = new TaskHandle!void[items];
    const expected = cast(ulong) items * (items + 1) / 2;
    immutable grains = [1UL, 4UL, 16UL, 64UL, 256UL];
    StoreRange[][] jobSets;
    foreach (grain; grains)
    {
        const taskCount = items / grain + (items % grain != 0 ? 1 : 0);
        auto jobs = new StoreRange[taskCount];
        foreach (task; 0 .. taskCount)
        {
            const first = task * grain;
            const last = first + (items - first < grain
                ? items - first : grain);
            jobs[task] = StoreRange(values, first, last);
        }
        jobSets ~= jobs;
    }
    string[] arms = ["serial", "inline", "parallel_1", "parallel_4",
        "parallel_16", "parallel_64", "parallel_256", "submit_1",
        "submit_4", "submit_16", "submit_64", "submit_256"];
    foreach (grainIndex, grain; grains)
    {
        const tasksPerProducer = jobSets[grainIndex].length / producers +
            (jobSets[grainIndex].length % producers != 0 ? 1 : 0);
        if (tasksPerProducer <= ingress && tasksPerProducer <= retained)
            arms ~= "batch_" ~ to!string(grain);
    }
    writeln("phase,sample,order,arm,workers,producers,items,ingress,retained,tasks,submit_ns,wait_ns,total_ns,checksum");

    foreach (sample; 0 .. warmups + samples)
    {
        const offset = sample % arms.length;
        foreach (order; 0 .. arms.length)
        {
            const arm = arms[(offset + order) % arms.length];
            values[] = 0;
            long submitNs;
            long waitNs;
            long totalNs;
            size_t taskCount;
            const totalStart = MonoTime.currTime;
            auto body = (size_t index) { values[index] = index + 1; };

            if (arm == "serial")
            {
                foreach (index; 0 .. items)
                    body(index);
            }
            else if (arm == "inline")
            {
                executor.parallelFor(items, items, body);
            }
            else if (arm.startsWith("parallel_"))
            {
                const grain = to!size_t(arm[9 .. $]);
                executor.parallelFor(items, grain, body);
            }
            else if (arm.startsWith("batch_"))
            {
                const grain = to!size_t(arm[6 .. $]);
                size_t grainIndex;
                foreach (index, candidate; grains)
                {
                    if (candidate == grain)
                    {
                        grainIndex = index;
                        break;
                    }
                }
                auto selectedJobs = jobSets[grainIndex];
                taskCount = selectedJobs.length;
                const submitStart = MonoTime.currTime;
                if (producers == 1)
                    submitRange(executor, selectedJobs, handles,
                        0, taskCount, true);
                else
                {
                    Thread[] producerThreads;
                    foreach (producer; 0 .. producers)
                    {
                        const first = taskCount * producer / producers;
                        const last = taskCount * (producer + 1) / producers;
                        producerThreads ~= makeSubmitThread(executor,
                            selectedJobs, handles, first, last, true);
                    }
                    foreach (thread; producerThreads) thread.start();
                    foreach (thread; producerThreads) thread.join();
                }
                submitNs = elapsedNs(submitStart);
                const waitStart = MonoTime.currTime;
                foreach (index; 0 .. taskCount)
                    handles[index].get();
                waitNs = elapsedNs(waitStart);
            }
            else
            {
                const batch = to!size_t(arm[7 .. $]);
                size_t batchIndex;
                foreach (index, grain; grains)
                {
                    if (grain == batch)
                    {
                        batchIndex = index;
                        break;
                    }
                }
                auto selectedJobs = jobSets[batchIndex];
                taskCount = selectedJobs.length;
                const submitStart = MonoTime.currTime;
                if (producers == 1)
                    submitRange(executor, selectedJobs, handles,
                        0, taskCount, false);
                else
                {
                    Thread[] producerThreads;
                    foreach (producer; 0 .. producers)
                    {
                        const first = taskCount * producer / producers;
                        const last = taskCount * (producer + 1) / producers;
                        producerThreads ~= makeSubmitThread(executor,
                            selectedJobs, handles, first, last, false);
                    }
                    foreach (thread; producerThreads) thread.start();
                    foreach (thread; producerThreads) thread.join();
                }
                submitNs = elapsedNs(submitStart);
                const waitStart = MonoTime.currTime;
                foreach (task; 0 .. taskCount)
                    handles[task].get();
                waitNs = elapsedNs(waitStart);
            }

            totalNs = elapsedNs(totalStart);
            const actual = checksum(values);
            enforce(actual == expected && totalNs > 0,
                arm ~ ": checksum or timing mismatch");
            writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                ",", order, ",", arm, ",", workers, ",", producers, ",",
                items, ",",
                ingress, ",", retained, ",", taskCount, ",", submitNs,
                ",", waitNs, ",", totalNs, ",", actual);
        }
    }
}
