/++
 P28 bounded process owner over actual M0 tasks.
 RESEARCH ONLY: explicit orphan announcement, no automatic GC-finalizer
 adoption, no arbitrary @safe TaskRef or native join error recovery.
+/
module concurrency.research.p28_bounded_orphans;

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

private void require(bool yes, string reason)
{
    if (!yes)
        throw new Exception("P28: " ~ reason);
}

private enum Phase : ubyte
{
    vacant, reserved, starting, active, orphaned, draining, uncertain, joined
}

private final class BoundedOwner
{
    private enum size_t Capacity = 2;
    private Mutex mutex;
    private OwnedTaskExecutor[Capacity] slots;
    private Phase[Capacity] states;
    private bool[Capacity] abandoned;
    private size_t installed, removed, capacityDenied, shutdownClaims;

    this() { mutex = new Mutex(); }

    bool enroll(OwnedTaskExecutor proposed, out size_t index) @system
    {
        require(proposed !is null && proposed.researchConstructed(),
            "enroll requires constructed unstarted executor");
        synchronized (mutex)
        {
            foreach (i; 0 .. Capacity)
            {
                if (states[i] != Phase.vacant)
                    continue;
                // Explicit lifetime obligation BEFORE any native start.
                GC.addRoot(cast(void*) proposed);
                slots[i] = proposed;
                states[i] = Phase.reserved;
                ++installed;
                index = i;
                return true;
            }
            ++capacityDenied;
        }
        return false;
    }

    bool start(size_t index) @system
    {
        OwnedTaskExecutor subject;
        synchronized (mutex)
        {
            if (index >= Capacity || states[index] != Phase.reserved)
                return false;
            subject = slots[index];
            states[index] = Phase.starting;
        }
        // P23 fails-stop on any real ambiguous native Thread.start error.
        try subject.researchStart();
        catch (Throwable)
            abort();

        synchronized (mutex)
        {
            require(states[index] == Phase.starting,
                "start state mutated while native launch underway");
            states[index] = subject.researchUncertain()
                ? Phase.uncertain : Phase.active;
        }
        return true;
    }

    // The caller must explicitly announce handoff/abandonment.
    // No GC finalizer detects this event. Already-obtained raw
    // references are NOT revoked by this bounded research API.
    bool markAbandoned(size_t index)
    {
        synchronized (mutex)
        {
            if (index >= Capacity || abandoned[index])
                return false;
            if (states[index] != Phase.active &&
                states[index] != Phase.uncertain)
                return false;
            abandoned[index] = true;
            if (states[index] == Phase.active)
                states[index] = Phase.orphaned;
            return true;
        }
    }

    OwnedTaskExecutor activeBorrow(size_t index)
    {
        synchronized (mutex)
        {
            if (index >= Capacity || states[index] != Phase.active)
                return null;
            return slots[index];
        }
    }

    bool closeOrphan(size_t index) @system
    {
        OwnedTaskExecutor subject;
        synchronized (mutex)
        {
            if (index >= Capacity || !abandoned[index] ||
                states[index] != Phase.orphaned)
                return false;
            states[index] = Phase.draining;
            ++shutdownClaims;
            subject = slots[index];
        }

        // Actual original M0 close/worker join. Native uncertainty
        // remains fail-stop, never silent root removal.
        try subject.closeAndJoin();
        catch (Throwable)
            abort();

        synchronized (mutex)
        {
            require(states[index] == Phase.draining && subject.isStopped(),
                "native join not verified");
            states[index] = Phase.joined;
        }
        return true;
    }

    // Research-only exceptional repair: P23 artificial fault was
    // injected AFTER KNOWN SUCCESSFUL native worker pool launch.
    // No native pthread_join has failed or even been called.
    bool finishKnownSynthetic(size_t index) @system
    {
        OwnedTaskExecutor subject;
        synchronized (mutex)
        {
            if (index >= Capacity || states[index] != Phase.uncertain ||
                !abandoned[index])
                return false;
            states[index] = Phase.draining;
            ++shutdownClaims;
            subject = slots[index];
        }
        try subject.researchJoinKnownSynthetic();
        catch (Throwable)
            abort();
        synchronized (mutex)
        {
            require(subject.isStopped(), "synthetic path failed real join");
            states[index] = Phase.joined;
        }
        return true;
    }

    bool reclaim(size_t index) @system
    {
        synchronized (mutex)
        {
            if (index >= Capacity || states[index] != Phase.joined)
                return false;
            auto subject = slots[index];
            require(subject !is null && subject.isStopped() &&
                subject.acceptedCount() == subject.completedCount() &&
                subject.retainedCount() == 0,
                "reclaim requires joined and settled work");
            GC.removeRoot(cast(void*) subject);
            slots[index] = null;
            states[index] = Phase.vacant;
            abandoned[index] = false;
            ++removed;
            return true;
        }
    }

    // No-start cancellation is separate from a native join proof.
    bool cancelNeverStarted(size_t index) @system
    {
        synchronized (mutex)
        {
            if (index >= Capacity || states[index] != Phase.reserved)
                return false;
            require(slots[index].researchConstructed(),
                "cancel lacks never-launched certificate");
            GC.removeRoot(cast(void*) slots[index]);
            slots[index] = null;
            states[index] = Phase.vacant;
            abandoned[index] = false;
            ++removed;
            return true;
        }
    }

    size_t occupied()
    {
        synchronized (mutex)
        {
            size_t n;
            foreach (phase; states)
                if (phase != Phase.vacant)
                    ++n;
            return n;
        }
    }

    size_t rootsInstalled() { synchronized (mutex) return installed; }
    size_t rootsRemoved() { synchronized (mutex) return removed; }
    size_t denied() { synchronized (mutex) return capacityDenied; }
    size_t claims() { synchronized (mutex) return shutdownClaims; }

    Phase phase(size_t index)
    {
        synchronized (mutex)
            return index < Capacity ? states[index] : Phase.vacant;
    }

    bool hasUnfinishedObligations()
    {
        synchronized (mutex)
        {
            foreach (phase; states)
                if (phase != Phase.vacant)
                    return true;
            return false;
        }
    }
}

// Anchored beyond all producer and controller handle lifetimes.
private __gshared BoundedOwner processManager;

// Explicit check BEFORE druntime thread teardown (P27 showed that
// shared static ~this() need not run while a live worker blocks exit).
private void applicationCloseOrAbort()
{
    if (processManager !is null &&
        processManager.hasUnfinishedObligations())
    {
        fprintf(stderr, "P28_APP_EXIT_UNFINISHED_FAILSTOP\n");
        fflush(stderr);
        abort();
    }
}

private final class WorkGate
{
    Semaphore sem;
    shared uint entered;
    this() { sem = new Semaphore(0); }
    void park()
    {
        atomicFetchAdd!(MemoryOrder.rel)(entered, 1u);
        sem.wait();
    }
    void open()
    {
        try sem.notify();
        catch (Throwable) abort();
    }
}

private final class Nested
{
    int value;
    Nested child;
    this(int val, Nested tail = null) { value = val; child = tail; }
}

private final class Receipt
{
    shared uint runs;
    shared uint checksum;
}

private struct Job
{
    WorkGate gate;
    Nested graph;
    Receipt receipt;
    int opCall()
    {
        gate.park();
        const v = cast(uint)(graph.value + graph.child.value * 3);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.checksum, v);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.runs, 1u);
        return cast(int) v;
    }
}

private Thread makeOrphanCloser(BoundedOwner manager, size_t id,
    shared uint* confirmed)
{
    return new Thread({
        if (manager.closeOrphan(id))
            atomicFetchAdd!(MemoryOrder.rel)(*confirmed, 1u);
        else
            abort();
    });
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

private void awaitParked(WorkGate gate)
{
    const end = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entered) == 0u)
    {
        require(MonoTime.currTime < end, "real M0 worker not parked");
        Thread.yield();
    }
}

private void check(Receipt r, uint expected)
{
    require(atomicLoad!(MemoryOrder.acq)(r.runs) == 1u &&
        atomicLoad!(MemoryOrder.acq)(r.checksum) == expected,
        "owned GC graph lost or executed more than once");
}

private void testCapacityAndOrphanDrain()
{
    auto manager = new BoundedOwner();
    processManager = manager;
    auto a = new OwnedTaskExecutor(1, 2, 4);
    auto b = new OwnedTaskExecutor(1, 2, 4);
    auto refused = new OwnedTaskExecutor(1, 2, 4);
    size_t ia, ib, rejected;
    require(manager.enroll(a, ia) && manager.enroll(b, ib) &&
        ia != ib && manager.occupied() == 2,
        "prelaunch roots not installed in independent slots");
    require(!manager.enroll(refused, rejected) &&
        manager.denied() == 1 && refused.researchConstructed(),
        "full capacity silently adopted or launched third executor");
    a = null;
    b = null; // callers abandon constructor handles
    require(manager.start(ia) && manager.start(ib),
        "M0 native workers not actually launched");

    auto ga = new WorkGate();
    auto gb = new WorkGate();
    auto ra = new Receipt();
    auto rb = new Receipt();
    Job first, second;
    first.gate = ga; first.graph = new Nested(5, new Nested(7)); first.receipt = ra;
    second.gate = gb; second.graph = new Nested(11, new Nested(13)); second.receipt = rb;
    {
        auto ownerA = manager.activeBorrow(ia);
        auto ownerB = manager.activeBorrow(ib);
        auto ha = ownerA.submit(first);
        auto hb = ownerB.submit(second);
        require(ha !is null && hb !is null, "real M0 task admission failed");
        ha = null;
        hb = null;
    }
    awaitParked(ga);
    awaitParked(gb);
    require(manager.markAbandoned(ia) && manager.markAbandoned(ib) &&
        !manager.markAbandoned(ia),
        "duplicate or missing explicit orphan transition");
    require(manager.activeBorrow(ia) is null &&
        manager.activeBorrow(ib) is null,
        "manager still publishes owner after orphan handoff");
    require(!manager.reclaim(ia) && !manager.reclaim(ib) &&
        manager.occupied() == 2,
        "running workers freed their root or capacity early");

    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(manager.occupied() == 2 &&
            manager.phase(ia) == Phase.orphaned &&
            manager.phase(ib) == Phase.orphaned,
            "orphan roots lost during forced GC");
    }
    shared uint finished;
    auto closerA = makeOrphanCloser(manager, ia, &finished);
    auto closerB = makeOrphanCloser(manager, ib, &finished);
    launchOrAbort(closerA);
    launchOrAbort(closerB);
    ga.open();
    gb.open();
    joinOrAbort(closerA);
    joinOrAbort(closerB);
    require(atomicLoad!(MemoryOrder.acq)(finished) == 2u &&
        manager.claims() == 2 && manager.phase(ia) == Phase.joined &&
        manager.phase(ib) == Phase.joined,
        "orphan supervisor native joins not proven");
    check(ra, 26u);
    check(rb, 50u);
    require(manager.reclaim(ia) && manager.reclaim(ib) &&
        !manager.reclaim(ia) && manager.occupied() == 0,
        "roots not reclaimed exactly once");

    // Previously refused application owner can now be admitted.
    size_t reused;
    require(manager.enroll(refused, reused) &&
        manager.cancelNeverStarted(reused) && manager.occupied() == 0,
        "capacity not reusable after real native joins");
    require(manager.rootsInstalled() == 3 &&
        manager.rootsRemoved() == 3 &&
        manager.denied() == 1, "bounded owner root ledger mismatched");
    applicationCloseOrAbort(); // explicit safe boundary
    processManager = null;
}

private void testUncertainConsumesCapacity()
{
    auto manager = new BoundedOwner();
    processManager = manager;
    auto uncertain = new OwnedTaskExecutor(1, 2, 4);
    uncertain.researchInjectAfterStart(); // synthetically AFTER a real launch
    size_t bad, keep, extra;
    require(manager.enroll(uncertain, bad), "unknown owner not rooted");
    uncertain = null;
    require(manager.start(bad) && manager.phase(bad) == Phase.uncertain &&
        manager.markAbandoned(bad), "synthetic unknown not retained");
    require(!manager.closeOrphan(bad) && !manager.reclaim(bad),
        "uncertain native worker incorrectly treated as joined");

    auto second = new OwnedTaskExecutor(1, 2, 4);
    require(manager.enroll(second, keep), "second rooted slot missing");
    second = null;
    auto third = new OwnedTaskExecutor(1, 2, 4);
    require(!manager.enroll(third, extra) && manager.occupied() == 2,
        "unknown slot erroneously freed its fixed capacity");
    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(manager.phase(bad) == Phase.uncertain &&
            manager.occupied() == 2 && !manager.reclaim(bad),
            "unknown-root GC collection permitted reclamation");
    }
    require(manager.cancelNeverStarted(keep) &&
        !manager.cancelNeverStarted(bad),
        "never-started certificate incorrectly used for launched worker");
    // Test-only: original startup completed before the synthetic fault.
    // This invokes the FIRST actual join; no failed OS join is retried.
    require(manager.finishKnownSynthetic(bad) &&
        manager.phase(bad) == Phase.joined && manager.reclaim(bad),
        "known synthetic proof did not discharge native obligation");
    require(manager.occupied() == 0 &&
        manager.rootsInstalled() == manager.rootsRemoved(),
        "unknown-shutdown root release ledger mismatch");
    applicationCloseOrAbort();
    processManager = null;
}

version (P28ExitUnknown)
{
    void main()
    {
        processManager = new BoundedOwner();
        auto created = new OwnedTaskExecutor(1, 2, 4);
        created.researchInjectAfterStart();
        size_t slot;
        require(processManager.enroll(created, slot), "adopt failed");
        created = null;
        require(processManager.start(slot) &&
            processManager.markAbandoned(slot), "unknown setup failed");
        applicationCloseOrAbort(); // must abort before runtime teardown
    }
}
else version (P28ExitOrphan)
{
    void main()
    {
        processManager = new BoundedOwner();
        auto created = new OwnedTaskExecutor(1, 2, 4);
        size_t slot;
        require(processManager.enroll(created, slot), "adopt failed");
        created = null;
        require(processManager.start(slot) &&
            processManager.markAbandoned(slot), "orphan setup failed");
        applicationCloseOrAbort(); // must abort before runtime teardown
    }
}
else
{
    void main()
    {
        foreach (_; 0 .. 6)
        {
            testCapacityAndOrphanDrain();
            testUncertainConsumesCapacity();
        }
        writeln("P28_BOUNDED_OWNER_PASS orphan_drains=6 unknown_retained=6 root_pairs=30 quota_denials=12");
    }
}
