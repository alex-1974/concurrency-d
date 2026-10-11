/**
 * R0.5 bounded worker-owned idle-search trace.
 *
 * Only compiled by explicit research configurations. Each worker writes
 * exclusively to its own preallocated slot; readers must join all workers
 * before requesting a snapshot. No per-event heap allocation or mutex.
 *
 * Event time is observed immediately after an action (or before a park
 * attempt), not the linearization time of another thread's queue operation.
 */
module concurrency.internal.worker_search_trace;

import core.time : MonoTime;

package(concurrency) enum WorkerSearchKind : ubyte
{
    localPop,
    ingressClaim,
    stealMiss,
    stealHit,
    searchEmpty,
    parkCheck,
    parkReturn,
    drained
}

package(concurrency) struct WorkerSearchEvent
{
    long ticks;
    WorkerSearchKind kind;
    size_t worker;
    int victim;
    size_t detail;
}

package(concurrency) struct WorkerSearchSnapshot
{
    WorkerSearchEvent[] events;
    size_t lostEvents;
    size_t perWorkerCapacity;
    size_t workers;
}

/**
 * Preallocated worker-local buffers. Concurrent writers never touch another
 * worker's count or event array. The controlling thread reads after join.
 */
package(concurrency) final class WorkerSearchRecorder
{
    private WorkerSearchEvent[][] _events;
    private size_t[] _used;
    private size_t[] _lost;
    private size_t _capacity;

    this(size_t workers, size_t capacityPerWorker = 256)
    {
        if (workers == 0 || capacityPerWorker == 0)
            throw new Exception("invalid worker search trace capacity");
        _capacity = capacityPerWorker;
        _events = new WorkerSearchEvent[][workers];
        _used = new size_t[workers];
        _lost = new size_t[workers];
        foreach (i; 0 .. workers)
            _events[i] = new WorkerSearchEvent[capacityPerWorker];
    }

    // Exactly one owner worker per index; no synchronization permitted here.
    void record(WorkerSearchKind kind, size_t worker,
                int victim = -1, size_t detail = 0)
    {
        const index = _used[worker];
        if (index >= _capacity)
        {
            ++_lost[worker];
            return;
        }
        _events[worker][index] = WorkerSearchEvent(
            cast(long) MonoTime.currTime.ticks, kind, worker, victim, detail);
        _used[worker] = index + 1;
    }

    /** Only after all worker Thread.join() calls have returned. */
    WorkerSearchSnapshot snapshotAfterJoin()
    {
        size_t total;
        size_t lost;
        foreach (i; 0 .. _events.length)
        {
            total += _used[i];
            lost += _lost[i];
        }
        auto result = new WorkerSearchEvent[total];
        size_t offset;
        foreach (i; 0 .. _events.length)
        {
            const used = _used[i];
            result[offset .. offset + used] = _events[i][0 .. used];
            offset += used;
        }
        return WorkerSearchSnapshot(
            result, lost, _capacity, _events.length);
    }
}

unittest
{
    auto trace = new WorkerSearchRecorder(2, 2);
    trace.record(WorkerSearchKind.stealMiss, 0, 1);
    trace.record(WorkerSearchKind.parkCheck, 0);
    trace.record(WorkerSearchKind.stealHit, 1, 0);
    trace.record(WorkerSearchKind.searchEmpty, 0); // explicit overflow
    auto snap = trace.snapshotAfterJoin();
    assert(snap.events.length == 3 && snap.lostEvents == 1);
    assert(snap.events[0].worker == 0);
    assert(snap.events[1].kind == WorkerSearchKind.parkCheck);
    assert(snap.events[2].worker == 1);
    assert(snap.perWorkerCapacity == 2 && snap.workers == 2);
}
