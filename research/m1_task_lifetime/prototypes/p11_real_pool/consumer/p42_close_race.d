module concurrency.research.p42_close_race;
version (P42Baseline)
    import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
else
    import concurrency.research.m1_p42_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint hits;
    shared uint admitted;
}
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    atomicFetchAdd!(MemoryOrder.rel)(record.hits, 1u);
}
private void produce(SubmissionWorkerPool pool, shared Record[] records,
                     size_t first, size_t last)
{
    foreach (i; first .. last)
    {
        auto task = TaskRef(&records[i].header);
        for (;;)
        {
            auto result = pool.trySubmit(task);
            if (result == SubmissionResult.accepted)
            {
                atomicStore!(MemoryOrder.rel)(records[i].admitted, 1u);
                break;
            }
            if (result == SubmissionResult.closed)
                return;
            assert(result == SubmissionResult.full);
            Thread.yield();
        }
    }
}
private Thread makeProducer(SubmissionWorkerPool pool, shared Record[] records,
                            size_t first, size_t last)
{
    return new Thread({ produce(pool, records, first, last); });
}
void main()
{
    enum producers = 4;
    enum tasksPerProducer = 48;
    enum total = producers * tasksPerProducer;
    foreach (round; 0 .. 16)
    {
        auto pool = new SubmissionWorkerPool(4, 8);
        auto records = new shared Record[total];
        foreach (ref record; records)
            record.header.execute = &execute;
        Thread[] producersThreads;
        foreach (i; 0 .. producers)
            producersThreads ~= makeProducer(pool, records,
                i * tasksPerProducer, (i + 1) * tasksPerProducer);
        foreach (thread; producersThreads)
            thread.start();
        // Vary close relative to active producer admission.
        foreach (_; 0 .. (round % 8))
            Thread.yield();
        pool.closeAndJoin();
        foreach (thread; producersThreads)
            thread.join();
        size_t admitted;
        foreach (ref record; records)
        {
            const accepted = atomicLoad!(MemoryOrder.acq)(record.admitted);
            const hits = atomicLoad!(MemoryOrder.acq)(record.hits);
            assert(accepted <= 1u);
            assert(hits == accepted);
            admitted += accepted;
        }
        assert(pool.acceptedCount() == admitted);
        assert(pool.completedCount() == admitted);
    }
    writeln("P42_CLOSE_RACE_PASS rounds=16 producers=4 workers=4");
}
