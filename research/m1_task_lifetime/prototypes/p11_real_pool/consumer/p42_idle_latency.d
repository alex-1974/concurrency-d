module concurrency.research.p42_idle_latency;
version (P42Baseline)
    import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
else
    import concurrency.research.m1_p42_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared long startedTicks;
    shared uint hits;
}
private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    atomicStore!(MemoryOrder.rel)(record.startedTicks, MonoTime.currTime.ticks);
    atomicStore!(MemoryOrder.rel)(record.hits, 1u);
}
private void awaitObservedPark(SubmissionWorkerPool pool)
{
    foreach (_; 0 .. 500_000)
    {
        if (pool.parkCount() != 0) return;
        Thread.yield();
    }
    throw new Exception("worker did not enter a wait before deadline");
}
void main()
{
    enum rounds = 64;
    long[rounds] samples;
    foreach (i; 0 .. rounds)
    {
        auto pool = new SubmissionWorkerPool(1, 2);
        awaitObservedPark(pool);
        auto record = new shared Record[1];
        record[0].header.execute = &execute;
        // Producer timestamp is immediately BEFORE admission; elapsed is a
        // publish-attempt-to-task-start upper bound, not pure wake latency.
        const before = MonoTime.currTime.ticks;
        if (pool.trySubmit(TaskRef(&record[0].header)) != SubmissionResult.accepted)
            throw new Exception("admission rejected");
        // Do not close before execution: close() broadcasts and would
        // contaminate the publish-notify wakeup comparison.
        bool executed;
        foreach (_; 0 .. 500_000)
        {
            if (atomicLoad!(MemoryOrder.acq)(record[0].hits) == 1u)
            {
                executed = true;
                break;
            }
            Thread.yield();
        }
        if (!executed)
            throw new Exception("task did not execute before close");
        pool.closeAndJoin();
        const start = atomicLoad!(MemoryOrder.acq)(record[0].startedTicks);
        if (atomicLoad!(MemoryOrder.acq)(record[0].hits) != 1u ||
            pool.acceptedCount() != 1 || pool.completedCount() != 1 ||
            start < before)
            throw new Exception("idle latency / completion invariant failed");
        samples[i] = start - before;
    }
    version (P42Baseline) enum arm = "baseline";
    else enum arm = "conditional";
    foreach (i, ticks; samples)
        writeln("P42_IDLE_SAMPLE arm=", arm, " round=", i,
            " publish_to_start_ticks=", ticks);
    writeln("P42_IDLE_PASS arm=", arm, " rounds=", rounds,
        " limitation=observed_wait_entry_not_confirmed_sleep");
}
