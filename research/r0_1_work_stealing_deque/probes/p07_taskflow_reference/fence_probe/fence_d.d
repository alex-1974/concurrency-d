module fence_d;

import core.atomic :
    MemoryOrder,
    atomicFence;

import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;

enum size_t defaultIterations = 20_000_000;
enum size_t defaultWarmups = 4;
enum size_t defaultSamples = 16;

ulong run(size_t iterations)
{
    StopWatch sw;
    sw.start();

    foreach (_; 0 .. iterations)
        atomicFence!(MemoryOrder.seq)();

    sw.stop();

    return cast(ulong) sw.peek.total!"nsecs";
}

void main(string[] args)
{
    size_t iterations = defaultIterations;

    if (args.length > 1)
        iterations = args[1].to!size_t;

    foreach (_; 0 .. defaultWarmups)
        run(iterations);

    ulong[defaultSamples] times;

    foreach (i; 0 .. defaultSamples)
        times[i] = run(iterations);

    import std.algorithm.sorting : sort;
    times[].sort();

    const median = (
        cast(double) times[defaultSamples / 2 - 1] +
        cast(double) times[defaultSamples / 2]
    ) / 2.0;

    writefln(
        "D atomicFence(seq): %.3f ns/fence",
        median / iterations);
}
