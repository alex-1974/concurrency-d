/** R0.5: experimentally observe burst admission while tasks block. */
module concurrency.benchmarks.burst_head_of_line;

import concurrency.internal.owned_task :
    OwnedTaskExecutor, OwnedRecordPolicy, TaskHandle;
import concurrency.internal.submission_pool : NotificationPolicy;
import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicFetchAdd;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : MonoTime, dur, ticksToNSecs;
import std.conv : to;
import std.stdio : writefln;

/** One instance per blocker. The parent thread owns and releases gate. */
private struct GateTask
{
    Semaphore gate;
    uint id;
    shared(uint)* started;
    shared(ulong)* threadId;
    shared(long)* startTicks;

    int opCall()
    {
        auto thread = Thread.getThis();
        if (thread is null)
            throw new Exception("unattached executor worker");
        // Each task owns a distinct atomic slot. Publication of started
        // is the last store, making the thread and time visible to observer.
        atomicStore!(MemoryOrder.rel)(*threadId, cast(ulong) thread.id);
        atomicStore!(MemoryOrder.rel)(*startTicks,
                                      cast(long) MonoTime.currTime.ticks);
        atomicStore!(MemoryOrder.rel)(*started, 1u);
        gate.wait();
        return cast(int) id + 73;
    }
}

private struct SiblingTask
{
    shared(uint)* executed;
    uint id;

    int opCall()
    {
        atomicFetchAdd!(MemoryOrder.rel)(*executed, 1u);
        return cast(int) id + 733;
    }
}

void main(string[] args)
{
    string notify = args.length > 1 ? args[1] : "always";
    string storage = args.length > 2 ? args[2] : "gc";
    size_t workers = args.length > 3 ? to!size_t(args[3]) : 4;
    size_t blockers = args.length > 4 ? to!size_t(args[4]) : 4;
    size_t siblings = args.length > 5 ? to!size_t(args[5]) : 8;
    size_t probeMs = args.length > 6 ? to!size_t(args[6]) : 100;

    if ((notify != "always" && notify != "waiter") ||
        (storage != "gc" && storage != "recycle") ||
        workers == 0 || workers > 32 || blockers == 0 ||
        blockers > workers || siblings == 0 || siblings > 64 ||
        probeMs == 0 || probeMs > 2_000)
        throw new Exception("invalid bounded burst-probe parameters");

    auto policy = notify == "always"
        ? NotificationPolicy.always : NotificationPolicy.waiterAware;
    auto recordPolicy = storage == "gc"
        ? OwnedRecordPolicy.freshGc : OwnedRecordPolicy.recycleTyped;

    auto started = new shared uint[blockers];
    auto tids = new shared ulong[blockers];
    auto ticks = new shared long[blockers];
    auto siblingCounts = new shared uint[siblings];
    auto gate = new Semaphore(0);
    TaskHandle!int[] blockerHandles;
    TaskHandle!int[] siblingHandles;
    auto pool = new OwnedTaskExecutor(
        workers, 64, 512, recordPolicy, true, policy);

    // Burst-publish all blockers, without confirming their start.
    // Then publish runnable siblings while no blocked task can finish.
    const begin = MonoTime.currTime.ticks;
    foreach (i; 0 .. blockers)
    {
        GateTask task;
        task.gate = gate;
        task.id = cast(uint) i;
        task.started = &started[i];
        task.threadId = &tids[i];
        task.startTicks = &ticks[i];
        blockerHandles ~= pool.submit(task);
    }
    foreach (i; 0 .. siblings)
    {
        SiblingTask task;
        task.id = cast(uint) i;
        task.executed = &siblingCounts[i];
        siblingHandles ~= pool.submit(task);
    }

    // Observation is a sleep, not a spin/yield polling loop.
    Thread.sleep(dur!"msecs"(probeMs));
    auto before = new bool[blockers];
    size_t startedBefore;
    foreach (i; 0 .. blockers)
    {
        before[i] = atomicLoad!(MemoryOrder.acq)(started[i]) != 0;
        if (before[i])
            ++startedBefore;
    }
    size_t siblingBefore;
    foreach (ref count; siblingCounts)
        if (atomicLoad!(MemoryOrder.acq)(count) != 0)
            ++siblingBefore;

    // All accepted blockers must be unblocked, including blockers
    // that were still in a deque when the observation ended.
    foreach (_; 0 .. blockers)
        gate.notify();
    pool.closeAndJoin();

    if (pool.acceptedCount() != blockers + siblings ||
        pool.completedCount() != blockers + siblings)
        throw new Exception("burst accepted/completed mismatch");
    foreach (i, handle; blockerHandles)
        if (handle.get() != cast(int) i + 73 ||
            atomicLoad!(MemoryOrder.acq)(started[i]) != 1u)
            throw new Exception("burst blocker lost or duplicate");
    foreach (i, handle; siblingHandles)
        if (handle.get() != cast(int) i + 733 ||
            atomicLoad!(MemoryOrder.acq)(siblingCounts[i]) != 1u)
            throw new Exception("burst sibling lost or duplicate");

    auto perWorker = pool.workerStatsAfterJoin();
    auto inbox = pool.inboxParkingStatsAfterJoin();
    ulong totalExecuted;
    ulong claimed;
    ulong batches;
    ulong localExecuted;
    ulong directExecuted;
    ulong stolenExecuted;
    foreach (i, worker; perWorker)
    {
        if (worker.ownerLocalExecutions +
            worker.directIngressExecutions +
            worker.stealExecutions != worker.executions ||
            worker.stealExecutions != worker.stealSuccesses)
            throw new Exception("burst worker-source accounting mismatch");
        totalExecuted += worker.executions;
        claimed += worker.ingressClaimedTasks;
        batches += worker.ingressBatches;
        localExecuted += worker.ownerLocalExecutions;
        directExecuted += worker.directIngressExecutions;
        stolenExecuted += worker.stealExecutions;
        writefln("claim,%s,%s,%s,%s,%s,%s,%s",
            i, worker.ingressBatches, worker.ingressClaimedTasks,
            worker.ownerLocalExecutions, worker.directIngressExecutions,
            worker.stealExecutions, worker.executions);
    }
    if (totalExecuted != blockers + siblings ||
        claimed != blockers + siblings ||
        batches != inbox.claimedBatches ||
        claimed != inbox.claimedTasks ||
        localExecuted + directExecuted + stolenExecuted != totalExecuted)
        throw new Exception("burst claim-vs-execution mismatch");

    // Build transient labels for OS thread IDs: 0..number of distinct
    // executor threads observed. OS identifiers themselves are not
    // written to retained evidence.
    ulong[] distinct;
    foreach (i; 0 .. blockers)
    {
        const id = atomicLoad!(MemoryOrder.acq)(tids[i]);
        const taskTicks = atomicLoad!(MemoryOrder.acq)(ticks[i]);
        if (id == 0 || taskTicks < begin)
            throw new Exception("invalid blocker start attribution");
        size_t slot;
        while (slot < distinct.length && distinct[slot] != id)
            ++slot;
        if (slot == distinct.length)
            distinct ~= id;
        writefln("task,%s,%s,%s,%s",
            i, before[i] ? 1 : 0, slot,
            ticksToNSecs(taskTicks - begin));
    }
    if (distinct.length > workers)
        throw new Exception("more blocker threads than executor workers");

    writefln("burst,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        notify, storage, workers, blockers, siblings, probeMs,
        startedBefore, siblingBefore, distinct.length,
        claimed, localExecuted, stolenExecuted);
}
