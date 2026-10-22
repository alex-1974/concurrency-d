/++
 P18 RESEARCH ONLY: source-identical M0 versus one bounded idle-grace retry.
 One semaphore-blocked task; 16 unique runnable sibling TaskRefs; two/four
 independent producer threads and two/four real workers.

 This is a correctness/progress observation, not a throughput, energy,
 starvation-freedom, or public @safe TaskScope qualification. TaskRef is
 non-owning. All records, semaphore and producer frames remain rooted until
 every started producer and pool worker have successfully joined.
+/
module concurrency.research.p18_multiworker_progress;

version (P18Grace)
{
    import concurrency.research.m1_p18_grace_pool :
        SubmissionResult, SubmissionWorkerPool;
}
else
{
    import concurrency.internal.submission_pool :
        SubmissionResult, SubmissionWorkerPool;
}

import concurrency.internal.task_record : TaskHeader, TaskRef;
import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicFetchAdd;
import core.stdc.stdlib : abort;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur;
import std.stdio : writeln;
import std.conv : to;

private enum size_t Siblings = 16;
private enum size_t Total = Siblings + 1;

private struct Record
{
    @disable this(this);
    TaskHeader header;
    size_t id;
    bool blocking;
    Semaphore gate;
    Thread executor;
    shared uint entered;
    shared uint executed;
    shared uint returned;

    static assert(header.offsetof == 0);
}

private Record* fromHeader(shared(TaskHeader)* raw)
    @trusted nothrow @nogc
{
    // Every published TaskRef targets the fixed header-first Record array.
    // The controlling thread cannot leave until native worker join succeeds.
    return cast(Record*) raw;
}

private void semaphoreWaitOrAbort(Semaphore gate) @trusted nothrow
{
    // A failing native wait cannot be turned into successful worker return;
    // fail-stop rather than silently lose an accepted TaskRef obligation.
    try
        gate.wait();
    catch (Throwable)
        abort();
}

private void execute(shared(TaskHeader)* raw) @safe nothrow
{
    auto record = fromHeader(raw);
    record.executor = Thread.getThis();
    atomicFetchAdd!(MemoryOrder.seq)(record.entered, 1u);
    if (record.blocking)
        semaphoreWaitOrAbort(record.gate);
    atomicFetchAdd!(MemoryOrder.seq)(record.executed, 1u);
}

private void afterReturn(TaskRef refTask) @trusted nothrow
{
    // Called by the *actual pool* only after dispatch and inbox accounting.
    auto record = cast(Record*) refTask.ptr;
    atomicFetchAdd!(MemoryOrder.rel)(record.returned, 1u);
}

private void require(bool ok, string detail)
{
    if (!ok)
        throw new Exception("P18 multiworker progress: " ~ detail);
}

private void await(scope bool delegate() predicate, string detail)
{
    auto deadline = MonoTime.currTime + dur!"seconds"(5);
    while (!predicate())
    {
        if (MonoTime.currTime > deadline)
            throw new Exception("P18 multiworker timeout: " ~ detail);
        Thread.sleep(dur!"msecs"(1));
    }
}

private void joinOrAbort(Thread thread) @system
{
    try
        thread.join();
    catch (Throwable)
        abort(); // No proof of native quiescence after a failed join.
}

private void notifyOrAbort(Semaphore gate) @system
{
    // D forbids a catch clause nested inside a finally block. Keep
    // recoverable cleanup and the native-error fail-stop in this helper.
    try
        gate.notify();
    catch (Throwable)
        abort();
}

private void closeOrAbort(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
        abort(); // Borrowed records may not be released on uncertain join.
}

// Separate invocation frame per producer, never a captured foreach slot.
private Thread makeProducer(
    SubmissionWorkerPool pool,
    Record[] records,
    shared(uint)[] accepted,
    shared(uint)[] rendezvous,
    size_t producerIndex,
    size_t producerCount)
{
    return new Thread({
        atomicFetchAdd!(MemoryOrder.rel)(rendezvous[0], 1u);
        while (atomicLoad!(MemoryOrder.acq)(rendezvous[1]) == 0u)
            Thread.yield();

        for (size_t i = producerIndex + 1; i < records.length;
             i += producerCount)
        {
            for (;;)
            {
                auto task = TaskRef(
                    cast(shared(TaskHeader)*) &records[i].header);
                const result = pool.trySubmit(task);
                if (result == SubmissionResult.accepted)
                {
                    atomicStore!(MemoryOrder.rel)(accepted[i], 1u);
                    break;
                }
                if (result == SubmissionResult.closed)
                {
                    atomicStore!(MemoryOrder.rel)(rendezvous[3], 1u);
                    atomicFetchAdd!(MemoryOrder.rel)(rendezvous[2], 1u);
                    return;
                }
                // 'full' leaves the Record entirely caller-owned.
                Thread.yield();
            }
        }
        atomicFetchAdd!(MemoryOrder.rel)(rendezvous[2], 1u);
    });
}

private size_t countReturned(Record[] records, size_t beginIndex)
{
    size_t count;
    foreach (i; beginIndex .. records.length)
        if (atomicLoad!(MemoryOrder.acq)(records[i].returned) == 1u)
            ++count;
    return count;
}

private size_t distinctExecutors(Record[] records)
{
    Thread[Total] unique;
    size_t count;
    foreach (ref record; records)
    {
        require(record.executor !is null, "record without executor");
        bool known;
        foreach (i; 0 .. count)
            if (unique[i] is record.executor)
                known = true;
        if (!known)
            unique[count++] = record.executor;
    }
    return count;
}

private void scenario(
    size_t workers, size_t producers, size_t ingress, bool blocked)
{
    auto records = new Record[Total];
    auto accepted = new shared uint[Total];
    auto rendezvous = new shared uint[4]; // ready, begin, done, bad
    auto gate = new Semaphore(0);

    foreach (i; 0 .. Total)
    {
        records[i].header.execute = &execute;
        records[i].id = i;
        records[i].blocking = (i == 0 && blocked);
        records[i].gate = i == 0 ? gate : null;
    }

    auto pool = new SubmissionWorkerPool(workers, ingress, &afterReturn);
    Thread[4] producerThreads;
    size_t launched;
    size_t siblingsWhileHeld;
    try
    {
        const first = pool.trySubmit(TaskRef(
            cast(shared(TaskHeader)*) &records[0].header));
        require(first == SubmissionResult.accepted,
                "initial blocker admission");
        atomicStore!(MemoryOrder.rel)(accepted[0], 1u);

        // Start siblings only AFTER the sole blocker has begun executing.
        await({ return atomicLoad!(MemoryOrder.acq)(
                  records[0].entered) == 1u; }, "initial worker start");

        foreach (id; 0 .. producers)
        {
            producerThreads[id] = makeProducer(
                pool, records, accepted, rendezvous, id, producers);
            try
                producerThreads[id].start();
            catch (Throwable)
                abort(); // start may fail after native thread launch
            ++launched;
        }

        await({ return atomicLoad!(MemoryOrder.acq)(rendezvous[0])
                  == producers; }, "all producers ready");
        atomicStore!(MemoryOrder.rel)(rendezvous[1], 1u);
        await({ return atomicLoad!(MemoryOrder.acq)(rendezvous[2])
                  == producers; }, "producer admission complete");
        require(atomicLoad!(MemoryOrder.acq)(rendezvous[3]) == 0u,
                "closed or unexpected admission result");

        // For a single blocked worker and at least one free worker,
        // every runnable sibling must make progress BEFORE release.
        await({ return countReturned(records, 1) == Siblings; },
              "runnable siblings before blocker release");
        if (blocked)
        {
            siblingsWhileHeld = countReturned(records, 1);
            require(atomicLoad!(MemoryOrder.acq)(
                    records[0].returned) == 0u,
                    "blocked record returned before release");
        }
    }
    finally
    {
        // Always unlock producer barrier and semaphore before native joins,
        // including if an observation deadline or ordinary check fails.
        atomicStore!(MemoryOrder.rel)(rendezvous[1], 1u);
        if (blocked)
            notifyOrAbort(gate);
        foreach (id; 0 .. launched)
            joinOrAbort(producerThreads[id]);
        closeOrAbort(pool);
    }

    size_t admitted;
    foreach (i; 0 .. Total)
    {
        const yes = atomicLoad!(MemoryOrder.acq)(accepted[i]);
        const started = atomicLoad!(MemoryOrder.acq)(records[i].entered);
        const executed = atomicLoad!(MemoryOrder.acq)(records[i].executed);
        const returned = atomicLoad!(MemoryOrder.acq)(records[i].returned);
        require(yes == 1u && started == 1u &&
                executed == 1u && returned == 1u,
                "TaskRef exactly-once record " ~ i.to!string);
        ++admitted;
    }
    require(pool.acceptedCount() == admitted &&
            pool.completedCount() == admitted,
            "accepted/completed obligation mismatch");
    const unique = distinctExecutors(records);
    if (blocked)
    {
        require(unique >= 2,
                "blocked worker prevented every other worker from running");
        require(siblingsWhileHeld == Siblings,
                "siblings did not finish before semaphore release");
    }
    writeln("case,", workers, ",", producers, ",", ingress, ",",
            blocked ? 1 : 0, ",", siblingsWhileHeld, ",", unique,
            ",", admitted, ",", pool.completedCount(), ",",
            pool.parkCount());
}

void main() @system
{
    // Distinct seedless IDs and per-producer stride guarantee identical work.
    // No hardware affinity or CPU-time / speed measurement is done here.
    writeln("phase,workers,producers,ingress,blocked,",
            "siblings_while_held,distinct_workers,accepted,completed,parks");
    size_t cases;
    foreach (workers; [2u, 4u])
    foreach (producers; [2u, 4u])
    foreach (ingress; [8u, 64u])
    foreach (blocked; [false, true])
    {
        scenario(workers, producers, ingress, blocked);
        ++cases;
    }
    require(cases == 16, "scenario matrix incomplete");
    writeln("P18_FAIRNESS_PASS scenarios=", cases);
}
