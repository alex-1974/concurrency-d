module main;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;

alias Step =
    extern(C) long function(
        shared long*,
        shared long*,
        shared long*)
        @nogc nothrow;

extern(C) long step_mfence(
    shared long*, shared long*, shared long*)
    @nogc nothrow;

extern(C) long step_cas(
    shared long*, shared long*, shared long*)
    @nogc nothrow;

extern(C) long step_fetch_add(
    shared long*, shared long*, shared long*)
    @nogc nothrow;

extern(C) long step_exchange(
    shared long*, shared long*, shared long*)
    @nogc nothrow;

enum size_t warmups = 4;
enum size_t samples = 16;

double benchmark(
    Step step,
    size_t iterations,
    ref ulong checksum)
{
    shared long top;
    shared long bottom;
    shared long scratch;

    ulong[samples] times;

    foreach (phase; 0 .. warmups + samples)
    {
        top = 0;
        bottom = cast(long) iterations + 1;
        scratch = 0;

        ulong local;

        StopWatch sw;
        sw.start();

        foreach (_; 0 .. iterations)
        {
            const value =
                step(
                    &top,
                    &bottom,
                    &scratch);

            assert(value != long.min);

            local += cast(ulong) value;
        }

        sw.stop();

        checksum += local;

        if (phase >= warmups)
            times[phase - warmups] =
                cast(ulong) sw.peek.total!"nsecs";
    }

    times[].sort();

    const median = (
        cast(double) times[samples / 2 - 1] +
        cast(double) times[samples / 2]
    ) / 2.0;

    return median / iterations;
}

void main(string[] args)
{
    size_t iterations = 20_000_000;

    if (args.length > 1)
        iterations = args[1].to!size_t;

    ulong checksum;

    const a =
        benchmark(
            &step_mfence,
            iterations,
            checksum);

    const b =
        benchmark(
            &step_cas,
            iterations,
            checksum);

    const c =
        benchmark(
            &step_fetch_add,
            iterations,
            checksum);

    const d =
        benchmark(
            &step_exchange,
            iterations,
            checksum);

    writefln("mfence     %.3f ns", a);
    writefln("cas         %.3f ns", b);
    writefln("fetch-add   %.3f ns", c);
    writefln("exchange    %.3f ns", d);
    writefln("checksum    %s", checksum);
}
