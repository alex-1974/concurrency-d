module concurrency.research.p42_wait_publish;
import concurrency.research.m1_p42_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;
import core.thread : Thread;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint hits;
}
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    atomicFetchAdd!(MemoryOrder.rel)(record.hits, 1u);
}
private void untilPark(SubmissionWorkerPool pool)
{
    foreach (_; 0 .. 300_000)
    {
        if (pool.parkCount() != 0) return;
        Thread.yield();
    }
    throw new Exception("P41 did not observe an actual wait-entry counter");
}
void main()
{
    foreach (_; 0 .. 12)
    {
        auto pool = new SubmissionWorkerPool(1, 2);
        untilPark(pool);
        auto record = new shared Record[1];
        record[0].header.execute = &execute;
        assert(pool.trySubmit(TaskRef(&record[0].header)) == SubmissionResult.accepted);
        pool.closeAndJoin();
        assert(pool.acceptedCount() == 1);
        assert(pool.completedCount() == 1);
        assert(atomicLoad!(MemoryOrder.acq)(record[0].hits) == 1u);
    }
    writeln("P42_WAIT_PUBLISH_PASS cases=12");
    writeln("P42_WAIT_PUBLISH_LIMIT observed wait entry; not an atomic proof of sleeping at publish");
}
