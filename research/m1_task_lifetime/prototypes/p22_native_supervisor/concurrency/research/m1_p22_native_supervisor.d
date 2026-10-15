/++
 M1 P22 — two real native workers with a controller-independent strong
 owner, coherent multi-closer shutdown and synthetic exceptional paths.
 RESEARCH ONLY. This is NOT the M0 scheduler or a production API.

 Actual Thread.join(false) is called only on workers whose Thread object
 was retained before launch. On real native start/join uncertainty, this
 experiment fails closed; ONLY the known injected, pre-join failure has a
 controlled, explicitly successful later join. No retry of a failed native
 pthread_join is claimed.
+/
module concurrency.research.m1_p22_native_supervisor;

import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad, atomicStore;
import core.memory : GC;
import core.stdc.stdlib : abort;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;

private enum size_t WorkerCount = 2;
private enum Phase : ubyte { running, draining, uncertain, joinedStopped }
private enum WorkerState : ubyte { absent, possiblyStarted, started, joined }
private enum Fault : ubyte
{
    none, syntheticPreJoin, syntheticPostLaunch, nativeUnknown
}
private enum Shutdown : ubyte { uncertain, joinedStopped }

private void require(bool okay, string reason)
{
    if (!okay)
        throw new Exception("P22: " ~ reason);
}

private final class Gate
{
    Semaphore semaphore;
    shared uint entered;

    this()
    {
        semaphore = new Semaphore(0);
    }

    void await()
    {
        atomicFetchAdd!(MemoryOrder.rel)(entered, 1u);
        semaphore.wait();
    }

    void releaseOrAbort(size_t permits)
    {
        foreach (_; 0 .. permits)
        {
            try
                semaphore.notify();
            catch (Throwable)
                abort();
        }
    }
}

private final class Payload
{
    int value;
    Payload child;
    this(int v, Payload next = null)
    {
        value = v;
        child = next;
    }
}

private final class Receipt
{
    shared uint[WorkerCount] hits;
    shared uint[WorkerCount] values;
}

private Thread makeWorker(
    Payload task, Gate workGate, Receipt receipt, size_t id)
{
    // Every worker captures its own value arguments. The controller
    // does not reference an expiring loop variable from its thread.
    return new Thread({
        workGate.await();
        const value = cast(uint)(task.value + task.child.value * 3);
        atomicStore!(MemoryOrder.rel)(receipt.values[id], value);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.hits[id], 1u);
    });
}

private final class RootedGroup
{
    private Mutex mutex;
    private Condition changed;
    private Phase phase;
    private Fault fault;
    private Thread[WorkerCount] workers;
    private WorkerState[WorkerCount] workerStates;
    private Payload[WorkerCount] roots;
    private Gate workGate;
    private Gate faultGate;
    private Receipt receipt;
    private size_t nativeCount;
    private size_t joinClaims;
    private size_t waitingClosers;
    private bool injectPreJoin;

    this(bool fakePreJoinFault = false)
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
        workGate = new Gate();
        faultGate = new Gate();
        receipt = new Receipt();
        phase = Phase.running;
        injectPreJoin = fakePreJoinFault;
    }

    // Must be called before any consumer/controller can drop the owner.
    // The test establishes a separate OwnerSupervisor root before start.
    bool start(bool fakePostLaunchFault = false)
    {
        foreach (i; 0 .. WorkerCount)
        {
            // Allocate the complete referent graph and hold it strongly
            // before the native worker could observe its address.
            roots[i] = new Payload(cast(int)i + 7,
                new Payload(cast(int)i + 13));
            workers[i] = makeWorker(roots[i], workGate, receipt, i);

            // A real Thread.start may throw after native launch. Retain
            // the Thread object and conservatively record possible start
            // BEFORE crossing the druntime launch boundary.
            workerStates[i] = WorkerState.possiblyStarted;
            try
            {
                workers[i].start();
            }
            catch (Throwable)
            {
                // A real druntime start failure could have happened
                // AFTER the OS launched this native worker. The
                // isolated research harness has no independent OS
                // quiescence proof for that path: do not unwind.
                abort();
            }
            ++nativeCount;

            if (fakePostLaunchFault && i == 0)
            {
                // Inject AFTER successful real start, BEFORE updating
                // the local known-started state.
                synchronized (mutex)
                {
                    fault = Fault.syntheticPostLaunch;
                    phase = Phase.uncertain;
                    changed.notifyAll();
                }
                return false;
            }
            workerStates[i] = WorkerState.started;
        }
        return true;
    }

    private void joinOrAbort()
    {
        // Never allow a real native join failure to become a normal
        // stack-frame unwind while any worker might still be accessing
        // a referent. A failed join(false) is NOT a worker Throwable.
        bool workerError;
        foreach (i; 0 .. WorkerCount)
        {
            if (workerStates[i] != WorkerState.started &&
                workerStates[i] != WorkerState.possiblyStarted)
                continue;

            Throwable returnedError;
            try
                returnedError = workers[i].join(false);
            catch (Throwable)
                abort();

            workerStates[i] = WorkerState.joined;
            if (returnedError !is null)
                workerError = true;
        }

        if (workerError)
            abort(); // Worker Error policy not qualified by P22.
    }

    private void finalizeJoined()
    {
        synchronized (mutex)
        {
            foreach (ref root; roots)
                root = null;
            phase = Phase.joinedStopped;
            fault = Fault.none;
            changed.notifyAll();
        }
    }

    Shutdown closeAndJoin()
    {
        synchronized (mutex)
        {
            final switch (phase)
            {
                case Phase.running:
                    phase = Phase.draining;
                    ++joinClaims;
                    break;
                case Phase.draining:
                    ++waitingClosers; // under mutex: independent waiter arrived
                    while (phase == Phase.draining)
                        changed.wait();
                    return phase == Phase.joinedStopped
                        ? Shutdown.joinedStopped : Shutdown.uncertain;
                case Phase.uncertain:
                    return Shutdown.uncertain;
                case Phase.joinedStopped:
                    return Shutdown.joinedStopped;
            }
        }

        // Only the elected first closer performs the native join.
        // In the injection arm, callers see uncertainty with all
        // worker-held payload roots intact.
        if (injectPreJoin)
        {
            faultGate.await();
            synchronized (mutex)
            {
                fault = Fault.syntheticPreJoin;
                phase = Phase.uncertain;
                changed.notifyAll();
            }
            return Shutdown.uncertain;
        }

        joinOrAbort();
        finalizeJoined();
        return Shutdown.joinedStopped;
    }

    // Test-only: ONLY permitted when the fault provenance is a known
    // synthetic injection. Never retry after an actual failed native
    // join, or after an ambiguous real Thread.start failure.
    void finishKnownSyntheticFaultOrAbort()
    {
        synchronized (mutex)
        {
            if (phase != Phase.uncertain ||
                (fault != Fault.syntheticPreJoin &&
                 fault != Fault.syntheticPostLaunch))
                abort();
            phase = Phase.draining;
            ++joinClaims;
        }
        joinOrAbort();
        finalizeJoined();
    }

    size_t heldRoots()
    {
        synchronized (mutex)
        {
            size_t n;
            foreach (root; roots)
                if (root !is null)
                    ++n;
            return n;
        }
    }

    Phase state()
    {
        synchronized (mutex)
            return phase;
    }

    size_t electedJoiners()
    {
        synchronized (mutex)
            return joinClaims;
    }

    size_t observedWaiters()
    {
        synchronized (mutex)
            return waitingClosers;
    }

    size_t startedCount() { return nativeCount; }
    Gate workingGate() { return workGate; }
    Gate prejoinGate() { return faultGate; }
    Receipt resultReceipt() { return receipt; }
}

// This object is rooted by the test controller INDEPENDENTLY of the
// original submitter handle and owns the entire Group graph.
private final class OwnerSupervisor
{
    private RootedGroup owned;

    this(RootedGroup group)
    {
        owned = group;
    }

    bool owns(RootedGroup group) { return owned is group; }
    bool hasRoot() { return owned !is null; }

    bool tryDiscard()
    {
        if (owned is null || owned.state() != Phase.joinedStopped)
            return false;
        require(owned.heldRoots() == 0, "joined group retains payloads");
        owned = null;
        return true;
    }

    RootedGroup retained() { return owned; }

    void recoverSyntheticAfterGateReleased()
    {
        require(owned !is null, "supervisor lost owner");
        owned.finishKnownSyntheticFaultOrAbort();
    }
}

private void awaitEntered(Gate gate, uint target)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entered) < target)
    {
        require(MonoTime.currTime < deadline, "worker/controller timeout");
        Thread.yield();
    }
}

private void checkResults(Receipt receipt, size_t count)
{
    foreach (i; 0 .. count)
    {
        require(atomicLoad!(MemoryOrder.acq)(receipt.hits[i]) == 1u,
            "accepted task executed other than once");
        const expected = cast(uint)((cast(int)i + 7) +
            (cast(int)i + 13) * 3);
        require(atomicLoad!(MemoryOrder.acq)(receipt.values[i]) == expected,
            "GC-owned nested task graph result mismatch");
    }
}

// A separate invocation frame per closer: capturing a loop-local slot
// directly can alias a reused iteration activation in D.
private Thread makeCloser(RootedGroup group, Shutdown[] outcomes, size_t index)
{
    return new Thread({
        outcomes[index] = group.closeAndJoin();
    });
}

private void testConcurrentNormalJoin()
{
    auto group = new RootedGroup();
    auto supervisor = new OwnerSupervisor(group); // before native start
    require(supervisor.owns(group), "owner not installed before launch");
    require(group.start(), "normal native start failed");

    auto workGate = group.workingGate();
    auto receipt = group.resultReceipt();
    awaitEntered(workGate, 2);
    require(group.heldRoots() == 2, "normal active roots disappeared");

    Shutdown[3] statuses;
    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = makeCloser(group, statuses[], i);
        closers[i].start();
    }

    // Ensure all work completes even if an oracle throws.
    workGate.releaseOrAbort(2);
    foreach (thread; closers)
    {
        try
        {
            auto failure = thread.join(false);
            if (failure !is null)
                abort();
        }
        catch (Throwable)
            abort();
    }

    foreach (status; statuses)
        require(status == Shutdown.joinedStopped,
            "normal concurrent closers disagreed");
    require(group.electedJoiners() == 1,
        "more than one native join owner elected");
    require(group.state() == Phase.joinedStopped,
        "normal close missing successful joined state");
    require(group.heldRoots() == 0, "normal roots still held after join");
    checkResults(receipt, 2);
    group = null;
    require(supervisor.tryDiscard(), "supervisor did not release joined owner");
}

private void awaitTwoCloseWaiters(RootedGroup group)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (group.observedWaiters() < 2)
    {
        require(MonoTime.currTime < deadline,
            "two concurrent shutdown observers did not enter draining");
        Thread.yield();
    }
}

private void testInjectedPrejoinAndAbandonedController()
{
    auto group = new RootedGroup(true);
    auto supervisor = new OwnerSupervisor(group);
    require(supervisor.owns(group), "root not installed pre-launch");
    require(group.start(), "prejoin-arm native start failed");

    auto workGate = group.workingGate();
    auto faultGate = group.prejoinGate();
    auto receipt = group.resultReceipt();
    awaitEntered(workGate, 2);

    Shutdown[3] statuses;
    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = makeCloser(group, statuses[], i);
        closers[i].start();
    }
    awaitEntered(faultGate, 1);
    // The elected closer is still inside its synthetic prejoin gate.
    require(group.state() == Phase.draining,
        "close did not enter draining before fault");
    require(group.heldRoots() == 2, "early roots cleared during draining");
    require(!supervisor.tryDiscard(), "prejoin owner discarded early");
    awaitTwoCloseWaiters(group); // prove both join the first closer's barrier
    faultGate.releaseOrAbort(1);

    foreach (thread; closers)
    {
        try
        {
            auto failure = thread.join(false);
            if (failure !is null)
                abort();
        }
        catch (Throwable)
            abort();
    }

    foreach (status; statuses)
        require(status == Shutdown.uncertain,
            "concurrent closers disagreed on synthetic fault");
    require(group.electedJoiners() == 1,
        "multiple native join owners after synthetic failure");
    require(group.state() == Phase.uncertain,
        "injected failure did not preserve uncertain status");
    require(group.heldRoots() == 2, "uncertain roots not retained");
    require(!supervisor.tryDiscard(), "uncertain owner discarded");
    group = null; // controller abandons its own owner reference

    // This root is explicit, not a claim about a conservative GC
    // collector's absence of residual stack or closure references.
    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(supervisor.hasRoot(), "strong supervisor root disappeared");
        require(supervisor.retained().heldRoots() == 2,
            "uncertain roots lost after GC");
        require(!supervisor.tryDiscard(), "uncertain release accepted");
    }

    // A known synthetic pre-join failure permits a LATER real join.
    // A real failed native join does NOT license this path.
    workGate.releaseOrAbort(2);
    supervisor.recoverSyntheticAfterGateReleased();
    require(supervisor.retained().state() == Phase.joinedStopped,
        "no verified joined state after successful join");
    require(supervisor.retained().heldRoots() == 0,
        "real join did not allow root reclamation");
    require(supervisor.retained().electedJoiners() == 2,
        "synthetic recovery was not separately elected");
    checkResults(receipt, 2);
    require(supervisor.tryDiscard(), "joined synthetic group not released");
}

private void testPostLaunchStartUncertainty()
{
    auto group = new RootedGroup();
    auto supervisor = new OwnerSupervisor(group);
    require(supervisor.owns(group), "missing pre-start supervisor");
    require(!group.start(true), "injected post-start fault not triggered");
    require(group.startedCount() == 1,
        "post-launch injection happened before actual native start");
    require(group.state() == Phase.uncertain,
        "post-launch uncertainty was not recorded");
    require(group.closeAndJoin() == Shutdown.uncertain,
        "post-launch startup error incorrectly treated as joined");
    require(group.heldRoots() == 1,
        "possibly started worker root was released");
    require(!supervisor.tryDiscard(),
        "post-launch supervisor released unknown work");

    auto gate = group.workingGate();
    auto receipt = group.resultReceipt();
    awaitEntered(gate, 1);
    group = null;
    GC.collect();
    require(supervisor.retained().heldRoots() == 1,
        "retained ambiguous native worker graph disappeared");
    gate.releaseOrAbort(1);
    supervisor.recoverSyntheticAfterGateReleased();
    checkResults(receipt, 1);
    require(supervisor.retained().state() == Phase.joinedStopped,
        "post-launch injected branch did not really join");
    require(supervisor.tryDiscard(), "post-launch retained owner not freed");
}

void main()
{
    // Repeated independent native start/join cycles; the synthetic
    // pre-join barrier forces two observers to WAIT concurrently.
    foreach (_; 0 .. 12)
    {
        testConcurrentNormalJoin();
        testInjectedPrejoinAndAbandonedController();
    }
    foreach (_; 0 .. 8)
        testPostLaunchStartUncertainty();

    writeln("P22_NATIVE_SUPERVISOR_PASS normal=12 prejoin=12 postlaunch=8");
}
