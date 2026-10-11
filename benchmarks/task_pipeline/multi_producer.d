/**
 * R0.5 — real concurrent-producer, mixed-type, GC-visible task pipeline.
 *
 * Both policies perform exactly the same admitted work. The measurements
 * include worker start, multiple producers, backpressure, typed and void
 * completion, producer join, shutdown, and record release.
 */
module concurrency.benchmarks.multi_producer;

import concurrency.internal.owned_task :
    AdmissionProbe,
    OwnedRecordPolicy,
    OwnedTaskExecutor;

import concurrency.benchmarks.thread_resource :
    ThreadResourceSnapshot,
    sampleThreadResources,
    difference;

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

/**
 * Deterministic, input-dependent integer computation. Its result is
 * observed by typed TaskHandles or the void-task checksum.
 * An optimized compiler cannot remove it as dead benchmark work.
 */
private uint computeDigest(uint input, uint rounds)
    @safe pure nothrow @nogc
{
    uint value = input ^ 0x9e3779b9u;
    foreach (_; 0 .. rounds)
    {
        value = (value ^ (value >> 16)) * 0x7feb352du;
        value = (value ^ (value >> 15)) * 0x846ca68bu;
        value ^= value >> 16;
    }
    return value;
}

private struct SmallWork
{
    shared(ulong)* counter;
    int value;
    uint rounds;

    int opCall()
    {
        const supplement = rounds
            ? cast(int)(computeDigest(cast(uint) value, rounds) % 17u)
            : 0;
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
        return value + 1 + supplement;
    }
}

private struct WideWork
{
    shared(ulong)* counter;
    ProducerPayload payload;
    int value;
    uint rounds;

    int opCall()
    {
        const supplement = rounds
            ? cast(int)(computeDigest(cast(uint) value, rounds) % 17u)
            : 0;
        atomicFetchAdd!(MemoryOrder.rel)(*counter, 1UL);
        return value + 1 + payload.bytes[0]
            + cast(int) payload.description.length + supplement;
    }
}

private struct VoidWork
{
    shared(ulong)* counter;
    shared(ulong)* computeChecksum;
    int value;
    uint rounds;

    void opCall()
    {
        if (rounds != 0)
        {
            const digest = computeDigest(cast(uint) value, rounds);
            atomicFetchAdd!(MemoryOrder.rel)(*computeChecksum,
                cast(ulong) digest);
        }
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
    shared(ulong)* producerBytes,
    AdmissionProbe* profile,
    ThreadResourceSnapshot* resources,
    shared(ulong)* computeChecksum,
    uint cpuRounds,
    bool instrumented)
{
    return new Thread({
        const beforeResources = sampleThreadResources();
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
                    work.rounds = cpuRounds;
                    auto handle = instrumented
                        ? executor.submitObserved(work, *profile)
                        : executor.submit(work);

                    if (taskId % 17 == 0)
                    {
                        const supplement = cpuRounds
                            ? cast(int)(computeDigest(
                                cast(uint) value, cpuRounds) % 17u)
                            : 0;
                        if (handle.get() != value + 1 + supplement)
                            throw new Exception("wrong scalar result");
                        atomicFetchAdd!(MemoryOrder.rel)(*observed, 1UL);
                    }
                    break;

                case 1:
                    WideWork work;
                    work.counter = executions;
                    work.value = value;
                    work.payload = payload;
                    auto handle = instrumented
                        ? executor.submitObserved(work, *profile)
                        : executor.submit(work);

                    if (taskId % 17 == 0)
                    {
                        const supplement = cpuRounds
                            ? cast(int)(computeDigest(
                                cast(uint) value, cpuRounds) % 17u)
                            : 0;
                        const expected = value + 1
                            + payload.bytes[0]
                            + cast(int) payload.description.length
                            + supplement;
                        if (handle.get() != expected)
                            throw new Exception("wrong GC-visible result");
                        atomicFetchAdd!(MemoryOrder.rel)(*observed, 1UL);
                    }
                    break;

                case 2:
                    VoidWork work;
                    work.counter = executions;
                    work.computeChecksum = computeChecksum;
                    work.value = value;
                    work.rounds = cpuRounds;
                    auto handle = instrumented
                        ? executor.submitObserved(work, *profile)
                        : executor.submit(work);

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
        // Producer has finished *all* submissions. Save before exiting
        // its OS thread, since RUSAGE_THREAD is not queryable after join.
        *resources = difference(sampleThreadResources(), beforeResources);
    });
}

private ulong upperBucketBound(size_t bucket) @safe pure nothrow @nogc
{
    if (bucket == 0)
        return 0;
    return (1UL << bucket) - 1UL;
}

private ulong percentileUpper(
    ref ulong[64] counts, ulong sampleCount, uint percentile)
{
    if (sampleCount == 0)
        return 0;

    const threshold = (sampleCount * percentile + 99) / 100;
    ulong total;
    foreach (i, count; counts)
    {
        total += count;
        if (total >= threshold)
            return upperBucketBound(i);
    }
    return upperBucketBound(63);
}

private void runCase(
    size_t workers,
    size_t producers,
    size_t tasks,
    size_t budget,
    OwnedRecordPolicy policy,
    bool striped,
    bool instrumented,
    uint cpuRounds)
{
    GC.collect();

    const usedBefore = GC.stats().usedSize;
    const start = MonoTime.currTime;

    shared ulong executions;
    shared ulong admitted;
    shared ulong observed;
    shared ulong computeChecksum;

    // Separate counter slot per producer. Read only after its Thread.join.
    auto producerBytes = new shared ulong[producers];
    auto threads = new Thread[producers];
    // 16 ulong elements = 128 bytes between producer counters.
    // This reduces cache-line ping-pong between *different* producer
    // task streams, without removing atomic work from the task body.
    auto stripes = new shared ulong[producers * 16];
    auto profiles = new AdmissionProbe[producers];
    auto resources = new ThreadResourceSnapshot[producers];

    auto executor = new OwnedTaskExecutor(
        workers, 64, budget, policy);

    foreach (i; 0 .. producers)
    {
        auto target = striped ? &stripes[i * 16] : &executions;
        threads[i] = makeProducer(
            executor, i, producers, tasks, target,
            &admitted, &observed, &producerBytes[i],
            &profiles[i], &resources[i],
            &computeChecksum, cpuRounds, instrumented);
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

    ulong executed = atomicLoad!(MemoryOrder.acq)(executions);
    if (striped)
    {
        executed = 0;
        foreach (i; 0 .. producers)
            executed += atomicLoad!(MemoryOrder.acq)(stripes[i * 16]);
    }

    // Runtime error checks survive optimized release builds.
    if (accepted != tasks || completed != tasks ||
        executed != tasks ||
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

    if (cpuRounds != 0)
    {
        ulong expectedChecksum;
        foreach (i; 0 .. tasks)
        {
            if (i % 3 == 2)
                expectedChecksum += computeDigest(cast(uint) i, cpuRounds);
        }
        if (atomicLoad!(MemoryOrder.acq)(computeChecksum) != expectedChecksum)
            throw new Exception("wrong compute workload checksum");
    }

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
        "multi,mixed,%s,%s,%s,%s,%s,%.3f,%.1f,%s,%s,%s,%s,%s,%s,%s",
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

    // Resource snapshots are read only after joining their producer
    // threads. All samples are taken at thread boundaries, not in the
    // admission hot path, for both profiled and unprofiled modes.
    ThreadResourceSnapshot producerTotal;
    foreach (item; resources)
    {
        producerTotal.cpuUserUs += item.cpuUserUs;
        producerTotal.cpuSystemUs += item.cpuSystemUs;
        producerTotal.voluntarySwitches += item.voluntarySwitches;
        producerTotal.involuntarySwitches += item.involuntarySwitches;
        producerTotal.minorFaults += item.minorFaults;
        producerTotal.majorFaults += item.majorFaults;
    }
    writefln(
        "resource,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        policyName(policy),
        striped ? "striped" : "shared",
        workers, producers, budget, tasks,
        producerTotal.cpuUserUs, producerTotal.cpuSystemUs,
        producerTotal.voluntarySwitches,
        producerTotal.involuntarySwitches,
        producerTotal.minorFaults, producerTotal.majorFaults);

    writefln("workload,%s,%s,%s",
        cpuRounds == 0 ? "minimal" : "compute",
        cpuRounds,
        atomicLoad!(MemoryOrder.acq)(computeChecksum));

    if (instrumented)
    {
        AdmissionProbe merged;
        foreach (ref profile; profiles)
        {
            merged.attempts += profile.attempts;
            merged.accepted += profile.accepted;
            merged.retentionFull += profile.retentionFull;
            merged.ingressFull += profile.ingressFull;
            merged.yields += profile.yields;
            merged.mutexWaitNs += profile.mutexWaitNs;
            merged.mutexHoldNs += profile.mutexHoldNs;
            if (profile.maxWaitNs > merged.maxWaitNs)
                merged.maxWaitNs = profile.maxWaitNs;
            if (profile.maxHoldNs > merged.maxHoldNs)
                merged.maxHoldNs = profile.maxHoldNs;

            foreach (i; 0 .. 64)
            {
                merged.waitBuckets[i] += profile.waitBuckets[i];
                merged.holdBuckets[i] += profile.holdBuckets[i];
            }
        }

        if (merged.accepted != tasks ||
            merged.attempts != merged.accepted +
                merged.retentionFull + merged.ingressFull ||
            merged.yields != merged.retentionFull + merged.ingressFull)
            throw new Exception("invalid admission probe accounting");

        writefln(
            "admission,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
            policyName(policy),
            striped ? "striped" : "shared",
            producers, workers, budget, tasks,
            merged.attempts, merged.accepted,
            merged.retentionFull, merged.ingressFull,
            merged.yields, merged.mutexWaitNs, merged.mutexHoldNs,
            merged.maxWaitNs, merged.maxHoldNs,
            percentileUpper(merged.waitBuckets, merged.attempts, 50),
            percentileUpper(merged.waitBuckets, merged.attempts, 95),
            percentileUpper(merged.waitBuckets, merged.attempts, 99),
            percentileUpper(merged.holdBuckets, merged.attempts, 50),
            percentileUpper(merged.holdBuckets, merged.attempts, 95),
            percentileUpper(merged.holdBuckets, merged.attempts, 99));
    }
}

void main(string[] args)
{
    size_t workers = 4;
    size_t producers = 4;
    size_t tasks = 6000;
    size_t budget = 64;
    string policyNameArg = "gc";
    string counterMode = "shared";
    string instrumentation = "off";
    string workload = "minimal";

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
    if (args.length > 6)
        counterMode = args[6];
    if (args.length > 7)
        instrumentation = args[7];
    if (args.length > 8)
        workload = args[8];

    if (workers == 0 || workers > 64 ||
        producers == 0 || producers > 64 ||
        tasks == 0 || tasks > 2_000_000 ||
        (budget != 8 && budget != 64 &&
         budget != 512 && budget != 4096))
        throw new Exception("invalid worker/producer/task/budget count");

    if (policyNameArg != "gc" && policyNameArg != "recycle")
        throw new Exception("policy must be gc or recycle");
    if (counterMode != "shared" && counterMode != "striped")
        throw new Exception("counter mode must be shared or striped");
    if (instrumentation != "on" && instrumentation != "off")
        throw new Exception("instrumentation must be on or off");
    if (workload != "minimal" && workload != "compute")
        throw new Exception("workload must be minimal or compute");

    const policy = policyNameArg == "gc"
        ? OwnedRecordPolicy.freshGc
        : OwnedRecordPolicy.recycleTyped;

    writefln(
        "metric,scenario,policy,workers,producers,budget,tasks,"
        ~ "elapsed_ms,throughput_per_s,fresh_nodes,reused_nodes,"
        ~ "producer_gc_bytes,used_close_delta,used_after_collect_delta,"
        ~ "observed_handles,completed");

    runCase(workers, producers, tasks, budget, policy,
        counterMode == "striped", instrumentation == "on",
        workload == "compute" ? 96u : 0u);
}
