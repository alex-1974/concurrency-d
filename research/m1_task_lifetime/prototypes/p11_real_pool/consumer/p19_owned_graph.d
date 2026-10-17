/++
 M1 P19 — actual M0 OwnedTaskExecutor, retained GC graph under admission,
 queued work, dropped handles and post-dispatch reclamation.

 RESEARCH ONLY. A GC collection + normal execution is not a complete
 ownership proof under D's conservative collector or native failures.
 No arbitrary borrowed/captured caller pointer is certified @safe.
+/
module concurrency.research.p19_owned_graph_consumer;

import concurrency.internal.owned_task : OwnedTaskExecutor;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad, atomicStore;
import core.memory : GC;
import core.stdc.stdlib : abort;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;

private enum size_t QueueCount = 8;

private void require(bool valid, string reason)
{
    if (!valid)
        throw new Exception("P19: " ~ reason);
}

private void drainOrAbort(OwnedTaskExecutor executor)
{
    try
        executor.closeAndJoin();
    catch (Throwable)
    {
        // A failing native join does NOT authorize reclaiming unknown work.
        abort();
    }
}

private final class Gate
{
    Semaphore semaphore;
    shared uint entered;

    this()
    {
        semaphore = new Semaphore(0);
    }

    void block()
    {
        atomicStore!(MemoryOrder.rel)(entered, 1u);
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

private struct Blocker
{
    Gate gate;

    void opCall()
    {
        gate.block();
    }
}

private final class Graph
{
    int value;
    Graph next;

    this(int number, Graph tail = null)
    {
        value = number;
        next = tail;
    }
}

private final class Receipt
{
    shared uint[QueueCount] hits;
    shared uint[QueueCount] results;
}

// The accepted callable is copied into GC-managed OwnedNode storage.
// A graph of GC-managed referents hangs from that copied callable.
private struct GraphTask
{
    Graph payload;
    Receipt receipt;
    size_t slot;

    int opCall()
    {
        require(payload !is null &&
            payload.next !is null &&
            payload.next.next !is null,
            "queued graph lost a nested referent");
        const result = payload.value +
            payload.next.value * 2 +
            payload.next.next.value * 3;
        atomicStore!(MemoryOrder.rel)(
            receipt.results[slot], cast(uint)result);
        atomicFetchAdd!(MemoryOrder.rel)(receipt.hits[slot], 1u);
        return result;
    }
}

// Heap graph and handles are never returned to the calling test. The
// submitting frame ends before the test's forced collections.
private void submitQueuedAndDrop(OwnedTaskExecutor executor, Receipt receipt)
{
    foreach (i; 0 .. QueueCount)
    {
        const n = cast(int)i;
        auto tail = new Graph(n + 3);
        auto middle = new Graph(n + 2, tail);
        auto root = new Graph(n + 1, middle);

        GraphTask task;
        task.payload = root;
        task.receipt = receipt;
        task.slot = i;

        auto handle = executor.submit(task);
        require(handle !is null, "queued submission rejected");
        handle = null; // does not cancel the accepted obligation
    }
}

private void waitEntered(Gate gate)
{
    const limit = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(gate.entered) == 0u)
    {
        require(MonoTime.currTime < limit,
            "worker did not enter the blocker");
        Thread.yield();
    }
}

private void testQueuedGcGraphAfterDroppedHandles()
{
    auto executor = new OwnedTaskExecutor(
        1, QueueCount, QueueCount + 1);
    auto gate = new Gate();
    auto receipt = new Receipt();

    // The blocker is admitted and is the only executing task.
    Blocker blockedWork;
    blockedWork.gate = gate;
    auto blocker = executor.submit(blockedWork);
    require(blocker !is null, "blocker admission rejected");
    blocker = null;

    try
    {
        waitEntered(gate);
        submitQueuedAndDrop(executor, receipt);

        require(executor.acceptedCount() == QueueCount + 1,
            "wrong queued admission count");
        require(executor.completedCount() == 0,
            "worker completed before blocker release");
        require(executor.retainedCount() == QueueCount + 1,
            "owner did not retain all task records");
        require(executor.reclaimCompleted() == QueueCount + 1,
            "unreturned record was reclaimed");

        // No queued callable has run; its graphs live behind OwnedNode.
        foreach (_; 0 .. 4)
            GC.collect();

        require(executor.completedCount() == 0,
            "queued work ran during blocked GC phase");
        require(executor.retainedCount() == QueueCount + 1,
            "forced collection changed explicit retention");
    }
    finally
    {
        gate.releaseOrAbort();
        drainOrAbort(executor);
    }

    require(executor.acceptedCount() == QueueCount + 1,
        "accepted count changed");
    require(executor.completedCount() == QueueCount + 1,
        "accepted work not fully completed");
    require(executor.retainedCount() == 0,
        "owner roots not cleared after successful join");

    foreach (i; 0 .. QueueCount)
    {
        const n = cast(uint)i;
        const expected = (n + 1) + 2 * (n + 2) + 3 * (n + 3);
        require(atomicLoad!(MemoryOrder.acq)(receipt.hits[i]) == 1u,
            "queued graph did not execute exactly once");
        require(atomicLoad!(MemoryOrder.acq)(receipt.results[i]) == expected,
            "nested graph result changed across GC");
    }
}

private struct ScalarTask
{
    int value;
    int opCall()
    {
        return value * 3 + 1;
    }
}

private void testResultAfterRecordReaping()
{
    auto executor = new OwnedTaskExecutor(1, 4, 2);
    ScalarTask task;
    task.value = 17;
    auto handle = executor.submit(task);
    require(handle !is null, "scalar admission rejected");

    try
    {
        require(handle.get() == 52, "scalar result mismatch");

        // Result ready and post-dispatch return are different instants.
        const limit = MonoTime.currTime + dur!"seconds"(10);
        while (executor.reclaimCompleted() != 0)
        {
            require(MonoTime.currTime < limit,
                "completed record never became reclaimable");
            Thread.yield();
        }
        require(executor.retainedCount() == 0,
            "record root survived explicit reaping");

        GC.collect();
        require(handle.get() == 52,
            "result cell was lost with its task record");
        require(executor.acceptedCount() == 1 &&
            executor.completedCount() == 1,
            "reaping changed execution accounting");
    }
    finally
        drainOrAbort(executor);
}

void main()
{
    testQueuedGcGraphAfterDroppedHandles();
    testResultAfterRecordReaping();
    writeln("P19_REAL_OWNED_GC_PASS queued=8 graphs=3 gc=4 result_after_reap=1");
}
