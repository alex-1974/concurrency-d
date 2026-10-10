/**
 * R0.5 — real concurrent-producer, mixed-type, GC-visible task pipeline.
 *
 * Both policies perform exactly the same admitted work. The measurements
 * include worker start, multiple producers, backpressure, typed and void
 * completion, producer join, shutdown, and record release.
 */
module concurrency.benchmarks.multi_producer;

import concurrency.internal.owned_task :
    OwnedRecordPolicy,
    OwnedTaskExecutor;

import core.atomic :
    MemoryOrder,
    atomicFetchAdd,
    atomicLoad,
    atomicStore;

import core.memory :
    GC;

import core.thread :
    Thread;

import core.time :
    MonoTime,
    ticksToNSecs;

import std.conv :
    to;

import std.stdio :
    writefln;

private final class ProducerPayload
{
    string description;
    ubyte[256] bytes;

    this()
    {
        description = "R0.5 mixed GC-reachable callable";
        bytes[0] = 7;
    }
}

private struct SmallWork
{
    shared(ulong)* counter;
    int value;

    int opCall()
    {
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
        return value + 1;
    }
}

private struct WideWork
{
    shared(ulong)* counter;
    ProducerPayload payload;
    int value;

    int opCall()
    {
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
        return value + 1 + payload.bytes[0]
            + cast(int) payload.description.length;
    }
}

private struct VoidWork
{
    shared(ulong)* counter;

    void opCall()
    {
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
    }
}

private string policyName(OwnedRecordPolicy policy)
{
    return policy == OwnedRecordPolicy.freshGc ? "gc" : "recycle";
}

// One function invocation produces exactly one environment per thread.
// Capturing a shared outer foreach index is NOT a valid worker identity.
private Thread makeProducer(
    OwnedTaskExecutor executor,
    size_t producerId,
    size_t producerCount,
    size_t totalTasks,
    shared(ulong)* executions,
    shared(ulong)* admitted,
    shared(ulong)* observed,
    shared(ulong)* producerBytes)
{
    return new Thread({
        auto payload = new ProducerPayload();
        const beforeBytes = GC.allocatedInCurrentThread();

        for (size_t taskId = producerId;
             taskId < totalTasks;
             taskId += producerCount)
        {
            const value = cast(int) taskId;

            switch (taskId % 3)
            {
                case 0:
                    SmallWork work;
                    work.counter = executions;
                    work.value = value;
                    auto handle = executor.submit(work);

                    if (taskId % 17 == 0)
                    {
                        if (handle.get() != value + 1)
                            throw new Exception("wrong scalar result");
                        atomicFetchAdd!(MemoryOrder.rel)(*observed, 1UL);
                    }
                    break;

                case 1:
                    WideWork work;
                    work.counter = executions;
                    work.value = value;
                    work.payload = payload;
                    auto handle = executor.submit(work);

                    if (taskId % 17 == 0)
                    {
                        const expected = value + 1
                            + payload.bytes[0]
                            + cast(int) payload.description.length;
                        if (handle.get() != expected)
                            throw new Exception("wrong GC-visible result");
                        atomicFetchAdd!(MemoryOrder.rel)(*observed, 1UL);
                    }
                    break;

                case 2:
                    VoidWork work;
                    work.counter = executions;
                    auto handle = executor.submit(work);

                    if (taskId % 17 == 0)
                    {
                        handle.get();
                        atomicFetchAdd!(MemoryOrder.rel)(*observed, 1UL);
                    }
                    break;

                default:
                    throw new Exception("unexpected task type");
            }

            atomicFetchAdd!(MemoryOrder.rel)(*admitted, 1UL);
        }

        const afterBytes = GC.allocatedInCurrentThread();
        atomicStore!(MemoryOrder.rel)(
            *producerBytes, afterBytes - beforeBytes);
    });
}

private void runCase(
    size_t workers,
    size_t producers,
    size_t tasks,
    size_t budget,
    OwnedRecordPolicy policy)
{
    GC.collect();

    const usedBefore = GC.stats().usedSize;
    const start = MonoTime.currTime;

    shared ulong executions;
    shared ulong admitted;
    shared ulong observed;

    // Separate counter slot per producer. Read only after its Thread.join.
    auto producerBytes = new shared ulong[producers];
    auto threads = new Thread[producers];

    auto executor = new OwnedTaskExecutor(
        workers, 64, budget, policy);

    foreach (i; 0 .. producers)
    {
        threads[i] = makeProducer(
            executor, i, producers, tasks, &executions,
            &admitted, &observed, &producerBytes[i]);
        threads[i].start();
    }

    foreach (thread; threads)
        thread.join();

    executor.closeAndJoin();
    const elapsedNs = ticksToNSecs(
        MonoTime.currTime.ticks - start.ticks);

    const usedAtClose = GC.stats().usedSize;
    const fresh = executor.freshNodeCount();
    const reused = executor.reusedNodeCount();
    const accepted = executor.acceptedCount();
    const completed = executor.completedCount();

    // Runtime error checks survive optimized release builds.
    if (accepted != tasks || completed != tasks ||
        atomicLoad!(MemoryOrder.acq)(executions) != tasks ||
        atomicLoad!(MemoryOrder.acq)(admitted) != tasks ||
        executor.retainedCount() != 0 ||
        executor.spareCount() != 0)
    {
        throw new Exception("mixed multi-producer completion mismatch");
    }

    size_t expectedObservations;
    foreach (i; 0 .. tasks)
    {
        if (i % 17 == 0)
            ++expectedObservations;
    }

    if (atomicLoad!(MemoryOrder.acq)(observed) != expectedObservations)
        throw new Exception("mixed multi-producer result mismatch");

    ulong allocatedInProducers;
    foreach (i; 0 .. producers)
    {
        allocatedInProducers += atomicLoad!(MemoryOrder.acq)(
            producerBytes[i]);
    }

    // Post-join collection is an additional heap retention diagnostic,
    // deliberately excluded from the pipeline timing.
    GC.collect();
    const usedAfterCollect = GC.stats().usedSize;

    const seconds = cast(double) elapsedNs / 1_000_000_000.0;
    const long closeUsedDelta =
        cast(long) usedAtClose - cast(long) usedBefore;
    const long collectedUsedDelta =
        cast(long) usedAfterCollect - cast(long) usedBefore;

    writefln(
        "multi,mixed,%s,%s,%s,%s,%s,%.3f,%.1f,%s,%s,%s,%s,%s,%s",
        policyName(policy), workers, producers, budget, tasks,
        cast(double) elapsedNs / 1_000_000.0,
        cast(double) tasks / seconds,
        fresh,
        reused,
        allocatedInProducers,
        closeUsedDelta,
        collectedUsedDelta,
        expectedObservations,
        completed);
}

void main(string[] args)
{
    size_t workers = 4;
    size_t producers = 4;
    size_t tasks = 6000;
    size_t budget = 64;
    string policyNameArg = "gc";

    if (args.length > 1)
        workers = to!size_t(args[1]);
    if (args.length > 2)
        producers = to!size_t(args[2]);
    if (args.length > 3)
        tasks = to!size_t(args[3]);
    if (args.length > 4)
        budget = to!size_t(args[4]);
    if (args.length > 5)
        policyNameArg = args[5];

    if (workers == 0 || workers > 64 ||
        producers == 0 || producers > 64 ||
        tasks == 0 || tasks > 2_000_000 ||
        (budget != 8 && budget != 64 &&
         budget != 512 && budget != 4096))
        throw new Exception("invalid worker/producer/task/budget count");

    if (policyNameArg != "gc" && policyNameArg != "recycle")
        throw new Exception("policy must be gc or recycle");

    const policy = policyNameArg == "gc"
        ? OwnedRecordPolicy.freshGc
        : OwnedRecordPolicy.recycleTyped;

    writefln(
        "metric,scenario,policy,workers,producers,budget,tasks,"
        ~ "elapsed_ms,throughput_per_s,fresh_nodes,reused_nodes,"
        ~ "producer_gc_bytes,used_close_delta,used_after_collect_delta,"
        ~ "observed_handles,completed");

    runCase(workers, producers, tasks, budget, policy);
}
