/++
 P18 RESEARCH ONLY: process CPU-time during sustained empty-pool intervals.
 No TaskRefs are admitted. Workers have had time to park before sampling.
 Measures CPU activity including the coordinator; NOT watts, energy, spin
 attribution or an @safe TaskScope guarantee.
+/
module concurrency.research.p18_idle_consumer;

version (P18Grace)
{
    import concurrency.research.m1_p18_grace_pool : SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool : SubmissionWorkerPool;
}

import core.stdc.stdlib : abort;
import core.stdc.time : clock, CLOCKS_PER_SEC;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;
import std.conv : to;
import std.stdio : writeln;

private struct Options
{
    size_t settleMs = 250;
    size_t holdMs = 1000;
    size_t rounds = 3;
}

private Options parse(string[] args)
{
    Options opts;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (i + 1 >= args.length)
            throw new Exception("P18 idle option lacks value");
        auto flag = args[i];
        auto value = args[++i];
        switch (flag)
        {
            case "--settle-ms": opts.settleMs = to!size_t(value); break;
            case "--hold-ms": opts.holdMs = to!size_t(value); break;
            case "--rounds": opts.rounds = to!size_t(value); break;
            default: throw new Exception("P18 idle unknown option " ~ flag);
        }
    }
    if (opts.settleMs < 20 || opts.settleMs > 10_000 ||
        opts.holdMs < 20 || opts.holdMs > 30_000 ||
        opts.rounds < 1 || opts.rounds > 40)
        throw new Exception("P18 invalid idle sampling options");
    return opts;
}

private void closeOrAbort(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
        abort(); // Join failure: no claim of native-worker quiescence.
}

void main(string[] args) @system
{
    auto opts = parse(args);
    writeln("phase,workers,round,settle_ms,hold_ms,wall_ns,process_cpu_ns,",
            "parks_before,parks_after,accepted,completed");

    foreach (workers; [1, 2, 4])
    {
        auto pool = new SubmissionWorkerPool(workers, 64);
        try
        {
            Thread.sleep(dur!"msecs"(cast(long) opts.settleMs));
            foreach (round; 0 .. opts.rounds)
            {
                auto parksBefore = pool.parkCount();
                const wallStart = MonoTime.currTime.ticks;
                const cpuStart = clock();
                Thread.sleep(dur!"msecs"(cast(long) opts.holdMs));
                const cpuEnd = clock();
                const wallEnd = MonoTime.currTime.ticks;
                auto parksAfter = pool.parkCount();

                if (cpuStart < 0 || cpuEnd < cpuStart ||
                    wallEnd <= wallStart || parksAfter < parksBefore)
                    throw new Exception("P18 idle invalid monotonic sample");
                const cpuNs = cast(long)(
                    (cast(double) (cpuEnd - cpuStart) * 1_000_000_000.0) /
                    cast(double) CLOCKS_PER_SEC);
                const wallNs = ticksToNSecs(wallEnd - wallStart);
                if (cpuNs < 0 || wallNs <= 0)
                    throw new Exception("P18 idle invalid CPU/wall time");
                // These are whole-process clocks, not per-worker samples.
                writeln("measure,", workers, ",", round, ",",
                    opts.settleMs, ",", opts.holdMs, ",", wallNs, ",",
                    cpuNs, ",", parksBefore, ",", parksAfter, ",",
                    pool.acceptedCount(), ",", pool.completedCount());
            }
        }
        finally
            closeOrAbort(pool);
        if (pool.acceptedCount() != 0 || pool.completedCount() != 0)
            throw new Exception("P18 idle unexpectedly admitted a TaskRef");
    }
    writeln("P18_IDLE_PASS no tasks admitted; all native workers joined");
}
