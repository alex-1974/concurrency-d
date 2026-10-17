module concurrency.research.p42_multi_producer;
version (P42Baseline)
    import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
else
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
private void produce(SubmissionWorkerPool pool, shared Record[] records,
                     size_t begin, size_t end)
{
    foreach (i; begin .. end)
    {
        TaskRef task = TaskRef(&records[i].header);
        for (;;)
        {
            final switch (pool.trySubmit(task))
            {
                case SubmissionResult.accepted: break;
                case SubmissionResult.full:
                    Thread.yield();
                    continue;
                case SubmissionResult.closed:
                    assert(false, "unexpected close before producers finish");
            }
            break;
        }
    }
}
private Thread makeProducer(SubmissionWorkerPool pool, shared Record[] data,
                            size_t first, size_t last)
{
    return new Thread({ produce(pool, data, first, last); });
}
void main()
{
    enum producers = 4;
    enum perProducer = 64;
    enum total = producers * perProducer;
    foreach (round; 0 .. 8)
    {
        auto pool = new SubmissionWorkerPool(4, 8);
        auto records = new shared Record[total];
        foreach (ref record; records)
            record.header.execute = &execute;
        Thread[] threads;
        foreach (index; 0 .. producers)
        {
            const first = index * perProducer;
            const last = first + perProducer;
            threads ~= makeProducer(pool, records, first, last);
        }
        foreach (thread; threads) thread.start();
        foreach (thread; threads) thread.join();
        pool.closeAndJoin();
        assert(pool.acceptedCount() == total);
        assert(pool.completedCount() == total);
        foreach (ref record; records)
            assert(atomicLoad!(MemoryOrder.acq)(record.hits) == 1u);
    }
    writeln("P42_MULTI_PRODUCER_PASS producers=4 workers=4 tasks=256 rounds=8");
}
