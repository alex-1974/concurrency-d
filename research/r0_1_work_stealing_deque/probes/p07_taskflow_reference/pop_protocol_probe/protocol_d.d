module protocol_d;

import core.atomic :
    MemoryOrder,
    atomicFence,
    atomicLoad,
    atomicStore;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;

enum size_t defaultIterations = 20_000_000;
enum size_t warmups = 4;
enum size_t samples = 16;

struct State
{
    shared long top;
    shared long bottom;
}

ulong run(
    ref State state,
    size_t iterations,
    ref ulong checksum)
{
    atomicStore!(MemoryOrder.raw)(
        state.top,
        0);

    atomicStore!(MemoryOrder.raw)(
        state.bottom,
        cast(long) iterations + 1);

    ulong local;

    StopWatch sw;
    sw.start();

    foreach (_; 0 .. iterations)
    {
        auto b =
            atomicLoad!(MemoryOrder.raw)(
                state.bottom) - 1;

        atomicStore!(MemoryOrder.raw)(
            state.bottom,
            b);

        atomicFence!(MemoryOrder.seq)();

        const t =
            atomicLoad!(MemoryOrder.raw)(
                state.top);

        local +=
            cast(ulong)(b - t);
    }

    sw.stop();

    checksum += local;

    return cast(ulong)
        sw.peek.total!"nsecs";
}

void main(string[] args)
{
    size_t iterations =
        defaultIterations;

    if (args.length > 1)
        iterations = args[1].to!size_t;

    State state;
    ulong checksum;

    foreach (_; 0 .. warmups)
        run(state, iterations, checksum);

    ulong[samples] times;

    foreach (i; 0 .. samples)
        times[i] =
            run(state, iterations, checksum);

    times[].sort();

    const median = (
        cast(double) times[samples / 2 - 1] +
        cast(double) times[samples / 2]
    ) / 2.0;

    writefln(
        "D pop-protocol: %.3f ns/iteration checksum=%s",
        median / iterations,
        checksum);
}
