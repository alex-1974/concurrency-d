import concurrency : Executor;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private ulong job(size_t id) @safe nothrow
{
    ulong value = id + 1;
    foreach (step; 0 .. 1024)
        value = value * 1664525UL + 1013904223UL + step;
    return value;
}

private ulong expectedChecksum()
{
    ulong sum;
    foreach (id; 0 .. 1024) sum += job(id);
    return sum * 8;
}

private ulong run(bool adaptive)
{
    auto executor = new Executor(4, 256, 1025);
    scope (exit) executor.closeAndJoin();
    auto values = new ulong[1024];
    ulong checksum;
    foreach (_; 0 .. 8)
    {
        if (adaptive)
            executor.parallelForAdaptive(values.length, 1,
                (size_t id) { values[id] = job(id); });
        else
            executor.parallelFor(values.length, 1,
                (size_t id) { values[id] = job(id); });
        foreach (value; values) checksum += value;
    }
    executor.closeAndJoin();
    return checksum;
}

void main(string[] args)
{
    enforce(args.length == 3, "usage: profile-heavy adaptive|fixed REPEATS");
    const adaptive = args[1] == "adaptive";
    enforce(adaptive || args[1] == "fixed", "mode must be adaptive or fixed");
    const repeats = to!size_t(args[2]);
    enforce(repeats > 0, "REPEATS must be positive");
    const expected = expectedChecksum();
    ulong total;
    foreach (_; 0 .. repeats)
    {
        const actual = run(adaptive);
        enforce(actual == expected, "checksum mismatch");
        total += actual;
    }
    enforce(total == expected * repeats, "aggregate checksum mismatch");
    writeln("PROFILE_RESULT mode=", args[1], " repeats=", repeats,
        " checksum=", expected, " aggregate=", total);
}
