// Opt-in matched public-facade/internal-owner diagnostic; no timing threshold.
module concurrency.benchmarks.executor;
import concurrency : Executor, TaskHandle;
import concurrency.internal.owned_task : OwnedTaskExecutor;
import core.thread : Thread;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writefln;

private struct Job
{
    uint value;
    uint iterations = 128;
    ulong opCall()
    {
        ulong result = value;
        foreach (_; 0 .. iterations) result = result * 1664525UL + 1013904223UL;
        return result;
    }
}
private Thread makeProducer(Pool)(Pool executor, TaskHandle!ulong[] handles,
    size_t first, size_t last, uint iterations)
{
    return new Thread({
        foreach (i; first .. last)
        {
            Job job;
            job.value = cast(uint)i;
            job.iterations = iterations;
            handles[i] = executor.submit(job);
        }
    });
}
private void run(Pool)(string arm, size_t producers, size_t workers, size_t count,
    uint iterations)
{
    auto handles = new TaskHandle!ulong[count];
    const start = MonoTime.currTime;
    auto executor = new Pool(workers, 256, 512);
    Thread[] threads;
    foreach (i; 0 .. producers)
        threads ~= makeProducer(executor, handles, i * count / producers,
            (i + 1) * count / producers, iterations);
    foreach (t; threads) t.start();
    foreach (t; threads) t.join();
    ulong sum;
    foreach (h; handles) sum += h.get();
    executor.closeAndJoin();
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    ulong expected;
    foreach (i; 0 .. count)
    {
        Job job;
        job.value = cast(uint)i;
        job.iterations = iterations;
        expected += job();
    }
    enforce(sum == expected && elapsed > 0, "matched benchmark checksum/time mismatch");
    writefln("PUBLIC_PATH_DIAGNOSTIC arm=%s producers=%s workers=%s tasks=%s iterations=%s elapsed_ns=%s checksum=%s",
        arm, producers, workers, count, iterations, elapsed, sum);
}
void main(string[] args)
{
    enforce(args.length == 5 || args.length == 6,
        "usage: executor-benchmark public|internal PRODUCERS WORKERS TASKS [ITERATIONS]");
    auto producers = to!size_t(args[2]);
    auto workers = to!size_t(args[3]);
    auto count = to!size_t(args[4]);
    auto iterations = args.length == 6 ? to!uint(args[5]) : 128U;
    enforce(producers > 0 && workers > 0 && count >= producers && count <= uint.max,
        "invalid benchmark dimensions");
    enforce(iterations > 0 && iterations <= 1_000_000, "invalid kernel iteration count");
    if (args[1] == "public") run!Executor("public", producers, workers, count, iterations);
    else if (args[1] == "internal") run!OwnedTaskExecutor("internal", producers, workers, count, iterations);
    else throw new Exception("unknown benchmark arm");
}
