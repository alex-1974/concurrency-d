module concurrency.research.p42_benchmark;
version (P42Baseline)
    import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
else
    import concurrency.research.m1_p42_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;
import core.thread : Thread;
import std.datetime.stopwatch : StopWatch;
import std.conv : to;
import std.stdio : writeln;

private struct Record { TaskHeader header; shared uint hits; shared uint work; }
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto r = cast(shared(Record)*) p;
    // A dependent, per-task atomic sequence keeps work observable under -O3.
    version (P42MediumTask)
    {
        foreach (_; 0 .. 32)
            atomicFetchAdd!(MemoryOrder.rel)(r.work, 1u);
    }
    atomicFetchAdd!(MemoryOrder.rel)(r.hits, 1u);
}
private void producer(SubmissionWorkerPool pool, shared Record[] tasks,
                      size_t first, size_t last)
{
    foreach (i; first .. last)
    {
        auto task = TaskRef(&tasks[i].header);
        for (;;)
        {
            auto result = pool.trySubmit(task);
            if (result == SubmissionResult.accepted) break;
            assert(result == SubmissionResult.full);
            Thread.yield();
        }
    }
}
private Thread makeProducer(SubmissionWorkerPool pool, shared Record[] tasks,
                            size_t first, size_t last)
{
    return new Thread({ producer(pool, tasks, first, last); });
}
void main(string[] args)
{
    if (args.length != 4) throw new Exception("usage: benchmark producers workers tasks");
    const producers = args[1].to!size_t;
    const workers = args[2].to!size_t;
    const count = args[3].to!size_t;
    if (producers == 0 || workers == 0 || count < producers ||
        count % producers != 0)
        throw new Exception("invalid benchmark dimensions");
    auto records = new shared Record[count];
    foreach (ref r; records) r.header.execute = &execute;
    StopWatch timer;
    timer.start();
    auto pool = new SubmissionWorkerPool(workers, 256);
    Thread[] producersThreads;
    const part = count / producers;
    foreach (i; 0 .. producers)
        producersThreads ~= makeProducer(pool, records, i * part, (i + 1) * part);
    foreach (t; producersThreads) t.start();
    foreach (t; producersThreads) t.join();
    pool.closeAndJoin();
    timer.stop();
    if (pool.acceptedCount() != count || pool.completedCount() != count)
        throw new Exception("accepted/completed task totals mismatch");
    foreach (ref r; records)
        if (atomicLoad!(MemoryOrder.acq)(r.hits) != 1u)
            throw new Exception("task executed other than once");
    version (P42MediumTask)
        foreach (ref r; records)
            if (atomicLoad!(MemoryOrder.acq)(r.work) != 32u)
                throw new Exception("medium task work count mismatch");
    version (P42Baseline) enum arm = "baseline";
    else enum arm = "conditional";
    writeln("P42_BENCH arm=", arm, " producers=", producers, " workers=",workers,
        " tasks=", count, " elapsed_us=",timer.peek.total!"usecs");
}
