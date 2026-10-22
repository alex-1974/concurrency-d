/++ P23 research: source-pinned actual M0 OwnedTaskExecutor with deferred
    launch, supervisor roots and explicitly distinct native join outcomes.
    All arbitrary callable submission remains @system; no public API. +/
module concurrency.research.p23_consumer;

import concurrency.research.m1_p23_owned : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.memory : GC;
import core.stdc.stdlib : abort;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;

private void require(bool ok, string what)
{
    if (!ok)
        throw new Exception("P23: " ~ what);
}

private final class Gate
{
    Semaphore sem;
    shared uint entered;
    this() { sem = new Semaphore(0); }
    void block()
    {
        atomicFetchAdd!(MemoryOrder.rel)(entered, 1u);
        sem.wait();
    }
    void releaseOrAbort()
    {
        try sem.notify();
        catch (Throwable) abort();
    }
}

private final class Graph
{
    int data;
    Graph next;
    this(int value, Graph tail = null) { data = value; next = tail; }
}

private final class Receipt
{
    shared uint runs;
    shared uint total;
}

private struct Job
{
    Gate gate;
    Graph graph;
    Receipt receipt;

    int opCall()
    {
        gate.block();
        const result = cast(uint)(graph.data + 3 * graph.next.data);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.runs, 1u);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.total, result);
        return cast(int)result;
    }
}

// Root installation precedes the REAL M0 native pool constructor.
private final class Supervisor
{
    private OwnedTaskExecutor owner;
    this(OwnedTaskExecutor e) { owner = e; }
    OwnedTaskExecutor get() { return owner; }
    bool holds() { return owner !is null; }
    void start() { owner.researchStart(); }
    bool tryDiscard()
    {
        if (owner is null || !owner.isStopped())
            return false;
        require(owner.retainedCount() == 0, "joined roots not cleared");
        owner = null;
        return true;
    }
    void finishKnownSyntheticOrAbort()
    {
        if (owner is null)
            abort();
        try owner.researchJoinKnownSynthetic();
        catch (Throwable) abort();
    }
}

private void awaitStarted(Gate gate)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entered) == 0u)
    {
        require(MonoTime.currTime < deadline, "worker never entered task");
        Thread.yield();
    }
}

private Thread closer(OwnedTaskExecutor owner,
    shared uint* complete, shared uint* synthetic)
{
    // Separate frame, never capture a reused foreach iteration variable.
    return new Thread({
        try
        {
            owner.closeAndJoin();
            atomicFetchAdd!(MemoryOrder.rel)(*complete, 1u);
        }
        catch (Exception ex)
        {
            if (ex.msg == "P23 synthetic before-native-join")
                atomicFetchAdd!(MemoryOrder.rel)(*synthetic, 1u);
            else
                throw ex;
        }
    });
}

private void signalOrAbort(Semaphore sem)
{
    try sem.notify();
    catch (Throwable) abort();
}

private void joinAllOrAbort(Thread[3] threads)
{
    foreach (t; threads)
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
}

private void requireResults(Receipt receipt, uint expected)
{
    require(atomicLoad!(MemoryOrder.acq)(receipt.runs) == 1u,
        "accepted task must execute exactly once");
    require(atomicLoad!(MemoryOrder.acq)(receipt.total) == expected,
        "nested GC payload graph checksum mismatch");
}

private void testNormal()
{
    auto owner = new OwnedTaskExecutor(1, 3, 4);
    auto supervisor = new Supervisor(owner);
    require(owner.researchConstructed() && supervisor.holds(),
        "no independent root before native start");
    supervisor.start(); // the actual unmodified M0 SubmissionWorkerPool
    require(owner.isAccepting(), "real pool not running");

    auto gate = new Gate();
    auto receipt = new Receipt();
    Job task;
    task.gate = gate;
    task.graph = new Graph(5, new Graph(7));
    task.receipt = receipt;
    auto handle = owner.submit(task);
    require(handle !is null, "normal admission");
    handle = null;
    awaitStarted(gate);

    shared uint complete, synthetic;
    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = closer(owner, &complete, &synthetic);
        closers[i].start();
    }
    try
    {
        require(!supervisor.tryDiscard(), "root freed before native join");
        require(owner.retainedCount() == 1, "active task prematurely reaped");
    }
    finally
    {
        gate.releaseOrAbort();
        joinAllOrAbort(closers);
    }

    require(owner.isStopped() && !owner.researchUncertain(),
        "joined condition absent");
    require(owner.researchJoinClaims() == 1, "duplicate real pool join");
    require(atomicLoad!(MemoryOrder.acq)(complete) == 3u &&
        atomicLoad!(MemoryOrder.acq)(synthetic) == 0u,
        "normal concurrent closer results changed");
    require(owner.acceptedCount() == 1 &&
        owner.completedCount() == 1 && owner.retainedCount() == 0,
        "normal M0 conservation failure");
    requireResults(receipt, 26u);
    owner = null;
    require(supervisor.tryDiscard(), "normal strong root not released");
}

private void waitTwoClosers(OwnedTaskExecutor owner)
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (owner.researchWaiters() < 2)
    {
        require(MonoTime.currTime < deadline, "closers never waited");
        Thread.yield();
    }
}

private void testSyntheticPreJoin()
{
    auto owner = new OwnedTaskExecutor(1, 3, 4);
    auto supervisor = new Supervisor(owner);
    require(owner.researchConstructed() && supervisor.holds(),
        "prelaunch owner missing");
    supervisor.start();
    auto gate = new Gate();
    auto receipt = new Receipt();
    Job task;
    task.gate = gate;
    task.graph = new Graph(7, new Graph(11));
    task.receipt = receipt;
    auto handle = owner.submit(task);
    require(handle !is null, "prejoin admission");
    handle = null;
    awaitStarted(gate);

    auto beforeJoin = new Semaphore(0);
    owner.researchInjectPreJoin(beforeJoin);
    shared uint complete, synthetic;
    Thread[3] closers;
    foreach (i; 0 .. closers.length)
    {
        closers[i] = closer(owner, &complete, &synthetic);
        closers[i].start();
    }
    try
    {
        waitTwoClosers(owner); // actual Condition.wait rendezvous
        require(!supervisor.tryDiscard(), "draining released roots");
        require(owner.retainedCount() == 1, "draining reclaimed in-flight");
    }
    finally
    {
        signalOrAbort(beforeJoin);
        joinAllOrAbort(closers);
    }

    require(owner.researchUncertain() && !owner.isStopped(),
        "false joinedStopped after injected failure");
    require(owner.researchJoinClaims() == 1,
        "multiple real join owners before fault");
    require(atomicLoad!(MemoryOrder.acq)(complete) == 0u &&
        atomicLoad!(MemoryOrder.acq)(synthetic) == 3u,
        "concurrent closers did not see same fault");
    require(owner.retainedCount() == 1 && owner.acceptedCount() == 1 &&
        owner.completedCount() == 0,
        "unknown native join lost accepted obligation");
    require(!supervisor.tryDiscard(), "uncertain root lost");
    owner = null;
    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(supervisor.holds() && supervisor.get().researchUncertain(),
            "supervisor graph lost after handle drop");
        require(supervisor.get().retainedCount() == 1,
            "uncertain record lost during forced GC");
        require(!supervisor.tryDiscard(), "premature root reclamation");
    }

    gate.releaseOrAbort();
    // NO native join has previously been attempted on this synthetic arm.
    supervisor.finishKnownSyntheticOrAbort(); // real successful join
    require(supervisor.get().isStopped() &&
        supervisor.get().researchJoinClaims() == 2 &&
        supervisor.get().retainedCount() == 0,
        "subsequent actual join did not prove release");
    require(supervisor.get().acceptedCount() == 1 &&
        supervisor.get().completedCount() == 1,
        "post-join completion missing");
    requireResults(receipt, 40u);
    require(supervisor.tryDiscard(), "joined uncertain owner still held");
}

private void testAfterPoolLaunch()
{
    auto owner = new OwnedTaskExecutor(1, 3, 4);
    auto supervisor = new Supervisor(owner);
    require(owner.researchConstructed(), "after-start path not deferred");
    owner.researchInjectAfterStart();
    supervisor.start(); // the real M0 pool was successfully constructed
    require(owner.researchUncertain() && !owner.isAccepting(),
        "injected after-start incorrectly admits work");
    require(!supervisor.tryDiscard(), "unknown native worker root released");
    owner = null;
    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(supervisor.holds() && supervisor.get().researchUncertain(),
            "post-start strong root not preserved");
    }
    supervisor.finishKnownSyntheticOrAbort();
    require(supervisor.get().isStopped() &&
        supervisor.get().acceptedCount() == 0 &&
        supervisor.get().completedCount() == 0,
        "empty real pool did not join");
    require(supervisor.tryDiscard(), "post-start root leaked after join");
}

private int smallTask()
{
    return 23;
}

private Thread makeProducer(OwnedTaskExecutor executor, shared uint* admitted)
{
    // Independent thread activation avoids a reused outer foreach frame.
    return new Thread({
        foreach (_; 0 .. 64)
        {
            try
            {
                auto h = executor.trySubmit(&smallTask);
                if (h !is null)
                    atomicFetchAdd!(MemoryOrder.rel)(*admitted, 1u);
                else
                    Thread.yield();
            }
            catch (Exception)
            {
                // Only operations accepted before the close linearization
                // contribute a completion obligation.
                break;
            }
        }
    });
}

private void testProducerRace()
{
    auto owner = new OwnedTaskExecutor(2, 8, 256);
    auto supervisor = new Supervisor(owner);
    require(owner.researchConstructed(), "producer owner started early");
    supervisor.start();

    shared uint admitted;
    Thread[4] producers;
    foreach (i; 0 .. producers.length)
    {
        producers[i] = makeProducer(owner, &admitted);
        try producers[i].start();
        catch (Throwable) abort(); // ambiguous native producer start
    }

    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (owner.acceptedCount() == 0)
    {
        require(MonoTime.currTime < deadline, "no producers admitted");
        Thread.yield();
    }

    // Close while producer methods may still be trying to publish.
    try owner.closeAndJoin();
    catch (Throwable) abort();
    foreach (p; producers)
    {
        try
        {
            auto problem = p.join(false);
            if (problem !is null)
                abort();
        }
        catch (Throwable)
            abort();
    }

    require(owner.isStopped(), "producer close did not prove native join");
    require(owner.researchJoinClaims() == 1, "multiple producer join claims");
    require(owner.acceptedCount() ==
        atomicLoad!(MemoryOrder.acq)(admitted),
        "producer acknowledgements differ from accepted obligations");
    require(owner.completedCount() == owner.acceptedCount(),
        "producer racing close lost a TaskRef completion");
    require(owner.retainedCount() == 0,
        "postjoin producer roots not reclaimed");

    bool rejected;
    try owner.trySubmit(&smallTask);
    catch (Exception) rejected = true;
    require(rejected, "closed executor accepted late producer");

    owner = null;
    require(supervisor.tryDiscard(), "producer-root not released");
}

void main()
{
    foreach (_; 0 .. 6)
    {
        testNormal();
        testSyntheticPreJoin();
        testAfterPoolLaunch();
        testProducerRace();
    }
    writeln("P23_REAL_M0_LIFECYCLE_PASS normal=6 prejoin=6 poststart=6 producer=6");
}
