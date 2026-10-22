module concurrency.tests.m0_lifecycle;

import concurrency.internal.owned_task : OwnedTaskExecutor;
import concurrency.internal.submission_pool : SubmissionWorkerPool, SubmissionResult;
import concurrency.internal.task_record : TaskHeader, TaskRef;
import concurrency.errors : WorkerSelfJoinException;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime, dur;
import core.memory : GC;
import core.stdc.stdlib : abort;
import std.stdio : writeln;

private void require(bool valid, string message)
{
    // A failed test must not unwind potentially live borrowed storage.
    if (!valid)
    {
        import core.stdc.stdio : fputs, stderr;
        fputs("M0_LIFECYCLE_TEST_FAILURE\n", stderr);
        abort();
    }
}

private final class Gate
{
    shared uint entered, released;
    void wait()
    {
        atomicStore!(MemoryOrder.rel)(entered, 1u);
        while (atomicLoad!(MemoryOrder.acq)(released) == 0) Thread.yield();
    }
    void untilEntered()
    {
        const end = MonoTime.currTime + dur!"seconds"(5);
        while (atomicLoad!(MemoryOrder.acq)(entered) == 0)
        {
            require(MonoTime.currTime < end, "gate did not enter");
            Thread.yield();
        }
    }
    void release() { atomicStore!(MemoryOrder.rel)(released, 1u); }
}

private struct SelfCloseJob
{
    OwnedTaskExecutor executor;
    Gate gate;
    int opCall()
    {
        if (gate !is null) gate.wait();
        executor.closeAndJoin(); // Must become the handle's ordinary error.
        return -1;
    }
}
private struct BlockJob
{
    Gate gate;
    void opCall() { gate.wait(); }
}
private struct ValueJob { int opCall() { return 42; } }
private struct ExceptionJob { int opCall() { throw new Exception("ordinary task failure"); } }
private struct ErrorJob { int opCall() { throw new Error("recorded task error"); } }
private struct CloseOtherJob
{
    OwnedTaskExecutor other;
    int opCall() { other.closeAndJoin(); return 17; }
}

private void ownCloseBeforeDrain()
{
    auto executor = new OwnedTaskExecutor(2, 8);
    SelfCloseJob job;
    job.executor = executor;
    auto handle = executor.submit(job);
    bool rejected;
    try { handle.get(); }
    catch (WorkerSelfJoinException) { rejected = true; }
    require(rejected, "worker close not rejected");
    require(executor.isAccepting() && !executor.isStopped(), "self-close changed lifecycle");
    require(executor.submit(ValueJob.init).get() == 42, "executor cannot continue after self-close");
    executor.closeAndJoin();
    require(executor.acceptedCount() == 2 && executor.completedCount() == 2, "self-close lost work");
}

private void ownCloseDuringDrain()
{
    auto executor = new OwnedTaskExecutor(2, 8);
    auto gate = new Gate;
    SelfCloseJob job;
    job.executor = executor;
    job.gate = gate;
    auto handle = executor.submit(job);
    gate.untilEntered();
    auto closer = new Thread({ executor.closeAndJoin(); });
    closer.start();
    const end = MonoTime.currTime + dur!"seconds"(5);
    while (executor.isAccepting())
    {
        require(MonoTime.currTime < end, "controller did not start drain");
        Thread.yield();
    }
    require(!executor.isStopped(), "close completed while worker is gated");
    GC.collect();
    gate.release();
    closer.join();
    bool rejected;
    try { handle.get(); }
    catch (WorkerSelfJoinException) { rejected = true; }
    require(rejected && executor.isStopped() && executor.retainedCount() == 0, "draining self-close failed");
}

private struct RawRecord
{
    TaskHeader header;
    SubmissionWorkerPool pool;
    shared uint rejected;
}
private void rawSelfClose(shared(TaskHeader)* header) @trusted nothrow
{
    auto record = cast(RawRecord*) header;
    try { record.pool.closeAndJoin(); }
    catch (WorkerSelfJoinException)
    {
        atomicStore!(MemoryOrder.rel)(record.rejected, 1u);
    }
    catch (Throwable) { abort(); }
}
private void rawPoolGuard()
{
    auto pool = new SubmissionWorkerPool(1, 2);
    auto record = new RawRecord;
    record.pool = pool;
    record.header.execute = &rawSelfClose;
    require(pool.trySubmit(TaskRef(cast(shared(TaskHeader)*)&record.header)) == SubmissionResult.accepted,
        "raw admission failed");
    pool.closeAndJoin();
    require(atomicLoad!(MemoryOrder.acq)(record.rejected) == 1, "raw pool did not guard self-close");
    require(pool.completedCount() == 1, "raw task lost");
}

private void taskErrorsAndOtherPool()
{
    auto executor = new OwnedTaskExecutor(2, 8);
    auto other = new OwnedTaskExecutor(1, 2);
    auto failure = executor.submit(ExceptionJob.init);
    auto taskError = executor.submit(ErrorJob.init);
    bool caught;
    try { failure.get(); }
    catch (Exception error) { caught = error.msg == "ordinary task failure"; }
    require(caught, "ordinary task Exception did not propagate");
    caught = false;
    try { taskError.get(); }
    catch (Error error) { caught = error.msg == "recorded task error"; }
    require(caught, "existing recorded task Error behavior changed");
    CloseOtherJob closeOther;
    closeOther.other = other;
    require(executor.submit(closeOther).get() == 17 && other.isStopped(), "foreign pool close rejected");
    require(executor.submit(ValueJob.init).get() == 42, "worker TLS leaked");
    executor.closeAndJoin();
    executor.closeAndJoin();
    require(executor.acceptedCount() == 4 && executor.completedCount() == 4, "task accounting changed");
    require(executor.retainedCount() == 0, "records not reclaimed");
}

void main(string[] args)
{
    if (args.length > 1 && args[1] == "construction-failure")
    {
        bool observed;
        try { auto executor = new OwnedTaskExecutor(3, 8); }
        catch (Exception error) { observed = error.msg == "M0 injected before launch"; }
        require(observed, "construction error not propagated");
        writeln("M0_CONSTRUCTION_CLEANUP_PASS");
        return;
    }
    if (args.length > 1 && args[1] == "fatal")
    {
        auto executor = new OwnedTaskExecutor(2, 8);
        if (args.length > 2 && (args[2] == "join" || args[2] == "close" || args[2] == "owner"))
        {
            auto gate = new Gate;
            BlockJob job;
            job.gate = gate;
            auto handle = executor.submit(job);
            gate.untilEntered(); // A real worker/record is live at the fault.
        }
        if (args.length > 2 && args[2] == "result-failure")
        {
            auto failed = executor.submit(ExceptionJob.init);
            failed.get(); // Outcome-publication failure must terminate, not hang.
        }
        executor.closeAndJoin();
        writeln("M0_FATAL_TEST_UNEXPECTED_RETURN");
        return;
    }
    foreach (_; 0 .. 8)
    {
        ownCloseBeforeDrain();
        ownCloseDuringDrain();
        rawPoolGuard();
        taskErrorsAndOtherPool();
    }
    writeln("M0_LIFECYCLE_PASS rounds=8 self_close=running,draining raw_guard=1 foreign_close=1 task_errors=2");
}
