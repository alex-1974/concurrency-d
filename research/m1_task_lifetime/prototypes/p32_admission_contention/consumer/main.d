module concurrency.research.p32_consumer;

// Research-only: identical TaskRef records, workers and producer work in
// the pinned original M0 and generated P15-timed M0.
version (P32Timed)
{
    import concurrency.research.m1_p15_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad;
import core.stdc.stdlib : abort;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.conv : to;
import std.stdio : writeln;

private struct Job
{
    @disable this(this);
    TaskHeader header;
    shared uint calls;
}

private void execute(shared(TaskHeader)* raw) @trusted nothrow @nogc
{
    auto job = cast(shared(Job)*)raw;
    atomicFetchAdd!(MemoryOrder.rel)(job.calls, 1u);
}

private Thread producer(SubmissionWorkerPool pool, Job[] jobs,
                        size_t index, size_t producers,
                        shared size_t* attempts, shared size_t* successes)
{
    // Each producer owns disjoint Job records (strided by producer count).
    return new Thread({
        const deadline = MonoTime.currTime + dur!"seconds"(30);
        for (size_t i = index; i < jobs.length; i += producers)
        {
            for (;;)
            {
                if (MonoTime.currTime >= deadline)
                    abort(); // borrowing remains live while worker may be active
                atomicFetchAdd!(MemoryOrder.rel)(*attempts, cast(size_t)1);
                const status = pool.trySubmit(
                    TaskRef(cast(shared(TaskHeader)*)&jobs[i].header));
                if (status == SubmissionResult.accepted)
                {
                    atomicFetchAdd!(MemoryOrder.rel)(*successes, cast(size_t)1);
                    break;
                }
                if (status != SubmissionResult.full)
                    abort();
                Thread.yield();
            }
        }
    });
}

private void startOrAbort(Thread thread)
{
    try thread.start();
    catch (Throwable) abort(); // native start-after-launch is uncertain
}

private void joinOrAbort(Thread thread)
{
    try thread.join(false);
    catch (Throwable) abort();
}

private void runArm(string phase, size_t round, size_t tasks,
                    size_t workers, size_t producers, size_t ingress)
{
    if (tasks == 0 || tasks % producers != 0 || workers == 0 || ingress == 0)
        throw new Exception("P32 invalid dimensions");

    auto jobs = new Job[tasks];
    foreach (ref job; jobs)
    {
        job.header.execute = &execute;
        job.calls = 0;
    }
    auto pool = new SubmissionWorkerPool(workers, ingress);
    auto threads = new Thread[producers];
    auto tries = new shared size_t[producers];
    auto done = new shared size_t[producers];
    foreach (i; 0 .. producers)
        threads[i] = producer(pool, jobs, i, producers, &tries[i], &done[i]);

    const begun = MonoTime.currTime;
    foreach (thread; threads)
        startOrAbort(thread);
    foreach (thread; threads)
        joinOrAbort(thread);
    const submitted = MonoTime.currTime;
    try pool.closeAndJoin();
    catch (Throwable) abort();
    const joined = MonoTime.currTime;

    size_t attempts, accepted;
    foreach (i; 0 .. producers)
    {
        attempts += atomicLoad!(MemoryOrder.acq)(tries[i]);
        accepted += atomicLoad!(MemoryOrder.acq)(done[i]);
    }
    if (accepted != tasks || attempts < accepted ||
        pool.acceptedCount() != tasks || pool.completedCount() != tasks)
        throw new Exception("P32 incorrect admission/completion counts");
    foreach (ref job; jobs)
        if (atomicLoad!(MemoryOrder.acq)(job.calls) != 1)
            throw new Exception("P32 missing or duplicate record execution");

    ulong submitCalls, submitWait, submitHold, batchCalls, completeCalls;
    version (P32Timed)
    {
        auto snapshot = pool.p15Snapshot();
        submitCalls = snapshot.entries[0].calls;
        submitWait = snapshot.entries[0].waitNs;
        submitHold = snapshot.entries[0].holdNs;
        batchCalls = snapshot.entries[1].calls;
        completeCalls = snapshot.entries[2].calls;
        if (submitCalls != attempts || completeCalls != tasks ||
            batchCalls == 0)
            throw new Exception("P32 lock-site conservation failed");
    }
    writeln(phase, ",", round, ",", producers, ",", tasks, ",",
        workers, ",", ingress, ",", accepted, ",", attempts, ",",
        pool.completedCount(), ",",
        (submitted - begun).total!"nsecs", ",",
        (joined - submitted).total!"nsecs", ",",
        submitCalls, ",", submitWait, ",", submitHold, ",",
        batchCalls, ",", completeCalls);
}

void main(string[] args)
{
    size_t tasks = 384, workers = 4, ingress = 32, warmup = 1, rounds = 3;
    for (size_t i = 1; i < args.length; i += 2)
    {
        if (i + 1 >= args.length) throw new Exception("missing argument");
        const val = to!size_t(args[i + 1]);
        switch (args[i])
        {
            case "--count": tasks = val; break;
            case "--workers": workers = val; break;
            case "--ingress": ingress = val; break;
            case "--warmup": warmup = val; break;
            case "--rounds": rounds = val; break;
            default: throw new Exception("unknown P32 option");
        }
    }
    if (rounds < 3 || rounds > 20 || warmup > 3 || tasks == 0 ||
        tasks > 100_000 || tasks % 4 != 0 || workers == 0 || ingress == 0)
        throw new Exception("P32 invalid experimental bounds");
    writeln("phase,round,producers,count,workers,ingress,accepted,attempts,",
        "completed,submit_ns,join_ns,submit_calls,submit_wait_ns,",
        "submit_hold_ns,batch_calls,complete_calls");
    foreach (r; 0 .. rounds + warmup)
    {
        foreach (offset; 0 .. 3)
        {
            const size_t[3] variants = [1, 2, 4];
            const producers = variants[(offset + r) % variants.length];
            runArm(r < warmup ? "warmup" : "measure", r, tasks,
                   workers, producers, ingress);
        }
    }
    writeln("P32_M0_CONTROL_TIMED_PASS");
}
