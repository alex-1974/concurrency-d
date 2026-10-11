/**
 * Bounded R0.5 research-only TaskRef event recorder.
 *
 * Enabled only by the separate burst tracing build. Never store raw record
 * addresses in evidence: an accepted submission gets a monotonically
 * increasing identity, even when a typed record is reused later.
 *
 * All events and registry operations are serialized under this diagnostic
 * mutex. Consequently timestamps are observation times, NOT uninstrumented
 * scheduling times. This instrumented build is never a throughput baseline.
 */
module concurrency.internal.task_trace;

import concurrency.internal.task_record : TaskRef, TaskHeader;
import core.sync.mutex : Mutex;
import core.time : MonoTime;

package(concurrency) enum TaskTraceKind : ubyte
{
    published,
    claimed,
    enqueueBegin,
    enqueueOk,
    enqueueFull,
    ownerPop,
    stolen,
    dispatchBegin,
    dispatchEnd,
    accounted
}

/** An address-free, logical-worker event recorded under the trace mutex. */
package(concurrency) struct TaskTraceEvent
{
    ulong sequence;
    ulong taskId;
    ulong batchId;
    long ticks;
    TaskTraceKind kind;
    int worker;
    int victim;
}

/** Returned only after all worker threads have joined. */
package(concurrency) struct TaskTraceSnapshot
{
    TaskTraceEvent[] events;
    ulong admitted;
    ulong lostEvents;
    ulong registryOverflow;
    ulong unmatched;
    size_t stillLive;
}

private struct LiveTask
{
    TaskRef task;
    ulong id;
    bool active;
}

/**
 * Intentionally small bounded diagnostic. Never blocks for space or silently
 * overwrites events. The normal scheduler build never constructs this object.
 */
package(concurrency) final class TaskTraceRecorder
{
    private Mutex _mutex;
    private TaskTraceEvent[] _events;
    private LiveTask[] _live;
    private size_t _count;
    private ulong _nextId;
    private ulong _nextBatchId;
    private ulong _lostEvents;
    private ulong _registryOverflow;
    private ulong _unmatched;

    this(size_t eventCapacity = 4096, size_t liveCapacity = 1024)
    {
        if (eventCapacity == 0 || liveCapacity == 0)
            throw new Exception("trace capacities must be positive");
        _mutex = new Mutex();
        _events = new TaskTraceEvent[eventCapacity];
        _live = new LiveTask[liveCapacity];
    }

    private void append(TaskTraceKind kind, ulong id, int worker,
                        int victim = -1, ulong batch = 0)
    {
        if (_count == _events.length)
        {
            ++_lostEvents;
            return;
        }
        const sequence = cast(ulong) (_count + 1);
        _events[_count] = TaskTraceEvent(
            sequence, id, batch,
            cast(long) MonoTime.currTime.ticks, kind, worker, victim);
        ++_count;
    }

    private size_t lookup(TaskRef task)
    {
        foreach (i, entry; _live)
            if (entry.active && entry.task.ptr == task.ptr)
                return i;
        return _live.length;
    }

    /** Call while admission still holds the inbox mutex. */
    void published(TaskRef task)
    {
        synchronized (_mutex)
        {
            if (lookup(task) != _live.length)
            {
                ++_unmatched; // same live record was published twice
                return;
            }
            size_t vacant;
            while (vacant < _live.length && _live[vacant].active)
                ++vacant;
            if (vacant == _live.length)
            {
                ++_registryOverflow;
                return;
            }
            const id = ++_nextId;
            _live[vacant] = LiveTask(task, id, true);
            append(TaskTraceKind.published, id, -1);
        }
    }

    /** Give every successful inbox claim a distinct batch identity. */
    void claimed(scope TaskRef[] tasks, size_t worker)
    {
        synchronized (_mutex)
        {
            const batch = ++_nextBatchId;
            foreach (task; tasks)
            {
                const i = lookup(task);
                if (i == _live.length)
                {
                    ++_unmatched;
                    continue;
                }
                append(TaskTraceKind.claimed, _live[i].id,
                       cast(int) worker, -1, batch);
            }
        }
    }

    /** Generic scheduler transition. victim is meaningful for steals only. */
    void record(TaskTraceKind kind, TaskRef task, size_t worker,
                int victim = -1)
    {
        synchronized (_mutex)
        {
            const i = lookup(task);
            if (i == _live.length)
            {
                ++_unmatched;
                return;
            }
            append(kind, _live[i].id, cast(int) worker, victim);
        }
    }

    /**
     * Called after dispatch and completion accounting, BEFORE the owned
     * executor permits record reuse. Never dereference the TaskRef here.
     */
    void accounted(TaskRef task, size_t worker)
    {
        synchronized (_mutex)
        {
            const i = lookup(task);
            if (i == _live.length)
            {
                ++_unmatched;
                return;
            }
            append(TaskTraceKind.accounted, _live[i].id,
                   cast(int) worker);
            _live[i] = LiveTask.init;
        }
    }

    TaskTraceSnapshot snapshotAfterJoin()
    {
        synchronized (_mutex)
        {
            size_t live;
            foreach (entry; _live)
                if (entry.active)
                    ++live;
            return TaskTraceSnapshot(
                _events[0 .. _count].dup, _nextId,
                _lostEvents, _registryOverflow, _unmatched, live);
        }
    }
}

unittest
{
    shared TaskHeader header;
    auto ref1 = TaskRef(&header);
    auto trace = new TaskTraceRecorder(32, 2);
    trace.published(ref1);
    TaskRef[1] batch = [ref1];
    trace.claimed(batch[], 0);
    trace.record(TaskTraceKind.enqueueBegin, ref1, 0);
    trace.record(TaskTraceKind.enqueueOk, ref1, 0);
    trace.record(TaskTraceKind.stolen, ref1, 1, 0);
    trace.record(TaskTraceKind.dispatchBegin, ref1, 1);
    trace.record(TaskTraceKind.dispatchEnd, ref1, 1);
    trace.accounted(ref1, 1);
    // Same address can be rearmed; identity must not be reused.
    trace.published(ref1);
    trace.claimed(batch[], 0);
    trace.accounted(ref1, 0);
    auto snap = trace.snapshotAfterJoin();
    assert(snap.admitted == 2 && snap.stillLive == 0);
    assert(snap.lostEvents == 0 && snap.registryOverflow == 0);
    assert(snap.unmatched == 0 && snap.events.length == 11);
    assert(snap.events[0].taskId == 1);
    assert(snap.events[8].taskId == 2);

    // Exhaustion must remain observable, never overwrite retained events.
    auto narrow = new TaskTraceRecorder(1, 1);
    narrow.published(ref1);
    narrow.claimed(batch[], 0);
    auto overflow = narrow.snapshotAfterJoin();
    assert(overflow.events.length == 1 && overflow.lostEvents == 1);
    shared TaskHeader secondHeader;
    narrow.published(TaskRef(&secondHeader));
    overflow = narrow.snapshotAfterJoin();
    assert(overflow.registryOverflow == 1 && overflow.stillLive == 1);
}
