// Deliberately outside package concurrency: no internal imports or access.
module public_api_consumer;

import concurrency : Executor, TaskHandle, ExecutorClosedException, WorkerSelfJoinException;
import core.atomic : atomicLoad, atomicStore, atomicFetchAdd, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime, dur;
import core.memory : GC;
import std.exception : enforce;
import std.stdio : writeln;

static assert(!__traits(compiles, (Executor e) { e.retainedCount(); }));
static assert(!__traits(compiles, (Executor e) { e._impl; }));
static assert(!__traits(compiles, (TaskHandle!int h) { h._cell; }));

private final class Gate
{
    shared uint entered, released;
    void wait()
    {
        atomicStore!(MemoryOrder.rel)(entered, 1u);
        while (atomicLoad!(MemoryOrder.acq)(released) == 0) Thread.yield();
    }
    void untilEntered()
    {
        const end = MonoTime.currTime + dur!"seconds"(5);
        while (atomicLoad!(MemoryOrder.acq)(entered) == 0)
        {
            enforce(MonoTime.currTime < end, "public consumer blocker did not start");
            Thread.yield();
        }
    }
    void release() { atomicStore!(MemoryOrder.rel)(released, 1u); }
}
private struct Block { Gate gate; void opCall() { gate.wait(); } }
private struct Value { int value; int opCall() { return value * 3; } }
private struct Hits
{
    shared uint* hits;
    int opCall() { atomicFetchAdd!(MemoryOrder.rel)(*hits, 1u); return 42; }
}
private int functionResult() { return 42; }
private struct Fail { void opCall() { throw new Exception("public task exception"); } }
private struct SelfClose { Executor executor; void opCall() { executor.closeAndJoin(); } }

private void resultsAndSelfClose()
{
    auto executor = new Executor(2, 8, 8);
    scope(exit) executor.closeAndJoin();
    Value value;
    value.value = 14;
    TaskHandle!int answer = executor.submit(value);
    auto failure = executor.submit(Fail.init);
    SelfClose misuse;
    misuse.executor = executor;
    auto self = executor.submit(misuse);
    enforce(answer.get() == 42 && answer.isComplete(), "typed result mismatch");
    enforce(executor.submit(&functionResult).get() == 42, "function pointer submission failed");
    auto closure = () { return value.value * 3; };
    // Caller keeps captured value alive through the explicit join below.
    enforce(executor.submit(closure).get() == 42, "delegate submission failed");
    bool caught;
    try { failure.get(); }
    catch (Exception error) { caught = error.msg == "public task exception"; }
    enforce(caught, "task exception lost");
    caught = false;
    try { self.get(); }
    catch (WorkerSelfJoinException) { caught = true; }
    enforce(caught, "public self-close error not typed");
    enforce(executor.submit(value).get() == 42, "self-close changed admission");
    executor.closeAndJoin();
    GC.collect();
    enforce(answer.get() == 42, "result lost after join");
    caught = false;
    try { failure.get(); }
    catch (Exception error) { caught = error.msg == "public task exception"; }
    enforce(caught, "error cell lost after join");
    caught = false;
    try { executor.trySubmit(value); }
    catch (ExecutorClosedException) { caught = true; }
    enforce(caught, "closed trySubmit did not reject");
    caught = false;
    try { executor.submit(value); }
    catch (ExecutorClosedException) { caught = true; }
    enforce(caught, "closed submit did not terminate");
}

private void backpressure()
{
    // Single worker executing a void blocker; then one queued task fills ingress.
    auto executor = new Executor(1, 1, 4);
    auto gate = new Gate;
    scope(exit) { gate.release(); executor.closeAndJoin(); }
    Block block;
    block.gate = gate;
    TaskHandle!void blocker = executor.submit(block);
    gate.untilEntered();
    auto hits = new shared uint[2];
    Hits queued;
    queued.hits = &hits[0];
    auto accepted = executor.trySubmit(queued);
    enforce(accepted !is null, "queue not admitted");
    Hits rejected;
    rejected.hits = &hits[1];
    enforce(executor.trySubmit(rejected) is null, "full inbox did not reject");
    gate.release();
    executor.closeAndJoin();
    blocker.get();
    enforce(accepted.get() == 42 && atomicLoad!(MemoryOrder.acq)(hits[0]) == 1 &&
        atomicLoad!(MemoryOrder.acq)(hits[1]) == 0, "rejection created an obligation");

    // Independent retained-budget exhaustion with an otherwise empty inbox.
    auto limited = new Executor(1, 8, 1);
    auto held = new Gate;
    scope(exit) { held.release(); limited.closeAndJoin(); }
    block.gate = held;
    auto only = limited.submit(block);
    held.untilEntered();
    enforce(limited.trySubmit(queued) is null, "record budget did not reject");
    held.release();
    only.get();
    // get may precede returned-marker reclamation; submit retries that boundary.
    enforce(limited.submit(queued).get() == 42, "record budget was not reclaimed");
    limited.closeAndJoin();
}

private final class Graph
{
    int number;
    Graph tail;
    this(int n, Graph t = null) { number = n; tail = t; }
}
private struct GraphJob
{
    Graph payload;
    shared uint* receipt;
    int opCall()
    {
        const value = payload.number + payload.tail.number + payload.tail.tail.number;
        atomicFetchAdd!(MemoryOrder.rel)(*receipt, cast(uint)value);
        return value;
    }
}
private void queueGraphsAndDrop(Executor executor, shared uint[] receipts)
{
    foreach (i; 0 .. receipts.length)
    {
        GraphJob job;
        job.payload = new Graph(1, new Graph(2, new Graph(3)));
        job.receipt = &receipts[i];
        auto handle = executor.submit(job);
        handle = null;
    }
}
private void gcAndDroppedHandles()
{
    auto executor = new Executor(1, 8, 16);
    auto gate = new Gate;
    scope(exit) { gate.release(); executor.closeAndJoin(); }
    Block block;
    block.gate = gate;
    auto blocker = executor.submit(block);
    gate.untilEntered();
    auto receipts = new shared uint[8];
    queueGraphsAndDrop(executor, receipts);
    foreach (_; 0 .. 4) GC.collect();
    foreach (ref receipt; receipts)
        enforce(atomicLoad!(MemoryOrder.acq)(receipt) == 0, "queued graph ran before release");
    gate.release();
    executor.closeAndJoin();
    foreach (ref receipt; receipts)
        enforce(atomicLoad!(MemoryOrder.acq)(receipt) == 6, "dropped-handle graph lost or duplicated");
    blocker.get();
}
private Thread producer(Executor executor, shared uint[] hits, shared uint[] accepted,
    size_t first, size_t last)
{
    return new Thread({
        foreach (i; first .. last)
        {
            Hits job;
            job.hits = &hits[i];
            for (;;)
            {
                try
                {
                    if (executor.trySubmit(job) is null) { Thread.yield(); continue; }
                    atomicStore!(MemoryOrder.rel)(accepted[i], 1u);
                    break;
                }
                catch (ExecutorClosedException) { return; }
            }
        }
    });
}
private void concurrentClose()
{
    foreach (_; 0 .. 8)
    {
        auto executor = new Executor(4, 8, 32);
        auto hits = new shared uint[128];
        auto accepted = new shared uint[128];
        Hits seedJob;
        seedJob.hits = &hits[0];
        auto seed = executor.submit(seedJob);
        atomicStore!(MemoryOrder.rel)(accepted[0], 1u);
        Thread[] producers;
        foreach (i; 0 .. 4)
            producers ~= producer(executor, hits, accepted,
                1 + i * 127 / 4, 1 + (i + 1) * 127 / 4);
        foreach (p; producers) p.start();
        auto otherCloser = new Thread({ executor.closeAndJoin(); });
        otherCloser.start();
        executor.closeAndJoin();
        otherCloser.join();
        foreach (p; producers) p.join();
        foreach (i; 0 .. hits.length)
            enforce(atomicLoad!(MemoryOrder.acq)(hits[i]) == atomicLoad!(MemoryOrder.acq)(accepted[i]),
                "public close/admission race lost or duplicated a task");
        enforce(seed.get() == 42, "seed result lost");
    }
}

void main()
{
    resultsAndSelfClose();
    backpressure();
    gcAndDroppedHandles();
    concurrentClose();
    // Long-lived executor must re-use its retained budget without public sweep.
    auto bounded = new Executor(2, 2, 2);
    scope(exit) bounded.closeAndJoin();
    Value value;
    value.value = 14;
    foreach (_; 0 .. 256) enforce(bounded.submit(value).get() == 42, "budget stalled");
    bounded.closeAndJoin();
    foreach (limits; [[0, 1, 1], [1, 0, 1], [1, 1, 0]])
    {
        bool rejected;
        try { auto invalid = new Executor(limits[0], limits[1], limits[2]); }
        catch (Exception) { rejected = true; }
        enforce(rejected, "invalid limits accepted");
    }
    writeln("PUBLIC_API_PASS typed_void_error=true backpressure=ingress,records gc_graphs=8 close_races=8 budget_reuse=256");
}
