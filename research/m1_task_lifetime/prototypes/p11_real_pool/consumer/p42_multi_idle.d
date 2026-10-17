module concurrency.research.p42_multi_idle;

// P42.16: Both arms use identically instrumented, source-derived overlays.
// Earlier P42 baseline benchmarks continue importing the ORIGINAL M0 module.
version (P42Baseline)
    import concurrency.research.m1_p42_baseline_pool :
        SubmissionWorkerPool, SubmissionResult, P42WaitSnapshot,
        p42CurrentWorkerIndex;
else
    import concurrency.research.m1_p42_pool :
        SubmissionWorkerPool, SubmissionResult, P42WaitSnapshot,
        p42CurrentWorkerIndex;

import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : atomicFetchAdd, atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint hits;
    shared uint workerId;
    shared long publishTicks;
    shared long startTicks;
}

private void execute(shared(TaskHeader)* p) @trusted nothrow
{
    auto record = cast(shared(Record)*) p;
    // One worker writes each accepted record; the release hit is written last.
    // This is diagnostic overhead in BOTH arms, not a pure wake latency probe.
    atomicStore!(MemoryOrder.rel)(
        record.workerId, cast(uint) p42CurrentWorkerIndex());
    atomicStore!(MemoryOrder.rel)(record.startTicks, MonoTime.currTime.ticks);
    atomicFetchAdd!(MemoryOrder.rel)(record.hits, 1u);
}

private P42WaitSnapshot awaitFourWaiters(
    SubmissionWorkerPool pool, size_t count)
{
    foreach (_; 0 .. 500_000)
    {
        if (pool.waiterCount() == count)
        {
            // One consistent under-mutex snapshot for per-worker verification.
            auto snapshot = pool.waitSnapshot();
            if (snapshot.total == count &&
                snapshot.entries.length == count &&
                snapshot.enrolled.length == count)
            {
                bool allEnrolled = true;
                foreach (index; 0 .. count)
                {
                    if (!snapshot.enrolled[index] ||
                        snapshot.entries[index] == 0)
                        allEnrolled = false;
                }
                if (allEnrolled)
                    return snapshot;
            }
        }
        Thread.yield();
    }
    throw new Exception("four simultaneous per-worker wait enrollments not observed");
}

void main()
{
    enum workers = 4;
    enum rounds = 12;
    version (P42Baseline) enum arm = "baseline";
    else enum arm = "conditional";

    foreach (tasks; [1, 4, 32])
    {
        foreach (round; 0 .. rounds)
        {
            auto pool = new SubmissionWorkerPool(workers, 64);
            auto snapshot = awaitFourWaiters(pool, workers);
            auto records = new shared Record[tasks];
            foreach (ref rec; records)
            {
                rec.header.execute = &execute;
                atomicStore!(MemoryOrder.rel)(rec.workerId, uint.max);
            }

            const begin = MonoTime.currTime.ticks;
            foreach (ref rec; records)
            {
                atomicStore!(MemoryOrder.rel)(
                    rec.publishTicks, MonoTime.currTime.ticks);
                if (pool.trySubmit(TaskRef(&rec.header)) !=
                    SubmissionResult.accepted)
                    throw new Exception("unexpected ingress rejection");
            }

            size_t finished;
            foreach (_; 0 .. 500_000)
            {
                finished = 0;
                foreach (ref rec; records)
                    if (atomicLoad!(MemoryOrder.acq)(rec.hits) == 1u)
                        ++finished;
                if (finished == tasks)
                    break;
                Thread.yield();
            }
            if (finished != tasks)
                throw new Exception("tasks did not finish before close");
            pool.closeAndJoin();

            if (pool.acceptedCount() != tasks ||
                pool.completedCount() != tasks)
                throw new Exception("completion counts mismatch");

            size_t[workers] workerTasks;
            long maxBurstTicks;
            foreach (id, ref rec; records)
            {
                if (atomicLoad!(MemoryOrder.acq)(rec.hits) != 1u)
                    throw new Exception("once-only invariant");

                const worker = atomicLoad!(MemoryOrder.acq)(rec.workerId);
                if (worker >= workers)
                    throw new Exception("task executed by unknown worker");
                ++workerTasks[worker];

                const publishTicks =
                    atomicLoad!(MemoryOrder.acq)(rec.publishTicks);
                const startTicks =
                    atomicLoad!(MemoryOrder.acq)(rec.startTicks);
                const ownTicks = startTicks - publishTicks;
                const burstTicks = startTicks - begin;
                if (ownTicks < 0 || burstTicks < 0)
                    throw new Exception("nonmonotonic timestamp");
                if (burstTicks > maxBurstTicks)
                    maxBurstTicks = burstTicks;

                writeln("P42_MULTI_IDLE_TASK arm=", arm,
                        " tasks=", tasks, " round=", round,
                        " task=", id, " worker=", worker,
                        " publish_ticks=", publishTicks,
                        " start_ticks=", startTicks,
                        " own_publish_to_start_ticks=", ownTicks);
            }

            if (workerTasks[0] + workerTasks[1] +
                workerTasks[2] + workerTasks[3] != tasks)
                throw new Exception("worker distribution total mismatch");

            writeln("P42_MULTI_IDLE_WAIT arm=", arm,
                    " tasks=", tasks, " round=", round,
                    " simultaneous_waiters=", snapshot.total,
                    " wait_entries=", snapshot.entries[0], ",",
                    snapshot.entries[1], ",", snapshot.entries[2], ",",
                    snapshot.entries[3],
                    " enrolled=", snapshot.enrolled[0], ",",
                    snapshot.enrolled[1], ",", snapshot.enrolled[2], ",",
                    snapshot.enrolled[3]);

            writeln("P42_MULTI_IDLE arm=", arm,
                    " tasks=", tasks, " round=", round,
                    " max_publish_to_start_ticks=", maxBurstTicks,
                    " work_per_worker=", workerTasks[0], ",",
                    workerTasks[1], ",", workerTasks[2], ",",
                    workerTasks[3]);
        }
    }
    writeln("P42_MULTI_IDLE_PASS workers=4 rounds=12 cases=3 ",
            "wait_evidence=simultaneous_per_worker_enrollments ",
            "worker_distribution=recorded");
}
