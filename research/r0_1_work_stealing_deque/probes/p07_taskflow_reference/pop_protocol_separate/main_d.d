module main_d;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;

extern(C)
long d_pop_protocol_step(
    shared long* top,
    shared long* bottom)
    @nogc nothrow;

enum size_t defaultIterations = 20_000_000;
enum size_t warmups = 4;
enum size_t samples = 16;

ulong run(
    shared long* top,
    shared long* bottom,
    size_t iterations,
    ref ulong checksum)
{
    *top = 0;
    *bottom = cast(long) iterations + 1;

    ulong local;

    StopWatch sw;
    sw.start();

    foreach (_; 0 .. iterations)
    {
        local += cast(ulong)
            d_pop_protocol_step(
                top,
                bottom);
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

    shared long top;
    shared long bottom;

    ulong checksum;

    foreach (_; 0 .. warmups)
        run(
            &top,
            &bottom,
            iterations,
            checksum);

    ulong[samples] times;

    foreach (i; 0 .. samples)
        times[i] =
            run(
                &top,
                &bottom,
                iterations,
                checksum);

    times[].sort();

    const median = (
        cast(double) times[samples / 2 - 1] +
        cast(double) times[samples / 2]
    ) / 2.0;

    writefln(
        "D separate pop-protocol: %.3f ns/iteration checksum=%s",
        median / iterations,
        checksum);
}
