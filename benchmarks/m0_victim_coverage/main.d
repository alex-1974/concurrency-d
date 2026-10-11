/**
 * Identical external benchmark consumer for the M0 full-victim-coverage fix.
 *
 * This source is injected unmodified into TWO temporary git worktrees
 * checked out at the exact develop and fix commit SHAs. It is NOT taken
 * from either candidate implementation. M0 has borrowed TaskRefs, so
 * all record storage outlives closeAndJoin. No R0.5 owned-task API.
 */
module concurrency.internal.victim_coverage_benchmark;

import concurrency.internal.submission_pool :
    SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;

import core.atomic :
    MemoryOrder, atomicLoad, atomicStore, atomicFetchAdd;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;
import core.sys.posix.sys.resource : getrusage, rusage;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.stdio : writefln;

private struct BenchRecord
{
    TaskHeader header;
    size_t id;
    uint rounds;
    shared uint executions;
    shared ulong result;
}

private ulong kernel(size_t id, uint rounds) @nogc nothrow pure
{
    ulong x = cast(ulong) id ^ 0x9e3779b97f4a7c15UL;
    foreach (i; 0 .. rounds)
    {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x += cast(ulong) i * 0xd6e8feb86659fd93UL;
    }
    return x;
}

private void execute(shared(TaskHeader)* header) @trusted @nogc nothrow
{
    auto record = cast(shared(BenchRecord)*) header;
    const value = kernel(record.id, record.rounds);
    atomicStore!(MemoryOrder.rel)(record.result, value);
    atomicFetchAdd!(MemoryOrder.rel)(record.executions, 1u);
}

private void prepare(shared BenchRecord[] records, TaskRef[] tasks,
                     uint rounds)
{
    assert(records.length == tasks.length);
    foreach (i; 0 .. tasks.length)
    {
        records[i].header.execute = &execute;
        records[i].id = i + 1;
        records[i].rounds = rounds;
        records[i].executions = 0;
        records[i].result = 0;
        tasks[i] = TaskRef(&records[i].header);
    }
}

private ulong validate(shared BenchRecord[] records)
{
    ulong total;
    foreach (i; 0 .. records.length)
    {
        if (atomicLoad!(MemoryOrder.acq)(records[i].executions) != 1u)
            throw new Exception("task not executed exactly once");
        const got = atomicLoad!(MemoryOrder.acq)(records[i].result);
        const expected = kernel(i + 1, records[i].rounds);
        if (got != expected)
            throw new Exception("incorrect task result");
        total += got;
    }
    return total;
}

// Producer-local invocation frame, avoiding captured foreach variable aliasing.
private Thread makeProducer(SubmissionWorkerPool pool, TaskRef[] tasks,
                            size_t producer, size_t totalProducers,
                            size_t[] rejected)
{
    return new Thread({
        size_t retries;
        for (size_t i = producer; i < tasks.length; i += totalProducers)
        {
            for (;;)
            {
                const state = pool.trySubmit(tasks[i]);
                if (state == SubmissionResult.accepted)
                    break;
                if (state != SubmissionResult.full)
                    throw new Exception("unexpected closed ingress");
                ++retries;
                Thread.yield();
            }
        }
        rejected[producer] = retries;
    });
}

private ulong microseconds(rusage usage)
{
    return cast(ulong) usage.ru_utime.tv_sec * 1_000_000UL
         + cast(ulong) usage.ru_utime.tv_usec
         + cast(ulong) usage.ru_stime.tv_sec * 1_000_000UL
         + cast(ulong) usage.ru_stime.tv_usec;
}

private ulong percentile(const(ulong)[] sorted, size_t p)
{
    const rank = (sorted.length * p + 99) / 100;
    return sorted[rank ? rank - 1 : 0];
}

private void mixed(size_t workers, size_t producers, size_t count,
                   size_t budget, uint rounds)
{
    if (workers == 0 || workers > 32 || producers == 0 ||
        producers > 32 || count < 1 || count > 500_000 ||
        budget == 0 || budget > 4096 || rounds > 4096)
        throw new Exception("invalid mixed benchmark parameters");

    auto records = new shared BenchRecord[count];
    auto tasks = new TaskRef[count];
    prepare(records, tasks, rounds);
    auto pool = new SubmissionWorkerPool(workers, budget);

    auto rejected = new size_t[producers];
    auto threads = new Thread[producers];
    foreach (i; 0 .. producers)
        threads[i] = makeProducer(pool, tasks, i, producers, rejected);

    const begin = MonoTime.currTime.ticks;
    foreach (t; threads)
        t.start();
    foreach (t; threads)
        t.join();
    pool.closeAndJoin();
    const elapsed = cast(ulong) ticksToNSecs(
        MonoTime.currTime.ticks - begin);

    if (pool.acceptedCount() != count || pool.completedCount() != count)
        throw new Exception("mixed accepted/completed mismatch");

    const result = validate(records); // Outside measured critical path.
    size_t retries;
    foreach (r; rejected)
        retries += r;
    // CSV: kind,workers,producers,tasks,budget,rounds,elapsed_ns,
    // accepted,completed,retries,checksum.
    writefln("mixed,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        workers, producers, count, budget, rounds, elapsed,
        pool.acceptedCount(), pool.completedCount(), retries, result);
}

private void idle(size_t workers, size_t millis, size_t samples,
                  size_t gapMs)
{
    if (workers == 0 || workers > 32 ||
        millis < 100 || millis > 10000 ||
        samples < 8 || samples > 1000 ||
        gapMs == 0 || gapMs > 100)
        throw new Exception("invalid idle benchmark parameters");

    auto records = new shared BenchRecord[samples];
    auto tasks = new TaskRef[samples];
    prepare(records, tasks, 0);
    auto durations = new ulong[samples];
    auto pool = new SubmissionWorkerPool(workers, 64);

    // The quiet interval starts AFTER the worker threads were created.
    // No producer thread runs during this interval.
    rusage beforeCpu, afterCpu;
    if (getrusage(0, &beforeCpu) != 0)
        throw new Exception("getrusage before idle failed");
    const before = MonoTime.currTime.ticks;
    Thread.sleep(dur!"msecs"(millis));
    const after = MonoTime.currTime.ticks;
    if (getrusage(0, &afterCpu) != 0)
        throw new Exception("getrusage after idle failed");
    const idleCpu = microseconds(afterCpu) - microseconds(beforeCpu);
    const idleWall = cast(ulong) ticksToNSecs(after - before);

    foreach (i; 0 .. samples)
    {
        Thread.sleep(dur!"msecs"(gapMs));
        const begin = MonoTime.currTime.ticks;
        if (pool.trySubmit(tasks[i]) != SubmissionResult.accepted)
            throw new Exception("idle submit was not accepted");
        // The controlling thread yields rather than spinning at 100% CPU.
        // This is a scheduler-dependent *response* probe, not a real-time SLA.
        while (atomicLoad!(MemoryOrder.acq)(records[i].executions) != 1u)
        {
            if (ticksToNSecs(MonoTime.currTime.ticks - begin) >
                5_000_000_000L)
                throw new Exception("idle wake timeout");
            Thread.yield();
        }
        durations[i] = cast(ulong) ticksToNSecs(
            MonoTime.currTime.ticks - begin);
    }
    pool.closeAndJoin();

    if (pool.acceptedCount() != samples ||
        pool.completedCount() != samples)
        throw new Exception("idle accepted/completed mismatch");
    const checksum = validate(records);
    sort(durations);

    // CSV: kind,workers,idle_ms,samples,gap_ms,idle_cpu_us,
    // idle_wall_ns,p50_ns,p95_ns,p99_ns,max_ns,completed,checksum.
    writefln("idle,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        workers, millis, samples, gapMs, idleCpu, idleWall,
        percentile(durations, 50), percentile(durations, 95),
        percentile(durations, 99), durations[$ - 1],
        pool.completedCount(), checksum);
}

void main(string[] args)
{
    if (args.length < 2)
        throw new Exception("expected mode mixed|idle");
    if (args[1] == "mixed" && args.length == 7)
        mixed(to!size_t(args[2]), to!size_t(args[3]),
              to!size_t(args[4]), to!size_t(args[5]),
              to!uint(args[6]));
    else if (args[1] == "idle" && args.length == 6)
        idle(to!size_t(args[2]), to!size_t(args[3]),
             to!size_t(args[4]), to!size_t(args[5]));
    else
        throw new Exception("invalid mode/argument count");
}
