module concurrency.research.p41_ticket_barrier;
import concurrency.research.m1_p41_pool : SubmissionWorkerPool, P41Barrier;
import concurrency.research.m1_p41_pool : SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint hits;
}

private void runRecord(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    atomicFetchAdd!(MemoryOrder.rel)(record.hits, 1u);
}

void main()
{
    foreach (_; 0 .. 12)
    {
        auto gate = new P41Barrier;
        auto pool = new SubmissionWorkerPool(1, 2, null, gate);
        gate.waitForReached();
        // Worker already captured the generation but cannot search or park.
        auto records = new shared Record[1];
        records[0].header.execute = &runRecord;
        assert(pool.trySubmit(TaskRef(&records[0].header)) == SubmissionResult.accepted);
        gate.release();
        pool.closeAndJoin();
        assert(pool.acceptedCount() == 1);
        assert(pool.completedCount() == 1);
        assert(atomicLoad!(MemoryOrder.acq)(records[0].hits) == 1u);
    }
    writeln("P41_TICKET_PUBLISH_RACE_PASS cases=12");
}
