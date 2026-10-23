// Matched public TaskScope versus submit + get diagnostic; no timing threshold.
module concurrency.benchmarks.scopes;

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

private struct Sample
{
    string mode;
    size_t pair;
    size_t tasks;
    size_t workers;
    uint iterations;
    long elapsedNs;
    ulong checksum;
}

private ulong expectedChecksum(size_t tasks, uint iterations) @safe nothrow
{
    ulong sum;
    foreach (i; 0 .. tasks)
        sum += Job(cast(uint)i, iterations)();
    return sum;
}

private Sample measure(string mode, size_t pair, size_t tasks,
    size_t workers, uint iterations)
{
    // Each arm gets a fresh, identically configured executor. Worker startup
    // is outside the clock; close/join and all task submission/wait work are
    // inside it for both arms.
    auto executor = new Executor(workers, 64, tasks + 64);
    auto handles = new TaskHandle!ulong[tasks];
    const start = MonoTime.currTime;

    if (mode == "scope")
    {
        executor.withScope(tasks, (ref taskGroup) {
            foreach (i; 0 .. tasks)
                handles[i] = taskGroup.spawn(Job(cast(uint)i, iterations));
        });
    }
    else
    {
        foreach (i; 0 .. tasks)
            handles[i] = executor.submit(Job(cast(uint)i, iterations));
    }

    ulong checksum;
    foreach (handle; handles)
        checksum += handle.get();
    executor.closeAndJoin();
    const elapsed = (MonoTime.currTime - start).total!"nsecs";

    enforce(checksum == expectedChecksum(tasks, iterations),
        mode ~ " checksum mismatch");
    enforce(elapsed > 0, "clock returned a non-positive duration");
    return Sample(mode, pair, tasks, workers, iterations, elapsed, checksum);
}

private void emit(Sample sample, string phase)
{
    writeln(phase, ",", sample.pair, ",", sample.mode, ",", sample.tasks,
        ",", sample.workers, ",", sample.iterations, ",", sample.elapsedNs,
        ",", sample.checksum);
}

void main(string[] args)
{
    enforce(args.length == 6,
        "usage: scopes TASKS WORKERS KERNEL_ITERATIONS PAIRS WARMUPS");
    const tasks = to!size_t(args[1]);
    const workers = to!size_t(args[2]);
    const iterations = to!uint(args[3]);
    const pairs = to!size_t(args[4]);
    const warmups = to!size_t(args[5]);
    enforce(tasks > 0 && tasks <= 4096 && workers > 0 && workers <= 256,
        "tasks must be 1..4096 and workers must be 1..256");
    enforce(iterations > 0 && iterations <= 1_000_000,
        "kernel iterations must be 1..1000000");
    enforce(pairs > 0 && pairs <= 1000 && warmups <= 1000,
        "pairs must be 1..1000 and warmups 0..1000");

    writeln("phase,pair,mode,tasks,workers,kernel_iterations,elapsed_ns,checksum");
    foreach (pair; 0 .. warmups + pairs)
    {
        const reverse = (pair & 1) != 0;
        Sample first = measure(reverse ? "submit" : "scope", pair,
            tasks, workers, iterations);
        Sample second = measure(reverse ? "scope" : "submit", pair,
            tasks, workers, iterations);
        const phase = pair < warmups ? "warmup" : "measure";
        emit(first, phase);
        emit(second, phase);
    }
}
