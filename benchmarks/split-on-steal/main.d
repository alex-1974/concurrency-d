module concurrency.benchmarks.split_on_steal;

import concurrency : Executor;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.string : indexOf, startsWith;
import std.parallelism : TaskPool;
import std.range : iota;
import std.stdio : writeln;

private enum waves = 8;
private enum Pattern { uniform, scattered, prefix, suffix }

private struct Workload
{
    string name;
    size_t items;
    uint iterations;
    uint extra;
    Pattern pattern;
}

private struct Job
{
    size_t index;
    Workload workload;

    this(size_t index, Workload workload) @safe nothrow
    {
        this.index = index;
        this.workload = workload;
    }

    ulong opCall() const nothrow
    {
        uint variation;
        final switch (workload.pattern)
        {
            case Pattern.uniform: break;
            case Pattern.scattered:
                if ((index * 2654435761UL) % 8 == 0)
                    variation = workload.extra;
                break;
            case Pattern.prefix:
                if (index < workload.items / 8)
                    variation = workload.extra;
                break;
            case Pattern.suffix:
                if (index >= workload.items - workload.items / 8)
                    variation = workload.extra;
                break;
        }
        ulong value = cast(ulong) index + 1;
        foreach (i; 0 .. workload.iterations + variation)
            value = value * 1664525UL + 1013904223UL + i;
        return value;
    }
}

private ulong checksum(Workload workload)
{
    ulong result;
    foreach (index; 0 .. workload.items)
        result += Job(index, workload)();
    return result;
}

private ulong runPhobos(TaskPool pool, Workload workload, size_t batchSize,
    ulong[] values)
{
    ulong result;
    foreach (_; 0 .. waves)
    {
        foreach (index; pool.parallel(iota(0, workload.items), batchSize))
            values[index] = Job(index, workload)();
        foreach (value; values)
            result += value;
    }
    return result;
}

private ulong run(Executor executor, TaskPool pool, Workload workload,
    string arm, ulong[] values)
{
    if (arm.startsWith("phobos_"))
        return runPhobos(pool, workload, to!size_t(arm[7 .. $]), values);

    const separator = arm.indexOf('_');
    const grain = to!size_t(arm[separator + 1 .. $]);
    const adaptive = arm.startsWith("adaptive_");
    ulong result;
    foreach (_; 0 .. waves)
    {
        if (adaptive)
            executor.parallelForAdaptive(workload.items, grain, (size_t index) {
                values[index] = Job(index, workload)();
            });
        else
            executor.parallelFor(workload.items, grain, (size_t index) {
                values[index] = Job(index, workload)();
            });
        foreach (value; values)
            result += value;
    }
    return result;
}

void main(string[] args)
{
    enforce(args.length == 3, "usage: split-on-steal SAMPLES WARMUPS");
    const samples = to!size_t(args[1]);
    const warmups = to!size_t(args[2]);
    enforce(samples > 0 && samples <= 1000 && warmups <= 1000,
        "samples must be 1..1000 and warmups 0..1000");
    immutable workloads = [
        Workload("short_uniform_1024", 1024, 16, 0, Pattern.uniform),
        Workload("medium_uniform_1024", 1024, 256, 0, Pattern.uniform),
        Workload("scattered_1024", 1024, 128, 896, Pattern.scattered),
        Workload("heavy_prefix_1024", 1024, 128, 896, Pattern.prefix),
        Workload("heavy_suffix_1024", 1024, 128, 896, Pattern.suffix),
        Workload("short_uniform_16384", 16384, 16, 0, Pattern.uniform),
        Workload("medium_uniform_16384", 16384, 256, 0, Pattern.uniform),
        Workload("scattered_16384", 16384, 128, 896, Pattern.scattered),
        Workload("heavy_prefix_16384", 16384, 128, 896, Pattern.prefix),
        Workload("heavy_suffix_16384", 16384, 128, 896, Pattern.suffix),
    ];
    immutable arms = ["fixed_1", "fixed_4", "fixed_16", "fixed_64", "fixed_256",
        "adaptive_1", "adaptive_4", "adaptive_16", "adaptive_64", "adaptive_256",
        "phobos_1", "phobos_4", "phobos_16", "phobos_64", "phobos_256"];
    auto executor = new Executor(4, 64, 64);
    scope (exit) executor.closeAndJoin();
    auto pool = new TaskPool(3);
    scope (exit) pool.finish(true);
    writeln("phase,sample,order,workload,arm,workers,item_count,elapsed_ns,checksum");
    foreach (workloadIndex, workload; workloads)
    {
        const expected = checksum(workload) * waves;
        auto values = new ulong[workload.items];
        foreach (sample; 0 .. warmups + samples)
        {
            const offset = (sample + workloadIndex) % arms.length;
            foreach (order; 0 .. arms.length)
            {
                const arm = arms[(offset + order) % arms.length];
                const started = MonoTime.currTime;
                const actual = run(executor, pool, workload, arm, values);
                const elapsed = (MonoTime.currTime - started).total!"nsecs";
                enforce(actual == expected && elapsed > 0,
                    workload.name ~ "/checksum or timing mismatch");
                writeln(sample < warmups ? "warmup" : "measure", ",", sample,
					",", order, ",", workload.name, ",", arm,
					",4,", workload.items,
                    ",", elapsed, ",", actual);
            }
        }
    }
}
