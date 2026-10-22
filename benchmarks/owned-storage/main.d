/** Public-path diagnostic for the GC-owned task records used by Executor. */
module concurrency.benchmarks.owned_storage;

import concurrency : Executor, TaskHandle;
import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.memory : GC;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private int kernel(int input) @safe pure nothrow @nogc
{
    int value = input;
    foreach (i; 0 .. 32)
        value = (value * 17 + i) ^ (value >>> 3);
    return value;
}

private struct TinyJob
{
    int input;
    int opCall() { return kernel(input); }
}

private struct LargeJob
{
    int input;
    long[64] context;
    int opCall() { return kernel(input) ^ cast(int) context[input & 63]; }
}

private final class Graph
{
    int value;
    Graph next;
    this(int value, Graph next = null) { this.value = value; this.next = next; }
}

private struct GraphJob
{
    int input;
    Graph graph;
    int opCall()
    {
        int sum;
        for (auto node = graph; node !is null; node = node.next)
            sum += node.value;
        return kernel(input) ^ sum;
    }
}

private final class Gate
{
    shared uint entered;
    shared uint released;

    void wait()
    {
        atomicStore!(MemoryOrder.rel)(entered, 1u);
        while (atomicLoad!(MemoryOrder.acq)(released) == 0u) Thread.yield();
    }

    void waitUntilEntered()
    {
        const deadline = MonoTime.currTime + dur!"seconds"(10);
        while (atomicLoad!(MemoryOrder.acq)(entered) == 0u)
        {
            enforce(MonoTime.currTime < deadline,
                "retention blocker did not start");
            Thread.yield();
        }
    }

    void release() { atomicStore!(MemoryOrder.rel)(released, 1u); }
}

private struct Blocker { Gate gate; void opCall() { gate.wait(); } }

private long elapsed(long start, long finish)
{
    enforce(finish >= start, "monotonic clock moved backwards");
    return ticksToNSecs(finish - start);
}

private Graph graphFor(size_t i)
{
    return new Graph(cast(int) i + 3,
        new Graph(cast(int) i + 5, new Graph(cast(int) i + 7)));
}

private J makeJob(J)(size_t i)
{
    J job;
    job.input = cast(int) i - 300;
    static if (is(J == LargeJob))
    {
        foreach (slot, ref value; job.context)
            value = cast(long)(i * 17 + slot);
    }
    else static if (is(J == GraphJob))
        job.graph = graphFor(i);
    return job;
}

private int expected(J)(size_t i)
{
    const input = cast(int) i - 300;
    static if (is(J == TinyJob))
        return kernel(input);
    else static if (is(J == LargeJob))
    {
        const slot = cast(size_t)(input & 63);
        return kernel(input) ^ cast(int)(i * 17 + slot);
    }
    else static if (is(J == GraphJob))
        return kernel(input) ^ cast(int)(3 * i + 15);
    else
        static assert(false, "unsupported benchmark job");
}

private struct TimedSample
{
    string kind;
    size_t count;
    size_t workers;
    long constructNs, submitNs, resultsNs, shutdownNs, collectNs, totalNs;
    ulong producerAllocatedBytes;
    size_t usedBefore, usedAfter;
    long checksum;
}

private TimedSample timed(J)(string kind, size_t count, size_t workers)
{
    GC.collect();
    const usedBefore = GC.stats().usedSize;
    const producerBefore = GC.allocatedInCurrentThread();
    const start = MonoTime.currTime.ticks;
    auto executor = new Executor(workers, count, count);
    const constructed = MonoTime.currTime.ticks;

    TaskHandle!int[] handles;
    handles.reserve(count);
    foreach (i; 0 .. count)
    {
        auto job = makeJob!J(i);
        handles ~= executor.submit(job);
    }
    const submitted = MonoTime.currTime.ticks;

    long checksum;
    foreach (i, handle; handles)
    {
        const value = handle.get();
        enforce(value == expected!J(i), "public storage result mismatch");
        checksum += value;
    }
    const results = MonoTime.currTime.ticks;
    executor.closeAndJoin();
    const stopped = MonoTime.currTime.ticks;
    const producerAfter = GC.allocatedInCurrentThread();

    handles = null;
    executor = null;
    GC.collect();
    const collected = MonoTime.currTime.ticks;

    TimedSample sample;
    sample.kind = kind;
    sample.count = count;
    sample.workers = workers;
    sample.constructNs = elapsed(start, constructed);
    sample.submitNs = elapsed(constructed, submitted);
    sample.resultsNs = elapsed(submitted, results);
    sample.shutdownNs = elapsed(results, stopped);
    sample.collectNs = elapsed(stopped, collected);
    sample.totalNs = elapsed(start, collected);
    sample.producerAllocatedBytes = producerAfter - producerBefore;
    sample.usedBefore = usedBefore;
    sample.usedAfter = GC.stats().usedSize;
    sample.checksum = checksum;
    return sample;
}

private struct RetentionSample
{
    size_t before;
    size_t after;
}

private RetentionSample retainedBytes(J)(size_t count)
{
    GC.collect();
    const before = GC.stats().usedSize;
    auto executor = new Executor(1, count + 1, count + 1);
    auto gate = new Gate;
    Blocker blocker;
    blocker.gate = gate;
    auto blocked = executor.submit(blocker);
    gate.waitUntilEntered();

    foreach (i; 0 .. count)
    {
        auto job = makeJob!J(i);
        auto dropped = executor.submit(job);
        dropped = null;
    }

    // Dropped handles cannot provide ownership here: Executor must retain
    // queued nodes and every GraphJob's transitive class graph. The GC can
    // also conservatively observe stale stack words, so byte counts alone
    // are not a proof of unique roots.
    GC.collect();
    const retained = GC.stats().usedSize;
    gate.release();
    executor.closeAndJoin();
    blocked.get();
    RetentionSample sample;
    sample.before = before;
    sample.after = retained;
    return sample;
}

private void emit(TimedSample sample, RetentionSample retained)
{
    writeln(sample.kind, ",", sample.count, ",", sample.workers, ",",
        sample.constructNs, ",", sample.submitNs, ",", sample.resultsNs, ",",
        sample.shutdownNs, ",", sample.collectNs, ",", sample.totalNs, ",",
        sample.producerAllocatedBytes, ",", sample.usedBefore, ",",
        sample.usedAfter, ",", retained.before, ",", retained.after, ",",
        sample.checksum);
}

void main(string[] args)
{
    enforce(args.length == 4,
        "usage: concurrency-owned-storage-benchmark COUNT WORKERS ROUNDS");
    const count = to!size_t(args[1]);
    const workers = to!size_t(args[2]);
    const rounds = to!size_t(args[3]);
    enforce(count > 0 && workers > 0 && rounds > 0,
        "COUNT, WORKERS and ROUNDS must be positive");

    writeln("kind,count,workers,construct_ns,submit_ns,results_ns,shutdown_ns,",
        "collect_ns,total_ns,producer_allocated_bytes,used_before,used_after,",
        "retained_used_before,retained_used_after,checksum");

    foreach (round; 0 .. rounds)
    {
        foreach (offset; 0 .. 3)
        {
            final switch ((round + offset) % 3)
            {
                case 0: emit(timed!TinyJob("tiny", count, workers),
                    retainedBytes!TinyJob(count)); break;
                case 1: emit(timed!LargeJob("large", count, workers),
                    retainedBytes!LargeJob(count)); break;
                case 2: emit(timed!GraphJob("graph", count, workers),
                    retainedBytes!GraphJob(count)); break;
            }
        }
    }
}
