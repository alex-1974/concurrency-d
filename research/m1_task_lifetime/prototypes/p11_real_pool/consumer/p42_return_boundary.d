module concurrency.research.p42_return_boundary;
version (P42Baseline)
    import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
else
    import concurrency.research.m1_p42_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;
import core.memory : GC;
import core.time : dur;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint hits;
    shared uint hookEntered;
    shared uint releaseHook;
    shared uint lastAccess;
}
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    atomicFetchAdd!(MemoryOrder.rel)(record.hits, 1u);
}
// Real existing pool hook; no scheduler instrumentation or source rewrite.
private void afterExecution(TaskRef task) @trusted nothrow
{
    auto record = cast(shared(Record)*) task.ptr;
    atomicStore!(MemoryOrder.rel)(record.hookEntered, 1u);
    while (atomicLoad!(MemoryOrder.acq)(record.releaseHook) == 0)
        Thread.yield();
    // A genuine final record access AFTER completedCount became one.
    atomicStore!(MemoryOrder.rel)(record.lastAccess, 1u);
}
void main()
{
    foreach (workers; [1, 4])
    {
        auto records = new shared Record[1];
        records[0].header.execute = &execute;
        auto pool = new SubmissionWorkerPool(workers, 2, &afterExecution);
        assert(pool.trySubmit(TaskRef(&records[0].header)) == SubmissionResult.accepted);
        while (atomicLoad!(MemoryOrder.acq)(records[0].hookEntered) == 0)
            Thread.yield();
        // This is a deterministic witness that completion is not quiescence.
        assert(pool.acceptedCount() == 1 && pool.completedCount() == 1);
        assert(atomicLoad!(MemoryOrder.acq)(records[0].lastAccess) == 0);
        shared uint joining, joined;
        auto closer = new Thread({
            atomicStore!(MemoryOrder.rel)(joining, 1u);
            pool.closeAndJoin();
            atomicStore!(MemoryOrder.rel)(joined, 1u);
        });
        closer.start();
        bool nativeJoined;
        // Always release and join before the caller's record root expires.
        scope(exit)
        {
            atomicStore!(MemoryOrder.rel)(records[0].releaseHook, 1u);
            if (!nativeJoined) closer.join();
        }
        while (atomicLoad!(MemoryOrder.acq)(joining) == 0)
            Thread.yield();
        GC.collect(); // Caller keeps records rooted throughout the hook.
        Thread.sleep(dur!"msecs"(20));
        // Bounded negative observation, not a scheduling/liveness proof.
        assert(atomicLoad!(MemoryOrder.acq)(joined) == 0);
        atomicStore!(MemoryOrder.rel)(records[0].releaseHook, 1u);
        closer.join();
        nativeJoined = true;
        assert(atomicLoad!(MemoryOrder.acq)(joined) == 1);
        assert(atomicLoad!(MemoryOrder.acq)(records[0].lastAccess) == 1);
        assert(atomicLoad!(MemoryOrder.acq)(records[0].hits) == 1);
    }
    writeln("P42_RETURN_BOUNDARY_PASS workers=1,4 completed_is_not_quiescent=true");
}
