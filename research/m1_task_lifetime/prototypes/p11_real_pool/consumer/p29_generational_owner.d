/++
 P29 bounded generational management of real M0 OwnedTaskExecutor.
 Research only. Slot index alone is never a public owner identity.
 Explicit handoff; no GC-finalizer detection or general @safe API.
+/
module concurrency.research.p29_generational_owner;

import concurrency.research.m1_p23_owned : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.memory : GC;
import core.stdc.stdio : fprintf, fflush, stderr;
import core.stdc.stdlib : abort;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;
version (P30Benchmark)
{
    import concurrency.internal.owned_task :
        OriginalExecutor = OwnedTaskExecutor;
    import std.conv : to;
}

version (P31Benchmark)
{
    import concurrency.internal.owned_task :
        OriginalExecutor = OwnedTaskExecutor;
    import std.conv : to;
}

private void check(bool correct, string reason)
{
    if (!correct)
        throw new Exception("P29: " ~ reason);
}

private enum Phase : ubyte
{
    vacant, reserved, starting, active, orphaned, draining, uncertain, joined
}

private struct OwnerHandle
{
    size_t slot;
    ulong generation;
}

private struct Entry
{
    OwnedTaskExecutor executor;
    ulong generation;
    Phase phase;
    bool abandoned;
    size_t operations;
}

private final class GenerationalManager
{
    private enum size_t Capacity = 2;
    private Mutex mutex;
    private Entry[Capacity] entries;
    private size_t installed;
    private size_t removed;
    private size_t denied;
    private size_t joinClaims;

    this() { mutex = new Mutex(); }

    private bool matches(OwnerHandle h)
    {
        return h.generation != 0 && h.slot < Capacity &&
            entries[h.slot].generation == h.generation &&
            entries[h.slot].phase != Phase.vacant;
    }

    bool enroll(OwnedTaskExecutor candidate, out OwnerHandle h) @system
    {
        check(candidate !is null && candidate.researchConstructed(),
            "enroll requires unstarted owner");
        h = OwnerHandle.init;
        synchronized (mutex)
        {
            foreach (i; 0 .. Capacity)
            {
                auto e = &entries[i];
                if (e.phase != Phase.vacant)
                    continue;
                // Generation must never wrap and resurrect stale handles.
                if (e.generation == ulong.max)
                    abort();
                GC.addRoot(cast(void*) candidate);
                ++e.generation;
                e.executor = candidate;
                e.phase = Phase.reserved;
                e.abandoned = false;
                e.operations = 0;
                ++installed;
                h = OwnerHandle(i, e.generation);
                return true;
            }
            ++denied;
        }
        return false;
    }

    bool start(OwnerHandle h) @system
    {
        OwnedTaskExecutor owner;
        synchronized (mutex)
        {
            if (!matches(h) || entries[h.slot].phase != Phase.reserved)
                return false;
            auto e = &entries[h.slot];
            e.phase = Phase.starting;
            owner = e.executor;
        }
        try owner.researchStart();
        catch (Throwable) abort(); // real postlaunch ambiguity: fail-stop
        synchronized (mutex)
        {
            check(matches(h) && entries[h.slot].phase == Phase.starting,
                "native start changed generation or owner state");
            entries[h.slot].phase =
                owner.researchUncertain() ? Phase.uncertain : Phase.active;
        }
        return true;
    }

    // Original M0 admission is the only task-queue operation. The
    // temporary registry operation count does NOT instrument worker
    // dispatch, deque pop, steal, park or completion hot paths.
    bool publish(F)(OwnerHandle h, F work)
    {
        OwnedTaskExecutor owner;
        synchronized (mutex)
        {
            if (!matches(h) || entries[h.slot].phase != Phase.active)
                return false;
            ++entries[h.slot].operations;
            owner = entries[h.slot].executor;
        }

        bool accepted;
        try
        {
            auto result = owner.trySubmit(work);
            accepted = result !is null;
            result = null;
        }
        catch (Exception)
        {
            // M0 close may linearize earlier than the submission.
        }
        catch (Throwable)
            abort();

        synchronized (mutex)
        {
            if (!matches(h) || entries[h.slot].operations == 0)
                abort();
            --entries[h.slot].operations;
        }
        return accepted;
    }

    bool orphan(OwnerHandle h)
    {
        synchronized (mutex)
        {
            if (!matches(h))
                return false;
            auto e = &entries[h.slot];
            if (e.abandoned || (e.phase != Phase.active &&
                                e.phase != Phase.uncertain))
                return false;
            e.abandoned = true;
            if (e.phase == Phase.active)
                e.phase = Phase.orphaned;
            return true;
        }
    }

    bool joinOrphan(OwnerHandle h) @system
    {
        OwnedTaskExecutor owner;
        synchronized (mutex)
        {
            if (!matches(h))
                return false;
            auto e = &entries[h.slot];
            if (!e.abandoned || e.phase != Phase.orphaned)
                return false;
            e.phase = Phase.draining;
            owner = e.executor;
            ++joinClaims;
        }
        try owner.closeAndJoin(); // real original native worker join
        catch (Throwable) abort(); // native uncertainty is not quiescence
        synchronized (mutex)
        {
            check(matches(h) && entries[h.slot].phase == Phase.draining &&
                owner.isStopped(), "joined without native evidence");
            entries[h.slot].phase = Phase.joined;
        }
        return true;
    }

    // P23 test hook: synthetic failure follows a KNOWN successful
    // Thread.start, before the FIRST native join. Never retry a real
    // failed native join or treat unknown OS status as recoverable.
    bool finishKnownSynthetic(OwnerHandle h) @system
    {
        OwnedTaskExecutor owner;
        synchronized (mutex)
        {
            if (!matches(h) || !entries[h.slot].abandoned ||
                entries[h.slot].phase != Phase.uncertain)
                return false;
            entries[h.slot].phase = Phase.draining;
            ++joinClaims;
            owner = entries[h.slot].executor;
        }
        try owner.researchJoinKnownSynthetic();
        catch (Throwable) abort();
        synchronized (mutex)
        {
            check(matches(h) && owner.isStopped(),
                "synthetic proof did not join actual workers");
            entries[h.slot].phase = Phase.joined;
        }
        return true;
    }

    bool reclaim(OwnerHandle h) @system
    {
        synchronized (mutex)
        {
            if (!matches(h))
                return false;
            auto e = &entries[h.slot];
            if (e.phase != Phase.joined || e.operations != 0)
                return false;
            auto owner = e.executor;
            check(owner !is null && owner.isStopped() &&
                owner.acceptedCount() == owner.completedCount() &&
                owner.retainedCount() == 0,
                "native join and settled TaskRefs required");
            GC.removeRoot(cast(void*) owner);
            e.executor = null;
            e.phase = Phase.vacant;
            e.abandoned = false;
            ++removed;
            return true;
        }
    }

    bool cancelNeverStarted(OwnerHandle h) @system
    {
        synchronized (mutex)
        {
            if (!matches(h) || entries[h.slot].phase != Phase.reserved)
                return false;
            auto e = &entries[h.slot];
            check(e.executor.researchConstructed(), "not an unstarted owner");
            GC.removeRoot(cast(void*) e.executor);
            e.executor = null;
            e.phase = Phase.vacant;
            e.abandoned = false;
            ++removed;
            return true;
        }
    }

    Phase status(OwnerHandle h)
    {
        synchronized (mutex)
        {
            if (!matches(h))
                return Phase.vacant;
            return entries[h.slot].phase;
        }
    }

    size_t occupied()
    {
        synchronized (mutex)
        {
            size_t total;
            foreach (e; entries)
                if (e.phase != Phase.vacant)
                    ++total;
            return total;
        }
    }

    bool outstanding()
    {
        return occupied() != 0;
    }

    size_t rootAdds() { synchronized (mutex) return installed; }
    size_t rootRemovals() { synchronized (mutex) return removed; }
    size_t refusals() { synchronized (mutex) return denied; }
    size_t nativeJoinClaims() { synchronized (mutex) return joinClaims; }
}

// Reference remains independent from ordinary controller or submitter.
private __gshared GenerationalManager applicationOwner;

private void verifyApplicationExit()
{
    if (applicationOwner !is null && applicationOwner.outstanding())
    {
        fprintf(stderr, "P29_UNFINISHED_OWNER_FAILSTOP\n");
        fflush(stderr);
        abort();
    }
}

private final class Gate
{
    Semaphore semaphore;
    shared uint entrants;
    this() { semaphore = new Semaphore(0); }
    void park()
    {
        atomicFetchAdd!(MemoryOrder.rel)(entrants, 1u);
        semaphore.wait();
    }
    void signalOrAbort()
    {
        try semaphore.notify();
        catch (Throwable) abort();
    }
}

private final class Graph
{
    int value;
    Graph next;
    this(int number, Graph other = null) { value = number; next = other; }
}

private final class Receipt
{
    shared uint executed;
    shared uint checksum;
}

private struct Job
{
    Gate gate;
    Graph graph;
    Receipt result;
    int opCall()
    {
        gate.park();
        const answer = cast(uint)(graph.value + graph.next.value * 3);
        atomicFetchAdd!(MemoryOrder.rel)(result.checksum, answer);
        atomicFetchAdd!(MemoryOrder.rel)(result.executed, 1u);
        return cast(int)answer;
    }
}

private void awaitWorker(Gate gate)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entrants) == 0u)
    {
        check(MonoTime.currTime < deadline, "native M0 worker did not park");
        Thread.yield();
    }
}

private void outcome(Receipt r, uint expected)
{
    check(atomicLoad!(MemoryOrder.acq)(r.executed) == 1u &&
        atomicLoad!(MemoryOrder.acq)(r.checksum) == expected,
        "owned task graph result or exactly-once property broken");
}

private void launchOrAbort(Thread t)
{
    try t.start();
    catch (Throwable) abort();
}

private void joinOrAbort(Thread t)
{
    try
    {
        auto error = t.join(false);
        if (error !is null)
            abort();
    }
    catch (Throwable)
        abort();
}

private Thread staleAttacker(GenerationalManager manager,
    OwnerHandle stale, Job bad, shared uint* violations)
{
    return new Thread({
        foreach (_; 0 .. 100)
        {
            if (manager.start(stale) ||
                manager.publish(stale, bad) ||
                manager.orphan(stale) ||
                manager.cancelNeverStarted(stale) ||
                manager.reclaim(stale) ||
                manager.joinOrphan(stale) ||
                manager.finishKnownSynthetic(stale))
                atomicFetchAdd!(MemoryOrder.rel)(*violations, 1u);
            Thread.yield();
        }
    });
}

private Thread orphanCloser(GenerationalManager manager, OwnerHandle h,
    shared uint* completed)
{
    return new Thread({
        if (!manager.joinOrphan(h))
            abort();
        atomicFetchAdd!(MemoryOrder.rel)(*completed, 1u);
    });
}

private void testAbaAndConcurrentStale()
{
    auto manager = new GenerationalManager();
    applicationOwner = manager;
    auto old = new OwnedTaskExecutor(1, 3, 4);
    OwnerHandle before, after;
    check(manager.enroll(old, before) && before.generation != 0 &&
        manager.cancelNeverStarted(before), "initial root not released");
    old = null;

    auto current = new OwnedTaskExecutor(1, 3, 4);
    check(manager.enroll(current, after) &&
        after.slot == before.slot &&
        after.generation != before.generation,
        "slot was reused without unique generation");
    current = null;
    check(manager.start(after), "fresh generation failed real start");

    auto gate = new Gate();
    auto receipt = new Receipt();
    Job accepted;
    accepted.gate = gate;
    accepted.graph = new Graph(5, new Graph(7));
    accepted.result = receipt;
    check(manager.publish(after, accepted), "fresh generation admission");
    awaitWorker(gate);

    // Identical task shape for stale submissions; not one can reach
    // the new executor after the slot was reused.
    shared uint violations;
    Thread[4] attacks;
    foreach (i; 0 .. attacks.length)
    {
        attacks[i] = staleAttacker(manager, before, accepted, &violations);
        launchOrAbort(attacks[i]);
    }
    foreach (t; attacks)
        joinOrAbort(t);
    check(atomicLoad!(MemoryOrder.acq)(violations) == 0u &&
        manager.status(before) == Phase.vacant &&
        manager.status(after) == Phase.active,
        "stale handle operated on different owner generation");

    check(manager.orphan(after), "real active owner could not orphan");
    shared uint joined;
    auto closer = orphanCloser(manager, after, &joined);
    launchOrAbort(closer);
    check(!manager.reclaim(after) && manager.occupied() == 1,
        "active worker released root");
    foreach (_; 0 .. 4)
    {
        GC.collect();
        check(manager.occupied() == 1, "worker GC graph lost");
    }
    gate.signalOrAbort();
    joinOrAbort(closer);
    outcome(receipt, 26u);
    check(atomicLoad!(MemoryOrder.acq)(joined) == 1u &&
        manager.status(after) == Phase.joined &&
        manager.reclaim(after) && !manager.reclaim(after),
        "joined owner root not reclaimed exactly once");
    check(manager.rootAdds() == 2 && manager.rootRemovals() == 2,
        "ABA root pairing incorrect");
    verifyApplicationExit();
    applicationOwner = null;
}

private void testQuotaAndUnknownGeneration()
{
    auto manager = new GenerationalManager();
    applicationOwner = manager;
    auto uncertain = new OwnedTaskExecutor(1, 2, 4);
    uncertain.researchInjectAfterStart();
    OwnerHandle u, other, refused, future;
    check(manager.enroll(uncertain, u), "unknown owner not adopted");
    uncertain = null;
    check(manager.start(u) && manager.status(u) == Phase.uncertain &&
        manager.orphan(u), "after-start synthetic uncertainty lost");

    auto second = new OwnedTaskExecutor(1, 2, 4);
    check(manager.enroll(second, other), "second capacity slot missing");
    second = null;
    auto third = new OwnedTaskExecutor(1, 2, 4);
    check(!manager.enroll(third, refused) &&
        refused.generation == 0 && manager.refusals() == 1 &&
        manager.occupied() == 2, "fixed capacity exhausted incorrectly");
    foreach (_; 0 .. 4)
    {
        GC.collect();
        check(!manager.cancelNeverStarted(u) && !manager.reclaim(u) &&
            !manager.joinOrphan(u) &&
            manager.status(u) == Phase.uncertain &&
            manager.occupied() == 2,
            "unknown native liveness was silently evicted");
    }

    // Free ONLY a proven never-started different slot. Re-occupy it.
    check(manager.cancelNeverStarted(other) &&
        manager.enroll(third, future) &&
        future.slot == other.slot &&
        future.generation != other.generation &&
        !manager.start(other) && !manager.orphan(other) &&
        !manager.cancelNeverStarted(other) &&
        manager.cancelNeverStarted(future),
        "quota reuse accepted stale generation");
    check(manager.occupied() == 1 && manager.status(u) == Phase.uncertain,
        "live uncertain generation disappeared during unrelated reuse");

    // Allowed only for known synthetic post-SUCCESSFUL native start.
    // No native join was attempted before this call.
    check(manager.finishKnownSynthetic(u) &&
        manager.status(u) == Phase.joined && manager.reclaim(u),
        "synthetic real native join did not release unknown slot");
    check(manager.occupied() == 0 &&
        manager.rootAdds() == 3 && manager.rootRemovals() == 3 &&
        manager.refusals() == 1, "uncertain ledger imbalance");
    verifyApplicationExit();
    applicationOwner = null;
}

version (P30Benchmark)
{
    private enum PerfMode : ubyte { original, deferred, managed }

    private final class PerfReceipt
    {
        shared uint executed;
        shared ulong checksum;
    }

    private struct PerfJob
    {
        PerfReceipt receipt;
        uint value;

        int opCall()
        {
            atomicFetchAdd!(MemoryOrder.rel)(receipt.executed, 1u);
            atomicFetchAdd!(MemoryOrder.rel)(receipt.checksum,
                cast(ulong)value);
            return cast(int)value;
        }
    }

    private final class ProducerStats
    {
        size_t attempts;
        size_t allocations;
        size_t accepted;
    }

    private Thread performanceProducer(
        PerfMode mode, OriginalExecutor original,
        OwnedTaskExecutor deferred, GenerationalManager manager,
        OwnerHandle h, PerfJob job, size_t requested,
        ProducerStats stats)
    {
        // Each worker delegate owns its own captured call-frame.
        return new Thread({
            const before = GC.allocatedInCurrentThread();
            const deadline = MonoTime.currTime + dur!"seconds"(40);
            foreach (_; 0 .. requested)
            {
                bool submitted;
                while (!submitted)
                {
                    if (MonoTime.currTime > deadline)
                        throw new Exception("P30 producer submission timeout");
                    ++stats.attempts;
                    final switch (mode)
                    {
                        case PerfMode.original:
                        {
                            auto result = original.trySubmit(job);
                            submitted = result !is null;
                            result = null;
                            break;
                        }
                        case PerfMode.deferred:
                        {
                            auto result = deferred.trySubmit(job);
                            submitted = result !is null;
                            result = null;
                            break;
                        }
                        case PerfMode.managed:
                            submitted = manager.publish(h, job);
                            break;
                    }
                    if (!submitted)
                        Thread.yield();
                }
                ++stats.accepted;
            }
            const after = GC.allocatedInCurrentThread();
            stats.allocations = after >= before ? after - before : 0;
        });
    }

    private struct PerfSample
    {
        string phase;
        size_t round;
        string mode;
        size_t tasks;
        size_t workers;
        size_t producers;
        size_t ingress;
        size_t retained;
        size_t accepted;
        size_t completed;
        ulong checksum;
        size_t attempts;
        size_t producerBytes;
        long createStartNs;
        long submitNs;
        long joinReleaseNs;
        long totalNs;
    }

    private PerfSample performanceArm(
        string phase, size_t round, PerfMode mode,
        size_t tasks, size_t workers, size_t producers,
        size_t ingress, size_t retained)
    {
        check(producers > 0 && tasks % producers == 0,
            "P30 count must divide producers");
        const perProducer = tasks / producers;
        auto receipt = new PerfReceipt();
        PerfJob job;
        job.receipt = receipt;
        job.value = 60u;

        OriginalExecutor original;
        OwnedTaskExecutor deferred;
        GenerationalManager manager;
        OwnerHandle h;

        // Preparation (including shared Job/Receipt) is outside the
        // timed phases in ALL three modes.
        GC.collect();
        const t0 = MonoTime.currTime;
        final switch (mode)
        {
            case PerfMode.original:
                original = new OriginalExecutor(workers, ingress, retained);
                break;
            case PerfMode.deferred:
                deferred = new OwnedTaskExecutor(workers, ingress, retained);
                deferred.researchStart();
                break;
            case PerfMode.managed:
                manager = new GenerationalManager();
                deferred = new OwnedTaskExecutor(workers, ingress, retained);
                check(manager.enroll(deferred, h), "P30 enroll failed");
                check(manager.start(h), "P30 manager native start failed");
                break;
        }
        const t1 = MonoTime.currTime;

        auto threads = new Thread[producers];
        auto stats = new ProducerStats[producers];
        foreach (i; 0 .. producers)
        {
            stats[i] = new ProducerStats();
            threads[i] = performanceProducer(mode, original, deferred,
                manager, h, job, perProducer, stats[i]);
        }
        foreach (t; threads)
            launchOrAbort(t);
        foreach (t; threads)
            joinOrAbort(t);
        const t2 = MonoTime.currTime;

        final switch (mode)
        {
            case PerfMode.original:
                original.closeAndJoin();
                break;
            case PerfMode.deferred:
                deferred.closeAndJoin();
                break;
            case PerfMode.managed:
                check(manager.orphan(h), "P30 manager orphan rejected");
                check(manager.joinOrphan(h), "P30 manager native join failed");
                check(manager.reclaim(h), "P30 manager root release failed");
                check(manager.rootAdds() == 1 && manager.rootRemovals() == 1,
                    "P30 explicit roots not paired");
                break;
        }
        const t3 = MonoTime.currTime;

        size_t accepted, completed;
        final switch (mode)
        {
            case PerfMode.original:
                accepted = original.acceptedCount();
                completed = original.completedCount();
                break;
            case PerfMode.deferred:
            case PerfMode.managed:
                accepted = deferred.acceptedCount();
                completed = deferred.completedCount();
                break;
        }
        size_t attempts, producerBytes, acknowledgements;
        foreach (stat; stats)
        {
            attempts += stat.attempts;
            producerBytes += stat.allocations;
            acknowledgements += stat.accepted;
        }
        const executed = atomicLoad!(MemoryOrder.acq)(receipt.executed);
        const checksum = atomicLoad!(MemoryOrder.acq)(receipt.checksum);
        check(accepted == tasks && completed == tasks &&
            acknowledgements == tasks && executed == tasks &&
            checksum == cast(ulong)tasks * 60u && attempts >= tasks,
            "P30 unpaired accepted/completed/execution/checksum");
        check(t1 >= t0 && t2 >= t1 && t3 >= t2, "P30 monotonic time");

        PerfSample sample;
        sample.phase = phase;
        sample.round = round;
        final switch (mode)
        {
            case PerfMode.original: sample.mode = "m0"; break;
            case PerfMode.deferred: sample.mode = "deferred"; break;
            case PerfMode.managed: sample.mode = "managed"; break;
        }
        sample.tasks = tasks;
        sample.workers = workers;
        sample.producers = producers;
        sample.ingress = ingress;
        sample.retained = retained;
        sample.accepted = accepted;
        sample.completed = completed;
        sample.checksum = checksum;
        sample.attempts = attempts;
        sample.producerBytes = producerBytes;
        sample.createStartNs = (t1 - t0).total!"nsecs";
        sample.submitNs = (t2 - t1).total!"nsecs";
        sample.joinReleaseNs = (t3 - t2).total!"nsecs";
        sample.totalNs = (t3 - t0).total!"nsecs";
        return sample;
    }

    private void outputSample(PerfSample s)
    {
        writeln(s.phase, ",", s.round, ",", s.mode, ",",
            s.tasks, ",", s.workers, ",", s.producers, ",",
            s.ingress, ",", s.retained, ",", s.accepted, ",",
            s.completed, ",", s.checksum, ",", s.attempts, ",",
            s.producerBytes, ",", s.createStartNs, ",",
            s.submitNs, ",", s.joinReleaseNs, ",", s.totalNs);
    }

    void main(string[] args)
    {
        size_t tasks = 512, workers = 2, producers = 2;
        size_t ingress = 64, retained = 512, warmup = 1, rounds = 3;
        for (size_t i = 1; i < args.length; ++i)
        {
            check(i + 1 < args.length, "P30 missing flag argument");
            auto flag = args[i];
            auto value = to!size_t(args[++i]);
            switch (flag)
            {
                case "--count": tasks = value; break;
                case "--workers": workers = value; break;
                case "--producers": producers = value; break;
                case "--ingress": ingress = value; break;
                case "--retained": retained = value; break;
                case "--warmup": warmup = value; break;
                case "--rounds": rounds = value; break;
                default: throw new Exception("P30 unknown option: " ~ flag);
            }
        }
        check(tasks > 0 && workers > 0 && producers > 0 &&
            ingress > 0 && retained > 0 &&
            tasks % producers == 0 && rounds >= 3 && warmup <= 10 &&
            rounds <= 20 && tasks <= 100_000,
            "P30 invalid dimensions");
        writeln("phase,round,mode,count,workers,producers,ingress,retained,"
            ~ "accepted,completed,checksum,attempts,producer_alloc_bytes,"
            ~ "create_start_ns,submit_ns,join_release_ns,total_ns");

        // Rotation avoids always granting the first arm the warmest
        // instruction cache or last arm the hottest processor. The
        // analyzer compares corresponding round/profile triples.
        // Balanced cyclic Latin square: each arm occurs exactly once at
        // position 1, 2 and 3 over each block of three paired triplets.
        // The archived 2026-10-15 XPS baseline used UNBALANCED orders;
        // retain that dataset unchanged and compare follow-up separately.
        const PerfMode[3][3] orders = [
            [PerfMode.original, PerfMode.deferred, PerfMode.managed],
            [PerfMode.deferred, PerfMode.managed, PerfMode.original],
            [PerfMode.managed, PerfMode.original, PerfMode.deferred]
        ];
        foreach (target; [PerfMode.original, PerfMode.deferred,
                          PerfMode.managed])
        {
            size_t[3] positions;
            foreach (order; orders)
                foreach (position, arm; order)
                    if (arm == target)
                        ++positions[position];
            foreach (countAtPosition; positions)
                check(countAtPosition == 1,
                    "P30 performance arm orders are not position balanced");
        }
        foreach (round; 0 .. warmup + rounds)
        {
            const phase = round < warmup ? "warmup" : "measure";
            foreach (mode; orders[round % orders.length])
                outputSample(performanceArm(phase, round, mode,
                    tasks, workers, producers, ingress, retained));
        }
        writeln("P30_M0_OWNERSHIP_BENCHMARK_PASS");
    }
}
else version (P31Benchmark)
{
    // P31 has no new executor, queue or task-header implementation:
    // it changes ONLY controlled producer count and task-side atomics
    // while reusing P29's exact generational manager.
    private enum P31Mode : ubyte { m0, deferred, managed }
    private enum P31Work : ubyte { sharedTwoAtomics, shardedTwoAtomics, minimal }

    // Separate heap objects intentionally reduce (but cannot strictly
    // rule out) cache-line aliasing between producer shards.
    private final class P31Counter
    {
        ubyte[128] padding;
        shared uint executed;
        shared ulong checksum;
    }

    private struct P31CountedJob
    {
        P31Counter result;
        int opCall()
        {
            atomicFetchAdd!(MemoryOrder.rel)(result.executed, 1u);
            atomicFetchAdd!(MemoryOrder.rel)(result.checksum, 60UL);
            return 60;
        }
    }

    private struct P31MinimalJob
    {
        int opCall() { return 60; }
    }

    private final class P31Stats
    {
        size_t attempts;
        size_t accepted;
        size_t producerBytes;
    }

    private bool p31Attempt(F)(
        P31Mode mode, OriginalExecutor baseline,
        OwnedTaskExecutor owned, GenerationalManager manager,
        OwnerHandle h, F job)
    {
        final switch (mode)
        {
            case P31Mode.m0:
            {
                auto result = baseline.trySubmit(job);
                return result !is null;
            }
            case P31Mode.deferred:
            {
                auto result = owned.trySubmit(job);
                return result !is null;
            }
            case P31Mode.managed:
                return manager.publish(h, job);
        }
    }

    private Thread p31Producer(
        P31Mode mode, P31Work work, OriginalExecutor baseline,
        OwnedTaskExecutor owned, GenerationalManager manager,
        OwnerHandle h, P31Counter counter, size_t count,
        P31Stats stats)
    {
        return new Thread({
            P31CountedJob counted;
            counted.result = counter;
            P31MinimalJob minimal;
            const startBytes = GC.allocatedInCurrentThread();
            const deadline = MonoTime.currTime + dur!"seconds"(40);
            foreach (_; 0 .. count)
            {
                bool accepted;
                while (!accepted)
                {
                    check(MonoTime.currTime < deadline,
                        "P31 producer admission timeout");
                    ++stats.attempts;
                    if (work == P31Work.minimal)
                        accepted = p31Attempt(mode, baseline, owned,
                            manager, h, minimal);
                    else
                        accepted = p31Attempt(mode, baseline, owned,
                            manager, h, counted);
                    if (!accepted)
                        Thread.yield();
                }
                ++stats.accepted;
            }
            const endBytes = GC.allocatedInCurrentThread();
            stats.producerBytes = endBytes >= startBytes
                ? endBytes - startBytes : 0;
        });
    }

    private string p31ModeName(P31Mode mode)
    {
        final switch (mode)
        {
            case P31Mode.m0: return "m0";
            case P31Mode.deferred: return "deferred";
            case P31Mode.managed: return "managed";
        }
    }

    private string p31WorkName(P31Work work)
    {
        final switch (work)
        {
            case P31Work.sharedTwoAtomics: return "shared_atomic";
            case P31Work.shardedTwoAtomics: return "sharded_atomic";
            case P31Work.minimal: return "minimal";
        }
    }

    private void p31Measure(
        string phase, size_t round, P31Mode mode, P31Work work,
        size_t taskCount, size_t workers, size_t producers,
        size_t ingress, size_t retained)
    {
        check(producers > 0 && taskCount > 0 &&
            taskCount % producers == 0 &&
            workers > 0 && ingress > 0 && retained > 0,
            "P31 fixed-work producer dimensions invalid");

        auto counters = new P31Counter[producers];
        foreach (i; 0 .. producers)
            counters[i] = new P31Counter();
        auto sharedCounter = new P31Counter();

        // Same original / P23 / actual P29 M0 worker pool, same bounded
        // retention, and same task type for each matched work-kind triple.
        GC.collect();
        OriginalExecutor baseline;
        OwnedTaskExecutor owned;
        GenerationalManager manager;
        OwnerHandle h;

        const begin = MonoTime.currTime;
        final switch (mode)
        {
            case P31Mode.m0:
                baseline = new OriginalExecutor(workers, ingress, retained);
                break;
            case P31Mode.deferred:
                owned = new OwnedTaskExecutor(workers, ingress, retained);
                owned.researchStart();
                break;
            case P31Mode.managed:
                manager = new GenerationalManager();
                owned = new OwnedTaskExecutor(workers, ingress, retained);
                check(manager.enroll(owned, h) && manager.start(h),
                    "P31 manager prelaunch/owned-start failed");
                break;
        }
        const created = MonoTime.currTime;

        auto threads = new Thread[producers];
        auto stats = new P31Stats[producers];
        foreach (i; 0 .. producers)
        {
            stats[i] = new P31Stats();
            auto counter = work == P31Work.sharedTwoAtomics
                ? sharedCounter : counters[i];
            threads[i] = p31Producer(mode, work, baseline, owned,
                manager, h, counter, taskCount / producers, stats[i]);
        }
        foreach (t; threads)
            launchOrAbort(t);
        foreach (t; threads)
            joinOrAbort(t);
        const submitted = MonoTime.currTime;

        final switch (mode)
        {
            case P31Mode.m0:
                baseline.closeAndJoin();
                break;
            case P31Mode.deferred:
                owned.closeAndJoin();
                break;
            case P31Mode.managed:
                check(manager.orphan(h) && manager.joinOrphan(h) &&
                    manager.reclaim(h) &&
                    manager.rootAdds() == 1 &&
                    manager.rootRemovals() == 1,
                    "P31 joined owner root not reclaimed");
                break;
        }
        const stopped = MonoTime.currTime;

        size_t accepted, completed;
        if (mode == P31Mode.m0)
        {
            accepted = baseline.acceptedCount();
            completed = baseline.completedCount();
        }
        else
        {
            accepted = owned.acceptedCount();
            completed = owned.completedCount();
        }
        size_t attempts, acknowledged, producerBytes;
        foreach (stat; stats)
        {
            attempts += stat.attempts;
            acknowledged += stat.accepted;
            producerBytes += stat.producerBytes;
        }
        ulong executed, checksum;
        if (work == P31Work.sharedTwoAtomics)
        {
            executed = atomicLoad!(MemoryOrder.acq)(
                sharedCounter.executed);
            checksum = atomicLoad!(MemoryOrder.acq)(
                sharedCounter.checksum);
        }
        else if (work == P31Work.shardedTwoAtomics)
        {
            foreach (c; counters)
            {
                // Every shard receives exactly taskCount/producers
                // accepted work, irrespective of native worker choice.
                check(atomicLoad!(MemoryOrder.acq)(c.executed) ==
                      taskCount / producers &&
                      atomicLoad!(MemoryOrder.acq)(c.checksum) ==
                      cast(ulong)(taskCount / producers) * 60UL,
                      "P31 individual producer shard not settled");
                executed += atomicLoad!(MemoryOrder.acq)(c.executed);
                checksum += atomicLoad!(MemoryOrder.acq)(c.checksum);
            }
        }
        // For minimal work, the *native pool's* accepted/completed
        // accounting is the oracle; no custom shared atomic is present.
        check(accepted == taskCount && completed == taskCount &&
            acknowledged == taskCount && attempts >= taskCount,
            "P31 M0 accepted/completed differs between arms");
        if (work == P31Work.minimal)
            check(executed == 0 && checksum == 0,
                "P31 minimal unexpectedly shared atomic counter");
        else
            check(executed == taskCount &&
                checksum == cast(ulong)taskCount * 60UL,
                "P31 counted task checksum or execution mismatch");
        check(created >= begin && submitted >= created &&
            stopped >= submitted, "P31 invalid monotonic phase order");

        writeln(phase, ",", round, ",", p31WorkName(work), ",",
            producers, ",", p31ModeName(mode), ",",
            taskCount, ",", workers, ",", ingress, ",", retained, ",",
            accepted, ",", completed, ",", executed, ",", checksum, ",",
            attempts, ",", producerBytes, ",",
            (created - begin).total!"nsecs", ",",
            (submitted - created).total!"nsecs", ",",
            (stopped - submitted).total!"nsecs", ",",
            (stopped - begin).total!"nsecs");
    }

    void main(string[] args)
    {
        size_t taskCount = 512, workers = 4, ingress = 64,
            retained = 256, warmup = 1, rounds = 3;
        for (size_t i = 1; i < args.length; ++i)
        {
            check(i + 1 < args.length, "P31 missing CLI value");
            auto key = args[i];
            const val = to!size_t(args[++i]);
            switch (key)
            {
                case "--count": taskCount = val; break;
                case "--workers": workers = val; break;
                case "--ingress": ingress = val; break;
                case "--retained": retained = val; break;
                case "--warmup": warmup = val; break;
                case "--rounds": rounds = val; break;
                default: throw new Exception("P31 unknown argument: " ~ key);
            }
        }
        check(taskCount > 0 && taskCount <= 100_000 &&
            taskCount % 4 == 0 && workers > 0 &&
            ingress > 0 && retained > 0 && rounds >= 3 &&
            rounds <= 12 && warmup <= 3,
            "P31 invalid fixed-dimension workload");
        writeln("phase,round,work,producers,mode,count,workers,ingress,"
            ~ "retained,accepted,completed,executed,checksum,attempts,"
            ~ "producer_alloc_bytes,create_start_ns,submit_ns,"
            ~ "join_release_ns,total_ns");

        // Latin square for the three ownership arms.
        const P31Mode[3][3] orders = [
            [P31Mode.m0, P31Mode.deferred, P31Mode.managed],
            [P31Mode.deferred, P31Mode.managed, P31Mode.m0],
            [P31Mode.managed, P31Mode.m0, P31Mode.deferred]
        ];
        const P31Work[3] workKinds = [
            P31Work.sharedTwoAtomics,
            P31Work.shardedTwoAtomics,
            P31Work.minimal
        ];
        const size_t[3] producerCounts = [1, 2, 4];
        foreach (round; 0 .. warmup + rounds)
        {
            auto phase = round < warmup ? "warmup" : "measure";
            // Vary profile order as well as ownership arm position.
            foreach (pIdx; 0 .. producerCounts.length)
            {
                auto nProd = producerCounts[
                    (pIdx + round) % producerCounts.length];
                foreach (wIdx; 0 .. workKinds.length)
                {
                    auto kind = workKinds[
                        (wIdx + round) % workKinds.length];
                    foreach (mode; orders[round % orders.length])
                        p31Measure(phase, round, mode, kind, taskCount,
                            workers, nProd, ingress, retained);
                }
            }
        }
        writeln("P31_FIXED_DIMENSIONS_BENCHMARK_PASS");
    }
}
else version (P29ExitUnknown)
{
    void main()
    {
        applicationOwner = new GenerationalManager();
        auto x = new OwnedTaskExecutor(1, 2, 4);
        x.researchInjectAfterStart();
        OwnerHandle h;
        check(applicationOwner.enroll(x, h), "failed to adopt");
        x = null;
        check(applicationOwner.start(h) && applicationOwner.orphan(h),
            "unknown setup failed");
        verifyApplicationExit(); // mandatory fail-stop BEFORE druntime
    }
}
else
{
    void main()
    {
        foreach (_; 0 .. 8)
        {
            testAbaAndConcurrentStale();
            testQuotaAndUnknownGeneration();
        }
        writeln("P29_GENERATIONAL_OWNER_PASS aba=8 contention=8 unknown_quota=8");
    }
}
