// Matched two-way join/scope/submit diagnostic; no timing threshold.
module concurrency.benchmarks.fork_join;

import concurrency : Executor, TaskHandle;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private struct Job
{
    uint id;
    uint iterations;

    this(uint id, uint iterations) @safe nothrow
    {
        this.id = id;
        this.iterations = iterations;
    }

    ulong opCall() @safe nothrow
    {
        ulong value = cast(ulong)id + 1;
        foreach (i; 0 .. iterations)
            value = value * 1664525UL + 1013904223UL + i;
        return value;
    }
}

private ulong expectedChecksum(size_t pairs, uint iterations) @safe nothrow
{
    ulong checksum;
    foreach (i; 0 .. pairs * 2)
        checksum += Job(cast(uint)i, iterations)();
    return checksum;
}

private struct Driver
{
    Executor executor;
    string mode;
    size_t pairs;
    uint iterations;

    this(Executor executor, string mode, size_t pairs, uint iterations)
    {
        this.executor = executor;
        this.mode = mode;
        this.pairs = pairs;
        this.iterations = iterations;
    }

    ulong opCall()
    {
        ulong checksum;
        foreach (pair; 0 .. pairs)
        {
            Job left = Job(cast(uint)(pair * 2), iterations);
            Job right = Job(cast(uint)(pair * 2 + 1), iterations);
            if (mode == "join")
            {
                auto result = executor.join(left, right);
                checksum += result.left + result.right;
            }
            else if (mode == "scope")
            {
                TaskHandle!ulong leftHandle;
                TaskHandle!ulong rightHandle;
                executor.withScope(2, (ref tasks) {
                    leftHandle = tasks.spawn(left);
                    rightHandle = tasks.spawn(right);
                });
                checksum += leftHandle.get() + rightHandle.get();
            }
            else
            {
                auto leftHandle = executor.submit(left);
                auto rightHandle = executor.submit(right);
                checksum += leftHandle.get() + rightHandle.get();
            }
        }
        return checksum;
    }
}

private long measure(string mode, size_t pairs, size_t workers,
    uint iterations, out ulong checksum)
{
    auto executor = new Executor(workers, 64, pairs * 2 + 65);
    Driver driver = Driver(executor, mode, pairs, iterations);
    const start = MonoTime.currTime;
    checksum = executor.submit(driver).get();
    executor.closeAndJoin();
    return (MonoTime.currTime - start).total!"nsecs";
}

void main(string[] args)
{
    enforce(args.length == 6,
        "usage: fork-join PAIRS WORKERS KERNEL_ITERATIONS SAMPLES WARMUPS");
    const pairs = to!size_t(args[1]);
    const workers = to!size_t(args[2]);
    const iterations = to!uint(args[3]);
    const samples = to!size_t(args[4]);
    const warmups = to!size_t(args[5]);
    enforce(pairs > 0 && pairs <= 2048 && workers >= 2 && workers <= 256,
        "pairs must be 1..2048 and workers 2..256");
    enforce(iterations > 0 && iterations <= 1_000_000,
        "kernel iterations must be 1..1000000");
    enforce(samples > 0 && samples <= 1000 && warmups <= 1000,
        "samples must be 1..1000 and warmups 0..1000");

    immutable modes = ["join", "scope", "submit"];
    const expected = expectedChecksum(pairs, iterations);
    writeln("phase,sample,order,mode,pairs,workers,kernel_iterations,elapsed_ns,checksum");
    foreach (sample; 0 .. warmups + samples)
    {
        const offset = sample % modes.length;
        foreach (order; 0 .. modes.length)
        {
            const mode = modes[(offset + order) % modes.length];
            ulong checksum;
            const elapsed = measure(mode, pairs, workers, iterations, checksum);
            enforce(checksum == expected && elapsed > 0,
                mode ~ " checksum/time mismatch");
            writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                ",", order, ",", mode, ",", pairs, ",", workers, ",",
                iterations, ",", elapsed, ",", checksum);
        }
    }
}
