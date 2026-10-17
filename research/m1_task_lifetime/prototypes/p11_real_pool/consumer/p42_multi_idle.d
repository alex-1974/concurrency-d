module concurrency.research.p42_multi_idle;
version (P42Baseline)
    import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
else
    import concurrency.research.m1_p42_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint hits;
    shared long startTicks;
}
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    record.startTicks = MonoTime.currTime.ticks;
    atomicFetchAdd!(MemoryOrder.rel)(record.hits, 1u);
}
private void awaitWaitEntries(SubmissionWorkerPool pool, size_t count)
{
    foreach (_; 0 .. 500_000)
    {
        if (pool.parkCount() >= count) return;
        Thread.yield();
    }
    throw new Exception("not all workers entered condition wait");
}
void main()
{
    enum workers = 4;
    enum rounds = 12;
    foreach (tasks; [1, 4, 32])
    {
        foreach (round; 0 .. rounds)
        {
            auto pool = new SubmissionWorkerPool(workers, 64);
            awaitWaitEntries(pool, workers);
            auto records = new shared Record[tasks];
            foreach (ref rec; records) rec.header.execute = &execute;
            auto begin = MonoTime.currTime.ticks;
            foreach (ref rec; records)
            {
                if (pool.trySubmit(TaskRef(&rec.header)) != SubmissionResult.accepted)
                    throw new Exception("unexpected ingress rejection");
            }
            size_t finished;
            foreach (_; 0 .. 500_000)
            {
                finished = 0;
                foreach (ref rec; records)
                    if (atomicLoad!(MemoryOrder.acq)(rec.hits) == 1u) ++finished;
                if (finished == tasks) break;
                Thread.yield();
            }
            if (finished != tasks)
                throw new Exception("tasks did not finish before close");
            pool.closeAndJoin();
            if (pool.acceptedCount() != tasks || pool.completedCount() != tasks)
                throw new Exception("completion counts mismatch");
            long maxTicks;
            foreach (ref rec; records)
            {
                if (atomicLoad!(MemoryOrder.acq)(rec.hits) != 1u)
                    throw new Exception("once-only invariant");
                const duration = rec.startTicks - begin;
                if (duration < 0) throw new Exception("nonmonotonic timestamp");
                if (duration > maxTicks) maxTicks = duration;
            }
            version (P42Baseline) enum arm = "baseline";
            else enum arm = "conditional";
            writeln("P42_MULTI_IDLE arm=", arm, " tasks=", tasks,
                " round=", round, " max_publish_to_start_ticks=", maxTicks);
        }
    }
    writeln("P42_MULTI_IDLE_PASS workers=4 rounds=12 cases=3");
}
