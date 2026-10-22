/++
 M1 P08: RESEARCH ONLY: owned value payload retention across a simulated
 *uncertain* executor shutdown, contrasted with borrowed TaskRefs from P07.

 No real failed OS join is induced or recovered here. A TaskHandle/ResultCell
 is not task-record ownership, and an OwnedNode is not transitive ownership
 of arbitrary pointer/delegate captures.

 This test keeps a controller-owned strong root while worker execution is
 outstanding, simulates a join failure, forces GC, then establishes true
 quiescence with a subsequent *successful* real native Thread.join(false).
 No general safety, portability, error recovery, or performance claim.
+/
module concurrency.research.m1_owned_uncertainty;

import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.memory : GC;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.stdio : writeln;

private final class Gate
{
    Mutex lock;
    Condition changed;
    bool opened;
    bool entered;

    this()
    {
        lock = new Mutex();
        changed = new Condition(lock);
    }

    // Test-only trusted wrappers: Condition.wait()/notifyAll() are system
    // under pinned druntime; all accesses hold precisely this Gate.lock.
    void block() @trusted
    {
        synchronized (lock)
        {
            entered = true;
            changed.notifyAll();
            while (!opened)
                changed.wait();
        }
    }

    void awaitEntry() @trusted
    {
        synchronized (lock)
        {
            while (!entered)
                changed.wait();
        }
    }

    void open() @trusted
    {
        synchronized (lock)
        {
            opened = true;
            changed.notifyAll();
        }
    }
}

// A deliberately alias-free by-value operation with GC-owned storage.
// In contrast to an arbitrary delegate, there is no pointer to producer
// stack or to mutable external consumer-owned state in this payload.
private final class ValueNode
{
    int input;
    int output;
    this(int value) { input = value; }
}

private final class WorkerReceipt
{
    shared uint returned;
}

private void delegate() workerAction(
    ValueNode node, WorkerReceipt receipt, Gate gate) @system
{
    // Fresh invocation => distinct closure frame. Do not capture a mutable
    // foreach/local slot then mutate it after passing the delegate.
    return ()
    {
        gate.block();
        node.output = node.input * 3;
        // This is the last node access; the worker may still be executing.
        atomicStore!(MemoryOrder.rel)(receipt.returned, 1u);
    };
}

/++
 Controller-rooted owned-value worker. This does not reuse the production
 OwnedTaskExecutor: it isolates just the ownership/liveness mechanism.
+/
private final class RetainedValueExecutor
{
    private enum State : ubyte { ready, running, uncertain, joined }

    private ValueNode ownedNode;
    private WorkerReceipt receipt;
    private Gate gate;
    private Thread thread;
    private State state;
    private bool rootRetainedOnUncertainty;

    this(int value)
    {
        ownedNode = new ValueNode(value);
        receipt = new WorkerReceipt();
        gate = new Gate();
        state = State.ready;
    }

    void launch() @system
    {
        assert(state == State.ready);
        thread = new Thread(workerAction(ownedNode, receipt, gate));
        thread.start();
        state = State.running;
    }

    void awaitWorkerEntry() @system
    {
        gate.awaitEntry();
    }

    void simulateUncertainJoin() @system
    {
        assert(state == State.running);
        assert(atomicLoad!(MemoryOrder.acq)(receipt.returned) == 0u);
        // IMPORTANT: This does not actually invoke pthread_join.
        // There is no evidence that a real failing join could be retried.
        state = State.uncertain;
        rootRetainedOnUncertainty = (ownedNode !is null);
        throw new Exception("P08 synthetic join uncertainty");
    }

    bool remainsUncertain() @system
    {
        return state == State.uncertain;
    }

    bool stillOwnsNode() @system
    {
        return rootRetainedOnUncertainty && ownedNode !is null;
    }

    bool taskReturned() @system
    {
        return atomicLoad!(MemoryOrder.acq)(receipt.returned) != 0u;
    }

    int confirmedResult() @system
    {
        assert(state == State.joined);
        assert(ownedNode !is null);
        return ownedNode.output;
    }

    void releaseGate() @system
    {
        gate.open();
    }

    void joinSuccessfully() @system
    {
        assert(state == State.uncertain || state == State.running);
        // A successful OS join is the actual post-dispatch barrier.
        // Only now is it permitted to discard the retained node.
        auto failure = thread.join(false);
        assert(failure is null);
        assert(taskReturned());
        state = State.joined;
    }

    void releaseOwnership() @system
    {
        assert(state == State.joined);
        ownedNode = null;
        rootRetainedOnUncertainty = false;
    }
}

private void collectOnce() @system
{
    GC.collect();
}

private void testOwnedValueSurvival() @system
{
    auto executor = new RetainedValueExecutor(14);
    executor.launch();
    executor.awaitWorkerEntry();

    bool uncertaintyObserved;
    try
        executor.simulateUncertainJoin();
    catch (Exception ex)
        uncertaintyObserved = ex.msg == "P08 synthetic join uncertainty";
    assert(uncertaintyObserved);
    assert(executor.remainsUncertain());
    assert(executor.stillOwnsNode());
    assert(!executor.taskReturned());

    // The external controller deliberately retains executor/ownedNode.
    // Forced collections may not reclaim a strongly reachable node.
    foreach (i; 0 .. 4)
    {
        collectOnce();
        assert(executor.remainsUncertain());
        assert(executor.stillOwnsNode());
        assert(!executor.taskReturned());
    }

    // A real successful join follows: unlike a failed native join, this
    // proves that the worker cannot access the node again.
    executor.releaseGate();
    executor.joinSuccessfully();
    assert(executor.taskReturned());
    assert(executor.confirmedResult() == 42);
    executor.releaseOwnership();
}

private void testRepeatedOwnedCycles() @system
{
    // New owner and own closure for each thread. No consumer stack pointer
    // is published to a worker, and no unjoined worker is abandoned.
    foreach (i; 0 .. 24)
    {
        auto executor = new RetainedValueExecutor(cast(int)i + 1);
        executor.launch();
        executor.awaitWorkerEntry();
        executor.releaseGate();
        executor.joinSuccessfully();
        assert(executor.confirmedResult() == (cast(int)i + 1) * 3);
        executor.releaseOwnership();
    }
}

void main()
{
    testOwnedValueSurvival();
    testRepeatedOwnedCycles();
    writeln("P08 owned value retention: PASS (uncertain state keeps GC root, ",
        "forced GC, successful later join, 24 independent cycles)");
}
