module main;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;

extern(C)
long d_step_mfence(
    shared long* top,
    shared long* bottom)
    @nogc nothrow;

extern(C)
long d_step_seq_cas(
    shared long* top,
    shared long* bottom,
    shared long* fenceWord)
    @nogc nothrow;

enum size_t defaultIterations = 20_000_000;
enum size_t warmups = 4;
enum size_t samples = 16;

enum Variant
{
    mfence,
    seqCas
}

ulong run(
    Variant variant,
    shared long* top,
    shared long* bottom,
    shared long* fenceWord,
    size_t iterations,
    ref ulong checksum)
{
    *top = 0;
    *bottom = cast(long) iterations + 1;
    *fenceWord = 0;

    ulong local;

    StopWatch sw;
    sw.start();

    final switch (variant)
    {
        case Variant.mfence:
            foreach (_; 0 .. iterations)
            {
                local += cast(ulong)
                    d_step_mfence(
                        top,
                        bottom);
            }
            break;

        case Variant.seqCas:
            foreach (_; 0 .. iterations)
            {
                const result =
                    d_step_seq_cas(
                        top,
                        bottom,
                        fenceWord);

                assert(result != long.min);

                local += cast(ulong) result;
            }
            break;
    }

    sw.stop();

    checksum += local;

    return cast(ulong)
        sw.peek.total!"nsecs";
}

double benchmark(
    Variant variant,
    shared long* top,
    shared long* bottom,
    shared long* fenceWord,
    size_t iterations,
    ref ulong checksum)
{
    foreach (_; 0 .. warmups)
        run(
            variant,
            top,
            bottom,
            fenceWord,
            iterations,
            checksum);

    ulong[samples] times;

    foreach (i; 0 .. samples)
        times[i] =
            run(
                variant,
                top,
                bottom,
                fenceWord,
                iterations,
                checksum);

    times[].sort();

    const median = (
        cast(double) times[samples / 2 - 1] +
        cast(double) times[samples / 2]
    ) / 2.0;

    return median / iterations;
}

void main(string[] args)
{
    size_t iterations =
        defaultIterations;

    if (args.length > 1)
        iterations = args[1].to!size_t;

    shared long top;
    shared long bottom;
    shared long fenceWord;

    ulong checksum;

    const mfenceNs =
        benchmark(
            Variant.mfence,
            &top,
            &bottom,
            &fenceWord,
            iterations,
            checksum);

    const seqCasNs =
        benchmark(
            Variant.seqCas,
            &top,
            &bottom,
            &fenceWord,
            iterations,
            checksum);

    writefln(
        "mfence    = %.3f ns/iteration",
        mfenceNs);

    writefln(
        "seq-cas   = %.3f ns/iteration",
        seqCasNs);

    writefln(
        "ratio     = %.3fx",
        seqCasNs / mfenceNs);

    writefln(
        "checksum  = %s",
        checksum);
}
