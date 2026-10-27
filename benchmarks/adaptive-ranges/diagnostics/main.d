module concurrency.benchmarks.adaptive_range_diagnostics;

import concurrency : Executor, TaskHandle, WorkSize;
import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private enum itemCount = 1024;
private enum waves = 8;
private enum workerCount = 4;

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
        ulong value = cast(ulong)id + 1;
        foreach (step; 0 .. iterations)
            value = value * 1664525UL + 1013904223UL + step;
        return value;
    }
}

private struct ScopeWork
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
        return Work(id, iterations)();
    }
}

private ulong expected(size_t count, uint iterations)
{
    ulong result;
    foreach (id; 0 .. count)
        result += Work(id, iterations)();
    return result;
}

private ulong runSerial(uint iterations, size_t repetitions)
{
    auto values = new ulong[itemCount];
    ulong sum;
    foreach (repetition; 0 .. repetitions)
        foreach (wave; 0 .. waves)
        {
            foreach (id; 0 .. itemCount)
                values[id] = Work(id, iterations)();
            foreach (value; values)
                sum += value;
        }
    return sum;
}

private ulong runRanges(Executor executor, uint iterations, size_t repetitions,
    bool adaptive)
{
    auto values = new ulong[itemCount];
    ulong sum;
    foreach (repetition; 0 .. repetitions)
    foreach (wave; 0 .. waves)
    {
        if (adaptive)
            executor.parallelForAdaptive(itemCount, 1, (size_t id) {
                values[id] = Work(id, iterations)();
            });
        else
            executor.parallelFor(itemCount, 1, (size_t id) {
                values[id] = Work(id, iterations)();
            });
        foreach (value; values)
            sum += value;
    }
    return sum;
}

private void verifyRangeCoverage(Executor executor, bool adaptive)
{
    shared size_t[itemCount] hits;
    foreach (id; 0 .. itemCount)
        hits[id] = 0;
    if (adaptive)
        executor.parallelForAdaptive(itemCount, 1, (size_t id) {
            atomicFetchAdd!(MemoryOrder.rel)(hits[id], 1UL);
        });
    else
        executor.parallelFor(itemCount, 1, (size_t id) {
            atomicFetchAdd!(MemoryOrder.rel)(hits[id], 1UL);
        });
    foreach (id; 0 .. itemCount)
        enforce(atomicLoad!(MemoryOrder.acq)(hits[id]) == 1,
            "range coverage was not exactly once at index " ~ to!string(id));
}

private struct ScopeMeasurement
{
    ulong checksum;
    long totalNs;
    long submitBodyNs;
}

private ScopeMeasurement runScope(Executor executor, size_t count,
    uint iterations)
{
    auto handles = new TaskHandle!ulong[](count);
    long submitBodyNs;
    const started = MonoTime.currTime;
    executor.withScope(count, (ref tasks) {
        const bodyStarted = MonoTime.currTime;
        foreach (id; 0 .. count)
            handles[id] = tasks.spawn(ScopeWork(id, iterations), WorkSize.small);
        submitBodyNs = (MonoTime.currTime - bodyStarted).total!"nsecs";
    });
    const totalNs = (MonoTime.currTime - started).total!"nsecs";

    ulong sum;
    foreach (handle; handles)
        sum += handle.get();
    return ScopeMeasurement(sum, totalNs, submitBodyNs);
}

void main(string[] args)
{
    enforce(args.length == 3 || args.length == 4,
        "usage: concurrency-adaptive-phase-diagnostic SAMPLES WARMUPS [ORDER_OFFSET]");
    const samples = to!size_t(args[1]);
    const warmups = to!size_t(args[2]);
    const orderOffset = args.length == 4 ? to!size_t(args[3]) : 0;
    enforce(samples > 0 && samples <= 1000 && warmups <= 1000,
        "samples must be 1..1000 and warmups 0..1000");

    auto executor = new Executor(workerCount, 64, itemCount + 1);
    scope (exit) executor.closeAndJoin();
    // Verify coverage separately so atomic validation does not perturb timings.
    verifyRangeCoverage(executor, false);
    verifyRangeCoverage(executor, true);
    immutable iterations = [0U, 16U, 1024U];
    immutable names = ["noop", "short", "heavy"];
    immutable arms = ["serial", "parallel_fixed", "parallel_adaptive"];
    writeln("phase,sample,order,scenario,arm,workers,items,grain,repetitions,elapsed_ns,submit_body_ns,post_body_ns,checksum");

    foreach (scenario, cost; iterations)
    {
        const repetitions = scenario == 0 ? 64UL : scenario == 1 ? 16UL : 1UL;
        const expectedTotal = expected(itemCount, cost) * waves * repetitions;
        foreach (sample; 0 .. warmups + samples)
        {
            foreach (order; 0 .. arms.length)
            {
                const arm = (sample + scenario + order + orderOffset) % arms.length;
                const started = MonoTime.currTime;
                ulong checksum;
                if (arm == 0)
                    checksum = runSerial(cost, repetitions);
                else
                    checksum = runRanges(executor, cost, repetitions, arm == 2);
                const elapsed = (MonoTime.currTime - started).total!"nsecs";
                enforce(checksum == expectedTotal && elapsed > 0,
                    names[scenario] ~ "/" ~ arms[arm] ~ " checksum/time mismatch: " ~
                    to!string(checksum) ~ " != " ~ to!string(expectedTotal) ~
                    " elapsed=" ~ to!string(elapsed));
                writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                    ",", order, ",", names[scenario], ",", arms[arm], ",",
                    workerCount, ",", itemCount * waves * repetitions, ",1,",
                    repetitions, ",", elapsed,
                    ",,,", checksum);
            }
        }
    }

    immutable taskCounts = [4UL, 16UL, 64UL];
    foreach (sample; 0 .. warmups + samples)
    {
        foreach (order; 0 .. iterations.length * taskCounts.length)
        {
            const scenario = (order + sample + orderOffset) % iterations.length;
            const countIndex = (order / iterations.length + sample + orderOffset) % taskCounts.length;
            const count = taskCounts[countIndex];
            const cost = iterations[scenario];
            const expectedSum = expected(count, cost);
            const measurement = runScope(executor, count, cost);
            enforce(measurement.checksum == expectedSum &&
                    measurement.totalNs >= measurement.submitBodyNs,
                "scope checksum/timing mismatch");
            writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                ",", order, ",scope_", names[scenario], "_", count,
                ",scope_spawn_drain,", workerCount, ",", count,
                ",0,1,", measurement.totalNs, ",", measurement.submitBodyNs,
                ",", measurement.totalNs - measurement.submitBodyNs,
                ",", measurement.checksum);
        }
    }
    executor.closeAndJoin();
}
