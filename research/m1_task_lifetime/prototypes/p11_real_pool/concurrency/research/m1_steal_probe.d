/++
 M1 P11 DETERMINISTIC STEAL PROBE (RESEARCH ONLY, @system).
 Proves that the unchanged M0 workerLoop really reaches its cross-worker
 steal path under a controlled schedule. This is NOT a typed/@safe
 consumer, and does not change containers-d or concurrency-d production.
+/
module concurrency.research.m1_steal_probe;

import concurrency.internal.task_record : TaskHeader, TaskRef;
import concurrency.internal.submission_pool :
    SubmissionResult, SubmissionWorkerPool;
import core.atomic :
    MemoryOrder, atomicLoad, atomicStore, atomicFetchAdd;
import core.stdc.stdlib : abort;
import core.thread : Thread;
import core.time : MonoTime, dur;

// Always-evaluated correctness checks, including release-mode watchdog.
private void requireSteal(bool valid, string detail = "invariant")
{
    if (!valid)
        throw new Exception("P11 real-steal " ~ detail);
}

private enum uint PrepA = 0;
private enum uint PrepB = 1;
private enum uint Head = 2;
private enum uint Remaining = 3;

private shared uint enteredA;
private shared uint enteredB;
private shared uint enteredHead;
private shared uint releaseA;
private shared uint releaseB;
private shared uint releaseHead;
private shared uint otherExecuted;

private struct ProbeRecord
{
    TaskHeader header;
    uint kind;
}
static assert(ProbeRecord.header.offsetof == 0);

private void executeProbe(shared(TaskHeader)* header) @trusted nothrow @nogc
{
    auto record = cast(shared(ProbeRecord)*) header;
    const kind = atomicLoad!(MemoryOrder.raw)(record.kind);
    switch (kind)
    {
        case PrepA:
            atomicStore!(MemoryOrder.rel)(enteredA, 1u);
            while (atomicLoad!(MemoryOrder.acq)(releaseA) == 0u) {}
            return;
        case PrepB:
            atomicStore!(MemoryOrder.rel)(enteredB, 1u);
            while (atomicLoad!(MemoryOrder.acq)(releaseB) == 0u) {}
            return;
        case Head:
            atomicStore!(MemoryOrder.rel)(enteredHead, 1u);
            while (atomicLoad!(MemoryOrder.acq)(releaseHead) == 0u) {}
            return;
        case Remaining:
            atomicFetchAdd!(MemoryOrder.rel)(otherExecuted, 1u);
            return;
        default:
            abort(); // Wrong kind must also fail in D -release.
    }
}

private void untilAtLeast(shared(uint)* flag, uint expected) @system
{
    const deadline = MonoTime.currTime + dur!"seconds"(10);
    while (atomicLoad!(MemoryOrder.acq)(*flag) < expected)
    {
        requireSteal(MonoTime.currTime < deadline,
            "P11 deterministic steal phase timed out");
        Thread.yield();
    }
}

private void publish(SubmissionWorkerPool pool, ref ProbeRecord record)
    @system
{
    const accepted = pool.trySubmit(
        TaskRef(cast(shared(TaskHeader)*) &record.header));
    requireSteal(accepted == SubmissionResult.accepted);
}

private void joinOrAbort(SubmissionWorkerPool pool) @system
{
    try
        pool.closeAndJoin();
    catch (Throwable)
    {
        // Native join uncertainty cannot authorize unwinding records.
        abort();
    }
}

private void releaseEverything() @system
{
    atomicStore!(MemoryOrder.rel)(releaseA, 1u);
    atomicStore!(MemoryOrder.rel)(releaseB, 1u);
    atomicStore!(MemoryOrder.rel)(releaseHead, 1u);
}

/++
 Establish two blocked native workers, enqueue eight records, release
 only the worker executing PrepA. That worker must claim the eight-item
 inbox batch, publish seven to its owner deque, then block executing
 the first item (Head). The second worker is still blocked in PrepB.
 Releasing PrepB lets its worker execute the other seven *while the owner
 remains blocked*. With the ingress empty, those tasks are only reachable
 through the real M0 cross-worker stealing branch.
+/
void qualifyRealSteal() @system
{
    atomicStore!(MemoryOrder.raw)(enteredA, 0u);
    atomicStore!(MemoryOrder.raw)(enteredB, 0u);
    atomicStore!(MemoryOrder.raw)(enteredHead, 0u);
    atomicStore!(MemoryOrder.raw)(releaseA, 0u);
    atomicStore!(MemoryOrder.raw)(releaseB, 0u);
    atomicStore!(MemoryOrder.raw)(releaseHead, 0u);
    atomicStore!(MemoryOrder.raw)(otherExecuted, 0u);

    ProbeRecord[10] records;
    foreach (i; 0 .. records.length)
    {
        records[i].header.execute = &executeProbe;
        records[i].kind =
            i == 0 ? PrepA :
            i == 1 ? PrepB :
            i == 2 ? Head : Remaining;
    }

    auto pool = new SubmissionWorkerPool(2, 16);
    bool joined;
    scope (exit)
    {
        if (!joined)
        {
            releaseEverything();
            joinOrAbort(pool);
        }
    }

    publish(pool, records[0]);
    publish(pool, records[1]);
    untilAtLeast(&enteredA, 1u);
    untilAtLeast(&enteredB, 1u);

    // Both workers blocked. All eight jobs remain in ingress until
    // exactly one worker is released; inbox capacity is >= eight.
    foreach (i; 2 .. records.length)
        publish(pool, records[i]);
    requireSteal(pool.acceptedCount() == 10);

    atomicStore!(MemoryOrder.rel)(releaseA, 1u);
    untilAtLeast(&enteredHead, 1u);
    requireSteal(atomicLoad!(MemoryOrder.acq)(otherExecuted) == 0u);

    // PrepB was still occupied when Head entered. The only remaining
    // jobs are in PrepA worker's local owner deque, not in the inbox.
    atomicStore!(MemoryOrder.rel)(releaseB, 1u);
    untilAtLeast(&otherExecuted, 7u);
    requireSteal(atomicLoad!(MemoryOrder.acq)(releaseHead) == 0u);

    releaseEverything();
    joinOrAbort(pool);
    joined = true;

    requireSteal(pool.acceptedCount() == 10);
    requireSteal(pool.completedCount() == 10);
    requireSteal(atomicLoad!(MemoryOrder.acq)(otherExecuted) == 7u);
}
