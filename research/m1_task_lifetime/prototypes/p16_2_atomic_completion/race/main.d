/++
 P16.2 RESEARCH ONLY adversarial close/completion/producer stress.
 The original M0 and proposed seq-cst completion copy run the identical
 protocol and observable checks. No public @safe promise.
+/
module concurrency.research.p16_2_close_races;

version (P162Atomic)
{
    import concurrency.research.m1_p16_2_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}
import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic :
    MemoryOrder, atomicLoad, atomicStore, atomicFetchAdd, pause;
import core.stdc.stdlib : abort;
import core.thread : Thread;
import std.conv : to;
import std.stdio : writeln;

private struct Record
{
    TaskHeader header;
    shared uint entered;
    shared uint released;
    shared uint executed;
}

private void verify(bool condition, string message)
{
    if (!condition)
        throw new Exception("P16.2 " ~ message);
}

private void blockingExecute(shared(TaskHeader)* raw) @trusted nothrow
{
    auto r = cast(Record*) raw;
    atomicStore!(MemoryOrder.seq)(r.entered, 1u);
    while (atomicLoad!(MemoryOrder.seq)(r.released) == 0u)
        pause();
    atomicFetchAdd!(MemoryOrder.seq)(r.executed, 1u);
}

private void immediateExecute(shared(TaskHeader)* raw) @trusted nothrow
{
    auto r = cast(Record*) raw;
    atomicFetchAdd!(MemoryOrder.seq)(r.executed, 1u);
}

private void spinUntil(scope bool delegate() check, string message)
{
    foreach (_; 0 .. 2_000_000)
    {
        if (check())
            return;
        Thread.yield();
    }
    throw new Exception("P16.2 bounded rendezvous failed: " ~ message);
}

private void closedBeforeLastCompletion(size_t workers, size_t ingress)
{
    Record record;
    record.header.execute = &blockingExecute;
    auto pool = new SubmissionWorkerPool(workers, ingress);
    verify(pool.trySubmit(TaskRef(cast(shared(TaskHeader)*) &record.header))
           == SubmissionResult.accepted, "initial blocking submit");

    spinUntil(
        { return atomicLoad!(MemoryOrder.seq)(record.entered) == 1u; },
        "wait for actual task execution");

    // Closing thread holds the native join boundary while its last task
    // has NOT completed. Other workers can be sleeping on Condition.wait.
    auto closer = new Thread({
        try
            pool.closeAndJoin();
        catch (Throwable)
            abort(); // unresolved native join failure: research fail-stop
    });
    closer.start();

    // No pending inbox entries: the only task is already executing.
    // hasIngressCapacity()==false therefore establishes _closed=true
    // under the SAME original publication mutex (in both variants).
    spinUntil({ return !pool.hasIngressCapacity(); },
              "close must linearize before final completion");
    verify(atomicLoad!(MemoryOrder.seq)(record.executed) == 0u,
           "blocking worker completed before release");
    atomicStore!(MemoryOrder.seq)(record.released, 1u);

    closer.join();
    verify(atomicLoad!(MemoryOrder.seq)(record.executed) == 1u,
           "closed-before-final task was not executed exactly once");
    verify(pool.acceptedCount() == 1 && pool.completedCount() == 1,
           "closed-before-final completion obligation mismatch");
    verify(pool.trySubmit(TaskRef(cast(shared(TaskHeader)*) &record.header))
           == SubmissionResult.closed,
           "closed pool admitted work after successful native join");
}

private void completedBeforeClose(size_t workers, size_t ingress)
{
    Record record;
    record.header.execute = &blockingExecute;
    auto pool = new SubmissionWorkerPool(workers, ingress);
    verify(pool.trySubmit(TaskRef(cast(shared(TaskHeader)*) &record.header))
           == SubmissionResult.accepted, "completed-before-close admission");
    spinUntil(
        { return atomicLoad!(MemoryOrder.seq)(record.entered) == 1u; },
        "worker never entered task");
    atomicStore!(MemoryOrder.seq)(record.released, 1u);
    spinUntil({ return pool.completedCount() == 1; },
              "completion before close did not commit");
    pool.closeAndJoin();
    verify(atomicLoad!(MemoryOrder.seq)(record.executed) == 1u,
           "completed-before-close execution mismatch");
}

private Thread startProducer(
    SubmissionWorkerPool pool, Record[] records, shared(uint)[] accepted,
    size_t offset, size_t stride)
{
    // Independent invocation frame; do not close over a reused loop slot.
    return new Thread({
        for (size_t i = offset; i < records.length; i += stride)
        {
            for (;;)
            {
                auto refTask = TaskRef(
                    cast(shared(TaskHeader)*) &records[i].header);
                const decision = pool.trySubmit(refTask);
                if (decision == SubmissionResult.accepted)
                {
                    atomicStore!(MemoryOrder.seq)(accepted[i], 1u);
                    break;
                }
                if (decision == SubmissionResult.closed)
                    return;
                verify(decision == SubmissionResult.full,
                    "unexpected producer decision");
                Thread.yield();
            }
        }
    });
}

private void closeDuringProducers(size_t workers, size_t ingress)
{
    enum size_t Jobs = 256;
    enum size_t Producers = 3;
    auto records = new Record[Jobs];
    auto accepted = new shared uint[Jobs];
    foreach (i; 0 .. Jobs)
        records[i].header.execute = &immediateExecute;

    auto pool = new SubmissionWorkerPool(workers, ingress);
    Thread[Producers] producers;
    foreach (id; 0 .. Producers)
    {
        producers[id] = startProducer(pool, records, accepted, id, Producers);
        producers[id].start();
    }

    // Publication/closure race: some admissions may succeed, others reject.
    // No attempt to predict accepted count; verify against actual decisions.
    Thread.yield();
    pool.closeAndJoin();
    foreach (producer; producers)
        producer.join();

    size_t admitted;
    foreach (i; 0 .. Jobs)
    {
        const wasAccepted = atomicLoad!(MemoryOrder.seq)(accepted[i]);
        const executed = atomicLoad!(MemoryOrder.seq)(records[i].executed);
        verify(wasAccepted <= 1u && executed == wasAccepted,
               "concurrent admission/completion exactly-once mismatch");
        admitted += wasAccepted;
    }
    verify(pool.acceptedCount() == admitted &&
           pool.completedCount() == admitted,
           "concurrent close lost completion obligations");
}

void main(string[] args)
{
    size_t rounds = 4;
    if (args.length == 2)
        rounds = to!size_t(args[1]);
    verify(rounds > 0 && rounds <= 100, "invalid bounded race repetitions");
    size_t scenarios;
    foreach (_; 0 .. rounds)
    {
        foreach (workers; [1u, 2u, 4u])
        foreach (ingress; [1u, 8u, 64u])
        {
            closedBeforeLastCompletion(workers, ingress);
            completedBeforeClose(workers, ingress);
            closeDuringProducers(workers, ingress);
            scenarios += 3;
        }
    }
    writeln("P16.2 close/complete/park/producer-race PASS scenarios=", scenarios);
}
