/**
 * R0.5 research-only zero-work CPU and idle-to-task result-latency probe.
 *
 * This benchmark intentionally creates an executor before accounting begins.
 * It does not exercise multi-producer throughput. The timed quantity starts
 * before submit() and ends only after a typed result becomes observable.
 */
module concurrency.benchmarks.notification_latency;

import concurrency.internal.owned_task :
    OwnedRecordPolicy,
    OwnedTaskExecutor;
import concurrency.internal.submission_pool :
    NotificationPolicy;

import core.sys.posix.sys.resource :
    getrusage,
    rusage;
import core.thread : Thread;
import core.time : dur, MonoTime, ticksToNSecs;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.stdio : writefln;

private ulong processCpuUs()
{
    rusage usage;
    if (getrusage(0, &usage) != 0)
        throw new Exception("getrusage(RUSAGE_SELF) failed");

    return cast(ulong) usage.ru_utime.tv_sec * 1_000_000UL
         + cast(ulong) usage.ru_utime.tv_usec
         + cast(ulong) usage.ru_stime.tv_sec * 1_000_000UL
         + cast(ulong) usage.ru_stime.tv_usec;
}

private ulong nearestRank(const(ulong)[] samples, size_t percentage)
{
    size_t pos = (samples.length * percentage + 99) / 100;
    if (pos == 0)
        pos = 1;
    return samples[pos - 1];
}

void main(string[] args)
{
    size_t workers = 4;
    size_t idleMilliseconds = 100;
    size_t samples = 128;
    size_t gapMilliseconds = 1;
    string notifyMode = "always";
    if (args.length > 1)
        workers = to!size_t(args[1]);
    if (args.length > 2)
        notifyMode = args[2];
    if (args.length > 3)
        idleMilliseconds = to!size_t(args[3]);
    if (args.length > 4)
        samples = to!size_t(args[4]);
    if (args.length > 5)
        gapMilliseconds = to!size_t(args[5]);

    if (workers == 0 || workers > 64 ||
        idleMilliseconds == 0 || idleMilliseconds > 10_000 ||
        samples == 0 || samples > 10_000 ||
        gapMilliseconds == 0 || gapMilliseconds > 100 ||
        (notifyMode != "always" && notifyMode != "waiter"))
        throw new Exception("invalid notification-latency parameters");

    auto policy = notifyMode == "waiter"
        ? NotificationPolicy.waiterAware : NotificationPolicy.always;
    auto elapsedNs = new ulong[samples];

    // No storage policy change between compared cases.
    auto executor = new OwnedTaskExecutor(
        workers, 64, 512, OwnedRecordPolicy.freshGc, false, policy);

    // Observe idle CPU *after* all workers were started, excluding
    // thread construction from the idle interval.
    const idleCpuStart = processCpuUs();
    const idleWallStart = MonoTime.currTime.ticks;
    Thread.sleep(dur!"msecs"(idleMilliseconds));
    const idleWallEnd = MonoTime.currTime.ticks;
    const idleCpuEnd = processCpuUs();

    foreach (i; 0 .. samples)
    {
        // Allow idle->wake transitions between samples. This is
        // intentionally a low-arrival-rate responsiveness probe.
        Thread.sleep(dur!"msecs"(gapMilliseconds));
        const start = MonoTime.currTime.ticks;
        auto handle = executor.submit(() => 42);
        if (handle.get() != 42)
            throw new Exception("incorrect typed task result");
        elapsedNs[i] = cast(ulong) ticksToNSecs(
            MonoTime.currTime.ticks - start);
    }

    executor.closeAndJoin();
    if (executor.acceptedCount() != samples ||
        executor.completedCount() != samples)
        throw new Exception("missing idle-to-work completion");

    sort(elapsedNs);
    writefln("latency,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        notifyMode, workers, idleMilliseconds, samples,
        gapMilliseconds,
        idleCpuEnd - idleCpuStart,
        ticksToNSecs(idleWallEnd - idleWallStart),
        nearestRank(elapsedNs, 50),
        nearestRank(elapsedNs, 95),
        nearestRank(elapsedNs, 99),
        elapsedNs[$ - 1],
        executor.completedCount());
}
