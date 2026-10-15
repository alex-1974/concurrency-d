/++
 P24: process-reachable explicit GC-root registry over a SOURCE-PINNED
 research copy of the REAL M0 OwnedTaskExecutor/SubmissionWorkerPool.
 No public API and no general @safe proof. All registry operations here
 occur on the control thread; only the test's native closer is concurrent.
+/
module concurrency.research.p24_durable_root;

import concurrency.research.m1_p23_owned : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.memory : GC;
import core.stdc.stdlib : abort;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;

private void require(bool ok, string reason)
{
    if (!ok)
        throw new Exception("P24: " ~ reason);
}

private final class RootRegistry
{
    private enum size_t Capacity = 2;
    private Mutex mutex;
    private OwnedTaskExecutor[Capacity] owners;
    private bool[Capacity] rooted;
    private size_t additions;
    private size_t removals;

    this() { mutex = new Mutex(); }

    size_t register(OwnedTaskExecutor executor) @system
    {
        require(executor !is null && executor.researchConstructed(),
            "registry adoption must precede native thread start");
        synchronized (mutex)
        {
            foreach (index; 0 .. Capacity)
            {
                if (rooted[index])
                    continue;

                // The explicit registered GC root outlives every local
                // caller handle. The process registry is also reachable
                // through a module-lifetime anchor.
                GC.addRoot(cast(void*) executor);
                owners[index] = executor;
                rooted[index] = true;
                ++additions;
                return index;
            }
        }
        throw new Exception("P24 fixed registry capacity exceeded");
    }

    OwnedTaskExecutor borrow(size_t id)
    {
        synchronized (mutex)
        {
            require(id < Capacity && rooted[id] && owners[id] !is null,
                "invalid registry lease");
            return owners[id];
        }
    }

    void start(size_t id) @system
    {
        // The native start occurs AFTER the registered explicit GC root.
        borrow(id).researchStart();
    }

    bool tryRelease(size_t id) @system
    {
        synchronized (mutex)
        {
            require(id < Capacity, "invalid registry index");
            if (!rooted[id])
                return false;
            auto executor = owners[id];
            if (!executor.isStopped())
                return false;
            require(executor.retainedCount() == 0,
                "successful native join left accepted task roots");

            // Only a confirmed native-joined executor may be unrooted.
            GC.removeRoot(cast(void*) executor);
            owners[id] = null;
            rooted[id] = false;
            ++removals;
            return true;
        }
    }

    size_t live()
    {
        synchronized (mutex)
        {
            size_t count;
            foreach (active; rooted)
                if (active)
                    ++count;
            return count;
        }
    }

    size_t added()
    {
        synchronized (mutex)
            return additions;
    }

    size_t removed()
    {
        synchronized (mutex)
            return removals;
    }
}

// Process-wide named access point, deliberately separate from the
// short-lived caller handles. Initialized by main before worker launch.
private __gshared RootRegistry processRoots;

private RootRegistry registry()
{
    require(processRoots !is null, "registry not installed");
    return processRoots;
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
    void openOrAbort()
    {
        try sem.notify();
        catch (Throwable) abort();
    }
}

private final class Graph
{
    int value;
    Graph next;
    this(int v, Graph tail = null) { value = v; next = tail; }
}

private final class Receipt
{
    shared uint count;
    shared uint total;
}

private struct Task
{
    Gate gate;
    Graph graph;
    Receipt receipt;
    int opCall()
    {
        gate.block();
        const answer = cast(uint)(graph.value + graph.next.value * 3);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.total, answer);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.count, 1u);
        return cast(int) answer;
    }
}

private void awaitEnter(Gate gate)
{
    const end = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entered) == 0u)
    {
        require(MonoTime.currTime < end, "task did not enter native worker");
        Thread.yield();
    }
}

private void checkReceipt(Receipt receipt, uint expected)
{
    require(atomicLoad!(MemoryOrder.acq)(receipt.count) == 1u,
        "task executed other than exactly once");
    require(atomicLoad!(MemoryOrder.acq)(receipt.total) == expected,
        "owned GC graph checksum mismatch");
}

private void collectWithDroppedHandles(size_t index)
{
    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(registry().live() == 1, "registered owner disappeared");
        require(registry().borrow(index).retainedCount() == 1,
            "accepted record lost while worker blocked");
        require(!registry().tryRelease(index),
            "registry released without native join");
    }
}

private void testNormal()
{
    auto controller = new OwnedTaskExecutor(1, 4, 4);
    const id = registry().register(controller); // before worker starts
    controller = null; // ordinary constructor handle dropped
    registry().start(id);

    auto gate = new Gate();
    auto receipt = new Receipt();
    Task work;
    work.gate = gate;
    work.graph = new Graph(5, new Graph(7));
    work.receipt = receipt;
    {
        auto borrowed = registry().borrow(id);
        auto handle = borrowed.submit(work);
        require(handle !is null, "normal submit rejected");
        handle = null;
    }
    awaitEnter(gate);
    collectWithDroppedHandles(id);
    require(registry().borrow(id).acceptedCount() == 1 &&
        registry().borrow(id).completedCount() == 0,
        "blocked work reported complete");

    // The registry, not an abandoned controller, drives real shutdown.
    gate.openOrAbort();
    registry().borrow(id).closeAndJoin();
    require(registry().borrow(id).isStopped(),
        "normal close did not prove native join");
    require(registry().borrow(id).acceptedCount() == 1 &&
        registry().borrow(id).completedCount() == 1 &&
        registry().borrow(id).retainedCount() == 0,
        "M0 admitted/completed/retained accounting mismatch");
    checkReceipt(receipt, 26u);
    require(registry().tryRelease(id), "joined root not unregistered");
    require(!registry().tryRelease(id), "root removed twice");
}

private Thread startCloser(RootRegistry registry, size_t id,
    shared uint* synthetic)
{
    // Independent thread activation: no escaping reused foreach frame.
    return new Thread({
        auto borrowed = registry.borrow(id);
        try borrowed.closeAndJoin();
        catch (Exception ex)
        {
            if (ex.msg != "P23 synthetic before-native-join")
                throw ex;
            atomicFetchAdd!(MemoryOrder.rel)(*synthetic, 1u);
        }
    });
}

private void joinOrAbort(Thread thread)
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

private void testSyntheticUncertain()
{
    auto controller = new OwnedTaskExecutor(1, 4, 4);
    const id = registry().register(controller);
    controller = null;
    registry().start(id);

    auto gate = new Gate();
    auto receipt = new Receipt();
    Task work;
    work.gate = gate;
    work.graph = new Graph(7, new Graph(11));
    work.receipt = receipt;
    {
        auto borrowed = registry().borrow(id);
        auto handle = borrowed.submit(work);
        require(handle !is null, "uncertain task rejected");
        handle = null;
    }
    awaitEnter(gate);
    auto beforeJoin = new Semaphore(0);
    registry().borrow(id).researchInjectPreJoin(beforeJoin);

    shared uint failures;
    auto closer = startCloser(registry(), id, &failures);
    try closer.start();
    catch (Throwable) abort(); // native start uncertainty, fail-stop

    // Wait for first closer to claim shutdown BEFORE injecting.
    const end = MonoTime.currTime + dur!"seconds"(10);
    while (registry().borrow(id).researchJoinClaims() == 0)
    {
        require(MonoTime.currTime < end, "closer never claimed join");
        Thread.yield();
    }
    require(!registry().tryRelease(id), "draining group freed early");
    try beforeJoin.notify();
    catch (Throwable) abort();
    joinOrAbort(closer);

    require(atomicLoad!(MemoryOrder.acq)(failures) == 1u,
        "synthetic shutdown outcome not delivered");
    require(registry().borrow(id).researchUncertain() &&
        !registry().borrow(id).isStopped(),
        "uncertain native liveness misreported as joined");
    collectWithDroppedHandles(id);

    gate.openOrAbort();
    // Injection happened BEFORE any native Thread.join call.
    // Real successful joins are now mandatory, never a failed-join retry.
    try registry().borrow(id).researchJoinKnownSynthetic();
    catch (Throwable) abort();

    require(registry().borrow(id).isStopped() &&
        registry().borrow(id).retainedCount() == 0,
        "postjoin roots not cleared");
    require(registry().borrow(id).acceptedCount() == 1 &&
        registry().borrow(id).completedCount() == 1,
        "uncertain executor completion obligation lost");
    checkReceipt(receipt, 40u);
    require(registry().tryRelease(id), "known synthetic roots not released");
}

private void testIndependentRoots()
{
    auto first = new OwnedTaskExecutor(1, 4, 4);
    auto second = new OwnedTaskExecutor(1, 4, 4);
    const firstId = registry().register(first);
    const secondId = registry().register(second);
    require(firstId != secondId && registry().live() == 2,
        "two simultaneously registered roots alias");
    first = null;
    second = null;
    registry().start(firstId);
    registry().start(secondId);

    auto firstGate = new Gate();
    auto secondGate = new Gate();
    auto firstReceipt = new Receipt();
    auto secondReceipt = new Receipt();
    Task a;
    a.gate = firstGate;
    a.graph = new Graph(13, new Graph(17));
    a.receipt = firstReceipt;
    Task b;
    b.gate = secondGate;
    b.graph = new Graph(19, new Graph(23));
    b.receipt = secondReceipt;
    {
        auto h1 = registry().borrow(firstId).submit(a);
        auto h2 = registry().borrow(secondId).submit(b);
        require(h1 !is null && h2 !is null,
            "two simultaneous real M0 owners rejected work");
        h1 = null;
        h2 = null;
    }
    awaitEnter(firstGate);
    awaitEnter(secondGate);

    secondGate.openOrAbort();
    registry().borrow(secondId).closeAndJoin();
    require(registry().tryRelease(secondId),
        "second joined executor root not released");
    require(registry().live() == 1,
        "joined executor release cleared unrelated active root");
    checkReceipt(secondReceipt, 88u);

    foreach (_; 0 .. 4)
    {
        GC.collect();
        require(registry().borrow(firstId).retainedCount() == 1 &&
            registry().borrow(firstId).completedCount() == 0,
            "active first owner lost graph after second root removal");
        require(!registry().tryRelease(firstId),
            "remaining active executor root released");
    }

    firstGate.openOrAbort();
    registry().borrow(firstId).closeAndJoin();
    checkReceipt(firstReceipt, 64u);
    require(registry().tryRelease(firstId),
        "remaining joined owner root not released");
    require(registry().live() == 0, "registry still owns released group");
}

void main()
{
    processRoots = new RootRegistry();
    foreach (_; 0 .. 6)
    {
        testNormal();
        testSyntheticUncertain();
    }
    foreach (_; 0 .. 4)
        testIndependentRoots();
    require(registry().live() == 0, "registry retained joined executors");
    require(registry().added() == 20 && registry().removed() == 20,
        "explicit GC.addRoot/removeRoot accounting not balanced");
    writeln("P24_DURABLE_ROOT_PASS normal=6 uncertain=6 independent=4 roots=20 removed=20");
}
