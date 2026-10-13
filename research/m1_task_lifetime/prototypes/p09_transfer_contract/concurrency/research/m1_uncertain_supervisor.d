/++
 P09 (RESEARCH ONLY) — explicit shutdownUncertain / joinedStopped states.
 A supervisor roots a GC-owned scalar payload while the external controller
 drops its handle. A simulated join failure NEVER masquerades as a join.
 Only an actually successful later Thread.join(false) allows release.

 This is a retention/state experiment, not a real native join-failure
 recovery claim and not a generic owned executor.
+/
module concurrency.research.m1_uncertain_supervisor;

import core.memory : GC;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.stdio : writeln;

private enum Lifecycle : ubyte
{
    running,
    draining,
    shutdownUncertain,
    joinedStopped
}

private final class ValueNode
{
    int input;
    int output;
    this(int number) { input = number; }
}

private final class Gate
{
    private Mutex mutex;
    private Condition changed;
    private bool entered;
    private bool opened;

    this()
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
    }

    // Test-only druntime synchronization boundary, never consumer API.
    void awaitOpen() @trusted
    {
        synchronized (mutex)
        {
            entered = true;
            changed.notifyAll();
            while (!opened)
                changed.wait();
        }
    }

    void awaitEntry() @trusted
    {
        synchronized (mutex)
        {
            while (!entered)
                changed.wait();
        }
    }

    void open() @trusted
    {
        synchronized (mutex)
        {
            opened = true;
            changed.notifyAll();
        }
    }
}

private void delegate() createWorker(ValueNode node, Gate gate)
{
    return ()
    {
        gate.awaitOpen();
        node.output = node.input * 4;
    };
}

private final class Lease
{
    private Lifecycle phase = Lifecycle.running;
    private ValueNode node;
    private Gate gate;
    private Thread worker;

    this(int argument)
    {
        node = new ValueNode(argument);
        gate = new Gate();
        worker = new Thread(createWorker(node, gate));
        worker.start();
    }

    void waitUntilWorkerParked() { gate.awaitEntry(); }

    void simulateNativeJoinFailure()
    {
        assert(phase == Lifecycle.running);
        phase = Lifecycle.draining;
        // No native pthread_join called, and no result claimed.
        phase = Lifecycle.shutdownUncertain;
        throw new Exception("P09 synthetic join failure");
    }

    bool isUncertain() { return phase == Lifecycle.shutdownUncertain; }
    bool hasValueRoot() { return node !is null; }
    bool isJoinedStopped() { return phase == Lifecycle.joinedStopped; }

    void proveQuiescence()
    {
        assert(phase == Lifecycle.shutdownUncertain);
        gate.open();
        // This actual successful join is THE only quiescence evidence.
        auto failure = worker.join(false);
        assert(failure is null);
        phase = Lifecycle.joinedStopped;
    }

    int result()
    {
        assert(phase == Lifecycle.joinedStopped);
        return node.output;
    }

    void discardRoot()
    {
        assert(phase == Lifecycle.joinedStopped);
        node = null;
    }
}

/++
 Independent owner/supervisor. It intentionally does not hand task memory
 ownership to a result-ready future. It retains the full Lease graph until
 a confirmed native join; an uncertain lease cannot be discarded.
+/
private final class Supervisor
{
    private Lease[] leases;

    void adopt(Lease lease)
    {
        assert(lease !is null);
        leases ~= lease;
    }

    size_t outstanding() { return leases.length; }

    Lease lease(size_t index)
    {
        assert(index < leases.length);
        return leases[index];
    }

    bool tryReleaseJoined(size_t index)
    {
        assert(index < leases.length);
        // The uncertain/ongoing worker state is a retained obligation.
        // Refuse early release instead of merely relying on the caller.
        if (!leases[index].isJoinedStopped())
            return false;

        leases[index].discardRoot();
        leases[index] = leases[$ - 1];
        leases[$ - 1] = null;
        leases.length = leases.length - 1;
        return true;
    }
}

private void testControllerAbandonment()
{
    auto supervisor = new Supervisor();
    {
        auto controllerHandle = new Lease(13);
        controllerHandle.waitUntilWorkerParked();
        supervisor.adopt(controllerHandle);
        bool sawFailure;
        try
            controllerHandle.simulateNativeJoinFailure();
        catch (Exception ex)
            sawFailure = ex.msg == "P09 synthetic join failure";
        assert(sawFailure);
        assert(controllerHandle.isUncertain());
        // Explicitly discard the caller handle; supervisor remains owner.
        controllerHandle = null;
    }

    foreach (_; 0 .. 4)
    {
        GC.collect();
        assert(supervisor.outstanding() == 1);
        assert(supervisor.lease(0).isUncertain());
        assert(supervisor.lease(0).hasValueRoot());
        assert(!supervisor.tryReleaseJoined(0));
        assert(supervisor.outstanding() == 1);
    }

    supervisor.lease(0).proveQuiescence();
    assert(supervisor.lease(0).result() == 52);
    assert(supervisor.tryReleaseJoined(0));
    assert(supervisor.outstanding() == 0);
}

private void testFreshLeases()
{
    auto supervisor = new Supervisor();
    foreach (n; 1 .. 17)
    {
        auto lease = new Lease(n);
        supervisor.adopt(lease);
        lease.waitUntilWorkerParked();
        bool sawFailure;
        try
            lease.simulateNativeJoinFailure();
        catch (Exception ex)
            sawFailure = true;
        assert(sawFailure);
        assert(!supervisor.tryReleaseJoined(0));
        lease.proveQuiescence();
        assert(lease.result() == n * 4);
        assert(supervisor.tryReleaseJoined(0));
    }
    assert(supervisor.outstanding() == 0);
}

void main()
{
    testControllerAbandonment();
    testFreshLeases();
    writeln("P09 supervisor lifecycle: PASS (uncertain roots across handle drop, ",
        "GC, actual joinedStopped, 16 leases)");
}
