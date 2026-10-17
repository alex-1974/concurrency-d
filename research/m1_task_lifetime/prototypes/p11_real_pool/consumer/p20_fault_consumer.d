/++
 P20: exact-M0 owned executor research COPY, injecting before the native
 join and calling an explicit real join only for controlled test cleanup.

 This is an observable false-stopped-state counterexample. There is NO
 real pthread failure or proven recoverable native-join path.
+/
module concurrency.research.p20_fault_consumer;

import concurrency.research.m1_p20_owned_fault : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.memory : GC;
import core.stdc.stdlib : abort;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;

private void require(bool okay, string description)
{
    if (!okay)
        throw new Exception("P20: " ~ description);
}

private final class Gate
{
    Semaphore semaphore;
    shared uint started;

    this() { semaphore = new Semaphore(0); }

    void block()
    {
        atomicStore!(MemoryOrder.rel)(started, 1u);
        semaphore.wait();
    }

    void releaseOrAbort()
    {
        try
            semaphore.notify();
        catch (Throwable)
            abort();
    }
}

private final class Receipt
{
    shared uint runs;
}

private struct OwnedJob
{
    Gate gate;
    Receipt receipt;

    int opCall()
    {
        gate.block();
        atomicStore!(MemoryOrder.rel)(receipt.runs, 1u);
        return 71;
    }
}

// A distinct strong root that survives controller-handle abandonment.
// It is NOT a substitute for GC-independent native worker ownership.
private final class OwnerSupervisor
{
    private OwnedTaskExecutor owned;
    private bool nativeJoined;

    this(OwnedTaskExecutor executor)
    {
        owned = executor;
    }

    bool holdsOwner() { return owned !is null; }
    bool hasNativeProof() { return nativeJoined; }

    bool tryReleaseRoot()
    {
        if (!nativeJoined)
            return false;
        owned = null;
        return true;
    }

    void finishInjectedFaultByRealJoinOrAbort()
    {
        if (nativeJoined || owned is null)
            abort();
        // Instrumented owned layer fail-stops if an ACTUAL join now fails.
        try
            owned.researchProveJoinAfterInjectedFault();
        catch (Throwable)
            abort();
        nativeJoined = true;
    }

    bool apparentStopped() { return owned.isStopped(); }
    size_t retained() { return owned.retainedCount(); }
    size_t completed() { return owned.completedCount(); }
    size_t admitted() { return owned.acceptedCount(); }
}

private void waitUntilBlocked(Gate gate)
{
    const end = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.started) != 1u)
    {
        require(MonoTime.currTime < end, "native worker not blocked");
        Thread.yield();
    }
}

private void testRealM0EarlyStopped()
{
    auto gate = new Gate();
    auto receipt = new Receipt();
    auto controller = new OwnedTaskExecutor(1, 2, 2);
    OwnerSupervisor supervisor;
    {
        OwnedJob job;
        job.gate = gate;
        job.receipt = receipt;
        auto handle = controller.submit(job);
        require(handle !is null, "accepted job absent");
        handle = null;
    }

    supervisor = new OwnerSupervisor(controller);
    controller.researchInjectBeforeJoin();
    try
    {
        waitUntilBlocked(gate);
        bool sawInjectedFailure;
        try
            controller.closeAndJoin();
        catch (Exception error)
            sawInjectedFailure = error.msg == "P20 synthetic pre-join fault";

        require(sawInjectedFailure, "expected synthetic close failure missing");
        require(controller.isStopped(), "actual M0 did not mark STOPPED");
        require(controller.acceptedCount() == 1, "admission disappeared");
        require(controller.completedCount() == 0, "blocked task completed early");
        require(controller.retainedCount() == 1, "root cleared before join");
        require(atomicLoad!(MemoryOrder.acq)(receipt.runs) == 0u,
            "worker escaped blocker");

        // The submitting controller is gone: only supervisor retains
        // the executor, and the worker still has outstanding work.
        controller = null;
        foreach (_; 0 .. 4)
        {
            GC.collect();
            require(supervisor.apparentStopped(), "STOPPED flag changed");
            require(!supervisor.hasNativeProof(), "join proof invented");
            require(supervisor.holdsOwner(), "strong owner abandoned");
            require(!supervisor.tryReleaseRoot(),
                "uncertain executor root released");
            require(supervisor.retained() == 1,
                "accepted record reaped without quiescence");
            require(supervisor.completed() == 0,
                "worker unexpectedly completed while blocked");
        }
    }
    finally
    {
        // Even when a test oracle fails, a still-blocked actual M0 worker
        // must be unblocked and really joined before the frame unwinds.
        gate.releaseOrAbort();
        supervisor.finishInjectedFaultByRealJoinOrAbort();
    }

    require(supervisor.hasNativeProof(), "native join was not performed");
    require(supervisor.admitted() == 1 && supervisor.completed() == 1,
        "native completion obligation not met");
    require(supervisor.retained() == 0,
        "root survived proven joined shutdown");
    require(atomicLoad!(MemoryOrder.acq)(receipt.runs) == 1u,
        "owned graph executed incorrect number of times");
    require(supervisor.tryReleaseRoot(), "joined owner root not releasable");
    require(!supervisor.holdsOwner(), "supervisor still retains executor");
}

void main()
{
    testRealM0EarlyStopped();
    writeln("P20_OWNED_UNKNOWN_JOIN_PASS stopped_not_quiescent=1 real_join=1");
}
