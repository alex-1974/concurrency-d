module concurrency.research.p42_20_races;
import concurrency.research.p42_barrier_pool : SubmissionWorkerPool, SubmissionResult, P42Barrier;
import concurrency.internal.task_record : TaskRef, TaskHeader;
import core.atomic : atomicLoad, atomicStore, atomicFetchAdd, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;
import core.stdc.stdlib : exit;

private struct Record
{
    TaskHeader header;
    shared uint hits;
    bool block;
    shared uint release;
}
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto r = cast(shared(Record)*) p;
    atomicFetchAdd!(MemoryOrder.rel)(r.hits, 1u);
    while (r.block && atomicLoad!(MemoryOrder.acq)(r.release) == 0) Thread.yield();
}
private bool until(bool delegate() predicate, long milliseconds = 5000)
{
    auto end = MonoTime.currTime + dur!"msecs"(milliseconds);
    while (!predicate())
    {
        if (MonoTime.currTime >= end) return false;
        Thread.yield();
    }
    return true;
}
private void require(bool ok) { if (!ok) throw new Exception("P42.20 race check failed"); }
void main(string[] args)
{
    // Synchronize publication against ticket capture and completed empty search.
    foreach (site; [1, 2, 3])
    {
        auto gate = new P42Barrier(site);
        auto records = new shared Record[1];
        records[0].header.execute = &execute;
        auto pool = new SubmissionWorkerPool(1, 2, null, gate);
        gate.waitReached();
        require(pool.trySubmit(TaskRef(&records[0].header)) == SubmissionResult.accepted);
        gate.release();
        // No close broadcast until the task has executed: close must not mask a missed wake.
        require(until({ return atomicLoad!(MemoryOrder.acq)(records[0].hits) == 1; }));
        pool.closeAndJoin();
        require(pool.acceptedCount() == 1 && pool.completedCount() == 1);
    }
    foreach (site; [1, 2, 3])
    {
        auto gate = new P42Barrier(site);
        auto pool = new SubmissionWorkerPool(1, 2, null, gate);
        gate.waitReached();
        pool.p42CloseInbox(); // Real inbox close transition while worker is paused.
        gate.release();
        pool.closeAndJoin();
        require(pool.acceptedCount() == 0 && pool.completedCount() == 0);
    }
    // Confirm wait enrollment under the actual inbox mutex before publishing.
    {
        auto records = new shared Record[1];
        records[0].header.execute = &execute;
        auto pool = new SubmissionWorkerPool(1, 2);
        require(until({ return pool.waiterCount() == 1; }));
        require(pool.trySubmit(TaskRef(&records[0].header)) == SubmissionResult.accepted);
        const ran = until({ return atomicLoad!(MemoryOrder.acq)(records[0].hits) == 1; }, 1500);
        if (args.length == 2 && args[1] == "silent")
        {
            require(!ran);
            writeln("P42_20_SILENT_CONTROL_DETECTED before_close=true");
            pool.closeAndJoin(); // Rescue and drain; never free a live record.
            require(atomicLoad!(MemoryOrder.acq)(records[0].hits) == 1);
            exit(23);
        }
        require(ran);
        pool.closeAndJoin();
    }
    // Prefill before worker launch to force a two-record inbox batch. Pause
    // after claim, BEFORE owner-deque publication. The peer must enroll first.
    {
        auto gate = new P42Barrier(4);
        auto records = new shared Record[2];
        foreach (ref r; records) r.header.execute = &execute;
        records[0].block = true;
        TaskRef[] initial = [TaskRef(&records[0].header), TaskRef(&records[1].header)];
        auto pool = new SubmissionWorkerPool(2, 2, null, gate, initial);
        gate.waitReached();
        require(until({ return pool.waiterCount() == 1; }));
        gate.release();
        // Owner executes the first record and blocks; peer must steal second
        // following the preserved local-work notification, before close.
        const bothRan = until({ return atomicLoad!(MemoryOrder.acq)(records[0].hits) == 1 &&
                              atomicLoad!(MemoryOrder.acq)(records[1].hits) == 1; }, 1500);
        if (args.length == 2 && args[1] == "no-local")
        {
            require(!bothRan);
            writeln("P42_20_LOCAL_CONTROL_DETECTED before_owner_release=true");
            atomicStore!(MemoryOrder.rel)(records[0].release, 1u);
            pool.closeAndJoin();
            foreach (ref r; records) require(atomicLoad!(MemoryOrder.acq)(r.hits) == 1);
            exit(24);
        }
        require(bothRan);
        atomicStore!(MemoryOrder.rel)(records[0].release, 1u);
        pool.closeAndJoin();
        require(pool.acceptedCount() == 2 && pool.completedCount() == 2);
        foreach (ref r; records) require(atomicLoad!(MemoryOrder.acq)(r.hits) == 1);
    }
    writeln("P42_20_RACES_PASS publish=3 close=3 enrolled=1 local_handoff=1");
}
