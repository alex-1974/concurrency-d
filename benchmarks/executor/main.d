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
    ulong opCall()
    {
        ulong result = value;
        foreach (_; 0 .. 128) result = result * 1664525UL + 1013904223UL;
        return result;
    }
}
private Thread makeProducer(Pool)(Pool executor, TaskHandle!ulong[] handles,
    size_t first, size_t last)
{
    return new Thread({
        foreach (i; first .. last)
        {
            Job job;
            job.value = cast(uint)i;
            handles[i] = executor.submit(job);
        }
    });
}
private void run(Pool)(string arm, size_t producers, size_t workers, size_t count)
{
    auto handles = new TaskHandle!ulong[count];
    const start = MonoTime.currTime;
    auto executor = new Pool(workers, 256, 512);
    Thread[] threads;
    foreach (i; 0 .. producers)
        threads ~= makeProducer(executor, handles, i * count / producers, (i + 1) * count / producers);
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
        expected += job();
    }
    enforce(sum == expected && elapsed > 0, "matched benchmark checksum/time mismatch");
    writefln("PUBLIC_PATH_DIAGNOSTIC arm=%s producers=%s workers=%s tasks=%s elapsed_ns=%s checksum=%s",
        arm, producers, workers, count, elapsed, sum);
}
void main(string[] args)
{
    enforce(args.length == 5, "usage: executor-benchmark public|internal PRODUCERS WORKERS TASKS");
    auto producers = to!size_t(args[2]);
    auto workers = to!size_t(args[3]);
    auto count = to!size_t(args[4]);
    enforce(producers > 0 && workers > 0 && count >= producers && count <= uint.max,
        "invalid benchmark dimensions");
    if (args[1] == "public") run!Executor("public", producers, workers, count);
    else if (args[1] == "internal") run!OwnedTaskExecutor("internal", producers, workers, count);
    else throw new Exception("unknown benchmark arm");
}
