module concurrency.research.p42_20_owned;
import concurrency.research.p42_owned : OwnedTaskExecutor;
import core.atomic : atomicLoad, atomicFetchAdd, atomicStore, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime, dur;
import core.memory : GC;
import std.stdio : writeln;

private void require(bool ok) { if (!ok) throw new Exception("P42.20 owned check failed"); }
private struct ValueJob { int value; this(int v) { value = v; } int opCall() { return value * 7; } }
private struct VoidJob { shared uint* hits; this(shared uint* p) { hits = p; } void opCall() { atomicFetchAdd!(MemoryOrder.rel)(*hits, 1u); } }
private struct FailingJob { int opCall() { throw new Exception("P42.20 expected task exception"); } }
private struct CountJob
{
    shared uint* hits;
    this(shared uint* p) { hits = p; }
    int opCall() { atomicFetchAdd!(MemoryOrder.rel)(*hits, 1u); return 42; }
}
private Thread producer(OwnedTaskExecutor executor, shared uint[] hits, shared uint[] accepted,
                         size_t first, size_t last)
{
    return new Thread({
        foreach (i; first .. last)
        {
            for (;;)
            {
                try
                {
                    auto handle = executor.trySubmit(CountJob(&hits[i]));
                    if (handle is null) { Thread.yield(); continue; }
                    atomicStore!(MemoryOrder.rel)(accepted[i], 1u);
                    break;
                }
                catch (Exception error)
                {
                    // Only an expected closed admission may terminate producer.
                    require(error.msg == "executor is closed");
                    return;
                }
            }
        }
    });
}
void main()
{
    // Actual owner/result/reaper implementation, only its pool import differs.
    foreach (workers; [1, 4])
    {
        auto executor = new OwnedTaskExecutor(workers, 8, 16);
        auto hits = new shared uint[1];
        auto value = executor.submit(ValueJob(6));
        auto nothing = executor.submit(VoidJob(&hits[0]));
        auto failure = executor.submit(FailingJob.init);
        require(value.get() == 42);
        nothing.get();
        bool observed;
        try { failure.get(); }
        catch (Exception error) { observed = error.msg == "P42.20 expected task exception"; }
        require(observed);
        auto end = MonoTime.currTime + dur!"seconds"(5);
        while (executor.reclaimCompleted() != 0)
        {
            require(MonoTime.currTime < end);
            Thread.yield();
        }
        GC.collect();
        require(value.get() == 42 && atomicLoad!(MemoryOrder.acq)(hits[0]) == 1);
        // Failed result cell also remains usable after the record was reaped.
        observed = false;
        try { failure.get(); }
        catch (Exception error) { observed = error.msg == "P42.20 expected task exception"; }
        require(observed);
        executor.closeAndJoin();
        executor.closeAndJoin();
        require(executor.isStopped() && executor.retainedCount() == 0);
        require(executor.acceptedCount() == 3 && executor.completedCount() == 3);
    }
    // Each candidate has a distinct record. Seed successful admission so a
    // close race cannot pass solely through rejecting every producer.
    foreach (round; 0 .. 12)
    {
        enum count = 256;
        auto executor = new OwnedTaskExecutor(4, 8, 32);
        auto hits = new shared uint[count];
        auto accepted = new shared uint[count];
        auto seed = executor.submit(CountJob(&hits[0]));
        atomicStore!(MemoryOrder.rel)(accepted[0], 1u);
        Thread[] producers;
        foreach (i; 0 .. 4)
            producers ~= producer(executor, hits, accepted,
                1 + i * (count - 1) / 4, 1 + (i + 1) * (count - 1) / 4);
        foreach (p; producers) p.start();
        foreach (_; 0 .. round) Thread.yield();
        // Two external callers exercise the real idempotent close protocol.
        auto otherCloser = new Thread({ executor.closeAndJoin(); });
        otherCloser.start();
        executor.closeAndJoin();
        otherCloser.join();
        foreach (p; producers) p.join();
        size_t total;
        foreach (i; 0 .. count)
        {
            const admitted = atomicLoad!(MemoryOrder.acq)(accepted[i]);
            require(admitted <= 1 && atomicLoad!(MemoryOrder.acq)(hits[i]) == admitted);
            total += admitted;
        }
        require(total >= 1 && executor.acceptedCount() == total && executor.completedCount() == total);
        require(executor.isStopped() && executor.retainedCount() == 0 && seed.get() == 42);
    }
    writeln("P42_20_OWNED_PASS typed_void_exception_reap=2 concurrent_close=12 producers=4");
}
