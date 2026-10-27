// Focused fixed versus adaptive range-size diagnostic; no timing threshold.
module concurrency.benchmarks.adaptive_ranges;

import concurrency : Executor;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;
import std.string : split;

private enum waves = 8;
private enum CostPattern { uniform, scatteredHotspots, heavyPrefix, heavySuffix }

private struct Workload
{
    string name;
    size_t chunks;
    uint iterations;
    uint extraIterations;
    CostPattern pattern;
}

private struct Job
{
    size_t id;
    Workload workload;

    this(size_t id, Workload workload) @safe nothrow
    {
        this.id = id;
        this.workload = workload;
    }

    ulong opCall() const @safe nothrow
    {
        uint variation;
        final switch (workload.pattern)
        {
            case CostPattern.uniform:
                break;
            case CostPattern.scatteredHotspots:
                if ((id * 2654435761UL) % 8 == 0)
                    variation = workload.extraIterations;
                break;
            case CostPattern.heavyPrefix:
                if (id < workload.chunks / 8)
                    variation = workload.extraIterations;
                break;
            case CostPattern.heavySuffix:
                if (id >= workload.chunks - workload.chunks / 8)
                    variation = workload.extraIterations;
                break;
        }
        ulong value = cast(ulong)id + 1;
        foreach (i; 0 .. workload.iterations + variation)
            value = value * 1664525UL + 1013904223UL + i;
        return value;
    }
}

private size_t[] parseSizes(string value)
{
    size_t[] result;
    foreach (part; value.split(","))
    {
        const parsed = to!size_t(part);
        enforce(parsed > 0, "workers and grains must be positive");
        result ~= parsed;
    }
    enforce(result.length > 0, "workers and grains cannot be empty");
    return result;
}

private ulong checksum(Workload workload)
{
    ulong result;
    foreach (id; 0 .. workload.chunks)
        result += Job(id, workload)();
    return result;
}

private ulong run(Workload workload, size_t workers, size_t grainSize,
    bool adaptive)
{
    auto executor = new Executor(workers, 64, workload.chunks + 1);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[workload.chunks];
    ulong result;
    foreach (_; 0 .. waves)
    {
        if (adaptive)
            executor.parallelForAdaptive(workload.chunks, grainSize,
                (size_t id) {
                    values[id] = Job(id, workload)();
                });
        else
                executor.parallelFor(workload.chunks, grainSize, (size_t id) {
                    values[id] = Job(id, workload)();
                });
        foreach (value; values)
            result += value;
    }
    executor.closeAndJoin();
    return result;
}

void main(string[] args)
{
    enforce(args.length == 3 || args.length == 5,
        "usage: adaptive-ranges SAMPLES WARMUPS [WORKERS_CSV GRAINS_CSV]");
    const samples = to!size_t(args[1]);
    const warmups = to!size_t(args[2]);
    enforce(samples > 0 && samples <= 1000 && warmups <= 1000,
        "samples must be 1..1000 and warmups 0..1000");

    immutable workloads = [
        Workload("short_uniform", 1024, 16, 0, CostPattern.uniform),
        Workload("medium_uniform", 1024, 256, 0, CostPattern.uniform),
        Workload("long_uniform", 1024, 4096, 0, CostPattern.uniform),
        Workload("scattered_hotspots", 1024, 128, 896,
            CostPattern.scatteredHotspots),
        Workload("heavy_prefix", 1024, 128, 896, CostPattern.heavyPrefix),
        Workload("heavy_suffix", 1024, 128, 896, CostPattern.heavySuffix),
    ];
    size_t[] workerCounts;
    size_t[] grains;
    if (args.length == 5)
    {
        workerCounts = parseSizes(args[3]);
        grains = parseSizes(args[4]);
    }
    else
    {
        workerCounts = [1UL, 2UL, 4UL];
        grains = [1UL, 4UL, 16UL, 64UL, 256UL, 512UL];
    }
    immutable arms = ["parallelForReused", "parallelForAdaptiveReused"];
    writeln("phase,sample,order,workload,arm,workers,batch_size,submitted_tasks,chunks,min_iterations_per_chunk,elapsed_ns,ns_per_chunk,chunks_per_second,checksum");

    foreach (workloadIndex, workload; workloads)
    {
        const expected = checksum(workload);
        foreach (workerIndex, workers; workerCounts)
        {
            foreach (grainIndex, grain; grains)
            {
                foreach (sample; 0 .. warmups + samples)
                {
                    const offset = (sample + workloadIndex + workerIndex + grainIndex) % arms.length;
                    foreach (order; 0 .. arms.length)
                    {
                        const armIndex = (offset + order) % arms.length;
                        const adaptive = armIndex == 1;
                        const started = MonoTime.currTime;
                        const actual = run(workload, workers, grain, adaptive);
                        const elapsed = (MonoTime.currTime - started).total!"nsecs";
                        const expectedTotal = expected * waves;
                        enforce(actual == expectedTotal && elapsed > 0,
                            workload.name ~ "/" ~ arms[armIndex] ~ " checksum/time mismatch");
                        const rangeCount = workload.chunks / grain +
                            (workload.chunks % grain != 0 ? 1 : 0);
                        const participants = workers < rangeCount ? workers : rangeCount;
                        const submitted = (participants - 1) * waves;
                        const chunks = workload.chunks * waves;
                        writeln(sample < warmups ? "warmup" : "measure", ",", sample,
                            ",", order, ",", workload.name, ",", arms[armIndex], ",", workers,
                            ",", grain, ",", submitted, ",", chunks, ",", workload.iterations,
                            ",", elapsed, ",", elapsed / chunks, ",",
                            (cast(double)chunks * 1_000_000_000.0) / elapsed,
                            ",", actual);
                    }
                }
            }
        }
    }
}
