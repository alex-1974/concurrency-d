/++
 P27: process-teardown and overlapping native ownership transitions.
 SOURCE-PINNED actual M0 OwnedTaskExecutor + SubmissionWorkerPool.
 Research only: not a scheduler rewrite, public API, or @safe contract.
+/
module concurrency.research.p27_registry_transitions;

import concurrency.research.m1_p23_owned : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.memory : GC;
import core.stdc.stdio : fprintf, fflush, stderr;
import core.stdc.stdlib : abort;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;

private void require(bool good, string message)
{
    if (!good)
        throw new Exception("P27: " ~ message);
}

private int shortTask() { return 27; }
private enum Phase : ubyte
{
    empty, registered, starting, running, draining, joined, released
}

private final class ManagedOwner
{
    private Mutex mutex;
    private Condition changed;
    private OwnedTaskExecutor owner;
    private Phase phase;
    private size_t activeCalls;
    private size_t starts;
    private size_t joins;
    private size_t startingWaiters;
    private bool rootRegistered;

    this()
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
        phase = Phase.empty;
    }

    void adopt(OwnedTaskExecutor executor) @system
    {
        require(executor !is null && executor.researchConstructed(),
            "adopt requires prelaunch constructed executor");
        synchronized (mutex)
        {
            require(phase == Phase.empty, "owner can be adopted once");
            GC.addRoot(cast(void*) executor);
            owner = executor;
            rootRegistered = true;
            phase = Phase.registered;
            changed.notifyAll();
        }
    }

    bool start(Semaphore heldBeforeNative = null) @system
    {
        synchronized (mutex)
        {
            if (phase != Phase.registered)
                return false;
            phase = Phase.starting;
            ++starts;
            changed.notifyAll();
        }

        // Holding here makes start-vs-close contention deterministic.
        // No native worker has launched yet. The root was already installed.
        if (heldBeforeNative !is null)
            heldBeforeNative.wait();

        // A real post-native-launch throw is UNKNOWN; the P23 source copy
        // fail-stops rather than returning with borrowed records at risk.
        try owner.researchStart();
        catch (Throwable)
            abort();

        synchronized (mutex)
        {
            require(phase == Phase.starting, "start state was overwritten");
            phase = Phase.running;
            changed.notifyAll();
        }
        return true;
    }

    // Admission borrows the owner under an explicit operation count;
    // the original M0 mutex independently arbitrates trySubmit vs close.
    bool tryPublish()
    {
        OwnedTaskExecutor target;
        synchronized (mutex)
        {
            if (phase != Phase.running)
                return false;
            ++activeCalls;
            target = owner;
        }

        bool accepted;
        try
        {
            auto handle = target.trySubmit(&shortTask);
            accepted = handle !is null;
            handle = null;
        }
        catch (Exception)
        {
            // Close may already have claimed the M0 admission mutex;
            // rejecting this attempt creates no accepted obligation.
        }
        catch (Throwable)
            abort();

        synchronized (mutex)
        {
            require(activeCalls > 0, "operation-count underflow");
            --activeCalls;
            changed.notifyAll();
        }
        return accepted;
    }

    bool closeAndJoin() @system
    {
        OwnedTaskExecutor target;
        synchronized (mutex)
        {
            while (phase == Phase.starting)
            {
                ++startingWaiters;
                changed.wait();
            }

            final switch (phase)
            {
                case Phase.empty:
                case Phase.registered:
                case Phase.released:
                    return false;
                case Phase.starting:
                    assert(0);
                case Phase.running:
                    phase = Phase.draining;
                    ++joins;
                    target = owner;
                    changed.notifyAll();
                    break;
                case Phase.draining:
                    while (phase == Phase.draining)
                        changed.wait();
                    return phase == Phase.joined;
                case Phase.joined:
                    return true;
            }
        }

        // Only one caller actually joins the real M0 worker pool.
        try target.closeAndJoin();
        catch (Throwable)
            abort(); // a true native join failure is NOT recoverable

        synchronized (mutex)
        {
            require(phase == Phase.draining, "join owner lost shutdown state");
            phase = Phase.joined;
            changed.notifyAll();
        }
        return true;
    }

    bool tryRelease() @system
    {
        synchronized (mutex)
        {
            if (phase != Phase.joined || activeCalls != 0)
                return false;
            require(rootRegistered && owner !is null && owner.isStopped(),
                "release without real native join proof");
            require(owner.acceptedCount() == owner.completedCount() &&
                owner.retainedCount() == 0,
                "accepted outcome or record retention remains");
            GC.removeRoot(cast(void*) owner);
            owner = null;
            rootRegistered = false;
            phase = Phase.released;
            changed.notifyAll();
            return true;
        }
    }

    // Explicit cancellation of an UNSTARTED/UNUSED registration only.
    // This path cannot run after native launch.
    bool cancelNeverStarted() @system
    {
        synchronized (mutex)
        {
            if (phase != Phase.registered)
                return false;
            require(rootRegistered && owner.researchConstructed(),
                "unstarted cancellation lacks no-launch proof");
            GC.removeRoot(cast(void*) owner);
            owner = null;
            rootRegistered = false;
            phase = Phase.released;
            changed.notifyAll();
            return true;
        }
    }

    bool outstanding()
    {
        synchronized (mutex)
            return rootRegistered;
    }

    Phase state()
    {
        synchronized (mutex)
            return phase;
    }

    size_t startClaims()
    {
        synchronized (mutex)
            return starts;
    }

    size_t joinClaims()
    {
        synchronized (mutex)
            return joins;
    }

    size_t waitingForStart()
    {
        synchronized (mutex)
            return startingWaiters;
    }

    size_t outstandingCalls()
    {
        synchronized (mutex)
            return activeCalls;
    }

    bool conservedAfterJoin()
    {
        synchronized (mutex)
        {
            if (phase != Phase.joined)
                return false;
            return owner.acceptedCount() == owner.completedCount() &&
                owner.retainedCount() == 0;
        }
    }

    size_t accepted()
    {
        synchronized (mutex)
            return owner is null ? 0 : owner.acceptedCount();
    }
}

// Anchored independently of producers and controller temporaries.
private __gshared ManagedOwner processOwner;

// Explicit application shutdown boundary: the D runtime may wait for
// live druntime Threads BEFORE dispatching shared static module
// destructors. Therefore this check must run while main can still act.
private void processExitOrAbort()
{
    if (processOwner !is null && processOwner.outstanding())
    {
        fprintf(stderr, "P27_APPLICATION_EXIT_FAILSTOP\n");
        fflush(stderr);
        abort();
    }
}

// A process-boundary sentinel; intentionally NO native join here.
// It MUST NOT silently allow druntime module teardown with live TaskRefs.
shared static ~this()
{
    if (processOwner !is null && processOwner.outstanding())
    {
        fprintf(stderr, "P27_PROCESS_EXIT_FAILSTOP\n");
        fflush(stderr);
        abort();
    }
}

private Thread producer(ManagedOwner manager, shared uint* credited)
{
    return new Thread({
        foreach (_; 0 .. 128)
        {
            if (manager.tryPublish())
                atomicFetchAdd!(MemoryOrder.rel)(*credited, 1u);
            else
                Thread.yield();
        }
    });
}

private Thread closer(ManagedOwner manager, shared uint* finished)
{
    return new Thread({
        if (!manager.closeAndJoin())
            abort();
        atomicFetchAdd!(MemoryOrder.rel)(*finished, 1u);
    });
}

private Thread starter(ManagedOwner manager, Semaphore blocker,
    shared uint* succeeded)
{
    return new Thread({
        if (manager.start(blocker))
            atomicFetchAdd!(MemoryOrder.rel)(*succeeded, 1u);
    });
}

private void launchOrAbort(Thread t)
{
    try t.start();
    catch (Throwable) abort(); // no native-start recovery asserted
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

private void waitForAccepted(ManagedOwner manager)
{
    const until = MonoTime.currTime + dur!"seconds"(10);
    while (manager.accepted() == 0)
    {
        require(MonoTime.currTime < until, "no real M0 task accepted");
        Thread.yield();
    }
}

private void waitForStartingWaiters(ManagedOwner manager, size_t count)
{
    const until = MonoTime.currTime + dur!"seconds"(10);
    while (manager.waitingForStart() < count)
    {
        require(MonoTime.currTime < until,
            "close controllers failed to wait for native start");
        Thread.yield();
    }
}

private void testProducerCloseOverlap()
{
    auto manager = new ManagedOwner();
    processOwner = manager;
    auto controller = new OwnedTaskExecutor(2, 8, 256);
    manager.adopt(controller);
    controller = null;
    require(manager.outstanding(), "missing prestart explicit root");
    require(!manager.tryPublish() && !manager.closeAndJoin() &&
        !manager.tryRelease(), "prestart admission, join or release allowed");
    require(manager.start(), "native M0 pool not started");
    require(!manager.start() && !manager.cancelNeverStarted(),
        "duplicate start or invalid no-start proof accepted");

    shared uint credited, completed;
    Thread[4] producers;
    foreach (i; 0 .. producers.length)
    {
        producers[i] = producer(manager, &credited);
        launchOrAbort(producers[i]);
    }
    waitForAccepted(manager);
    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = closer(manager, &completed);
        launchOrAbort(closers[i]);
    }
    foreach (t; producers)
        joinOrAbort(t);
    foreach (t; closers)
        joinOrAbort(t);

    require(manager.state() == Phase.joined &&
        manager.joinClaims() == 1 && manager.startClaims() == 1,
        "concurrent transitions elected duplicate owners");
    require(atomicLoad!(MemoryOrder.acq)(completed) == 3u,
        "competing closers did not agree on terminal state");
    require(manager.accepted() == atomicLoad!(MemoryOrder.acq)(credited) &&
        manager.conservedAfterJoin(),
        "acknowledged, accepted and completed TaskRefs differ");
    require(manager.outstandingCalls() == 0 && !manager.tryPublish(),
        "new admission or unreturned operation after join");
    require(manager.tryRelease() && !manager.tryRelease(),
        "registered native root was not removed exactly once");
    processOwner = null;
}

private void testStartCloseOverlap()
{
    auto manager = new ManagedOwner();
    processOwner = manager;
    auto controller = new OwnedTaskExecutor(1, 2, 2);
    manager.adopt(controller);
    controller = null;
    auto startGate = new Semaphore(0);
    shared uint started, closed;

    auto startThread = starter(manager, startGate, &started);
    launchOrAbort(startThread);
    const until = MonoTime.currTime + dur!"seconds"(10);
    while (manager.state() != Phase.starting)
    {
        require(MonoTime.currTime < until, "start was never claimed");
        Thread.yield();
    }
    require(!manager.start() && !manager.tryPublish() &&
        !manager.tryRelease() && !manager.cancelNeverStarted(),
        "second start, early submit/release or false no-start claim");

    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = closer(manager, &closed);
        launchOrAbort(closers[i]);
    }
    waitForStartingWaiters(manager, 3);
    try startGate.notify();
    catch (Throwable) abort();

    joinOrAbort(startThread);
    foreach (t; closers)
        joinOrAbort(t);

    require(atomicLoad!(MemoryOrder.acq)(started) == 1u &&
        atomicLoad!(MemoryOrder.acq)(closed) == 3u &&
        manager.startClaims() == 1 && manager.joinClaims() == 1 &&
        manager.conservedAfterJoin(),
        "start-close handoff failed to prove native quiescence");
    require(manager.tryRelease(), "joined early-close owner not released");
    processOwner = null;
}

private void testNeverStartedCancellation()
{
    auto manager = new ManagedOwner();
    processOwner = manager;
    auto controller = new OwnedTaskExecutor(1, 2, 2);
    manager.adopt(controller);
    controller = null;
    require(manager.cancelNeverStarted(), "never-started root cannot cancel");
    require(!manager.cancelNeverStarted() && !manager.start() &&
        !manager.tryRelease(), "never-started cancellation not terminal");
    require(!manager.outstanding(), "never-started root leaked");
    processOwner = null;
}

version (P27ExitActive)
{
    void main()
    {
        auto controller = new OwnedTaskExecutor(1, 2, 2);
        processOwner = new ManagedOwner();
        processOwner.adopt(controller);
        controller = null;
        processOwner.start();
        // Explicit app-controlled shutdown check runs BEFORE D runtime
        // tries to wait for the still-running native worker threads.
        processExitOrAbort();
    }
}
else version (P27ExitUnstarted)
{
    void main()
    {
        auto controller = new OwnedTaskExecutor(1, 2, 2);
        processOwner = new ManagedOwner();
        processOwner.adopt(controller);
        controller = null;
        // A registered but never-started executor still requires explicit
        // cancellation before the module lifetime ends.
    }
}
else version (P27RuntimeOnly)
{
    void main()
    {
        auto controller = new OwnedTaskExecutor(1, 2, 2);
        processOwner = new ManagedOwner();
        processOwner.adopt(controller);
        controller = null;
        processOwner.start();
        // Deliberately omit explicit process-exit check. With the pinned
        // DMD/LDC runtimes, normal main exit waits for native workers
        // before shared static ~this() can run. Bounded diagnostic only.
    }
}
else
{
    void main()
    {
        foreach (_; 0 .. 12)
        {
            testProducerCloseOverlap();
            testStartCloseOverlap();
            testNeverStartedCancellation();
            GC.collect();
        }
        require(processOwner is null,
            "final module exit still holds an owner reference");
        processExitOrAbort(); // normal safe process boundary
        writeln("P27_LIFECYCLE_RACES_PASS producer_close=12 start_close=12 never_started=12");
    }
}
