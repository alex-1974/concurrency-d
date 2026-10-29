module concurrency.benchmarks.batch_wait;

import concurrency : Executor;
import core.thread : Thread;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
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

private void submitAndWait(Executor executor, StoreRange[] jobs)
{
    executor.submitBatchAndWait(jobs[]);
}

private Thread makeProducer(Executor executor, StoreRange[] jobs)
{
    return new Thread({ submitAndWait(executor, jobs); });
}

void main(string[] args)
{
    enforce(args.length == 8,
        "usage: batch-wait SAMPLES WARMUPS ITEMS WORKERS PRODUCERS INGRESS RETAINED");
    const samples = to!size_t(args[1]);
    const warmups = to!size_t(args[2]);
    const items = to!size_t(args[3]);
    const workers = to!size_t(args[4]);
    const producers = to!size_t(args[5]);
    const ingress = to!size_t(args[6]);
    const retained = to!size_t(args[7]);
    enforce(samples > 0 && samples <= 10000 && warmups <= 10000 &&
        items > 0 && items <= 1_000_000 && workers > 0 && workers <= 256 &&
        producers > 0 && producers <= 256 && ingress > 0 && retained > 0,
        "invalid benchmark dimensions");

    immutable grains = [16UL, 64UL, 256UL];
    auto executor = new Executor(workers, ingress, retained);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[items];
    const expected = cast(ulong) items * (items + 1) / 2;
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
        enforce((taskCount + producers - 1) / producers <= ingress &&
            (taskCount + producers - 1) / producers <= retained,
            "per-producer batch exceeds configured capacity");
        jobSets ~= jobs;
    }

    writeln("phase,sample,order,grain,workers,producers,items,ingress,retained,tasks,total_ns,checksum");
    foreach (sample; 0 .. warmups + samples)
    {
        foreach (order; 0 .. grains.length)
        {
            const grainIndex = (sample + order) % grains.length;
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
                ",", order, ",", grains[grainIndex], ",", workers, ",",
                producers, ",", items, ",", ingress, ",", retained, ",",
                jobs.length, ",", totalNs, ",", actual);
        }
    }
}
