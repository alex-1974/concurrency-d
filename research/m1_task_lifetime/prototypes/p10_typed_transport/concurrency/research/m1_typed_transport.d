/++
 M1 P10 — bounded typed inline-value work over the ACTUAL M0 TaskRef and
 dispatchTask transport. RESEARCH ONLY; not a consumer-public API.

 P09's strict inline-data trait excludes arbitrary references/captures.
 P10 additionally requires an ordinary context-free pure @safe function
 pointer. P and R are CT-specialized: no abstract base class, virtual
 callable, per-task heap node, or type-erased result is required.

 Worker lifecycle, queue allocation, thread creation, and a header-first
 cast remain manual safety obligations. A fail-stop native failure policy
 below is intentionally very conservative and NOT approved for production.
+/
module concurrency.research.m1_typed_transport;

import concurrency.internal.task_record :
    TaskHeader, TaskRef, dispatchTask;
import concurrency.research.m1_inline_transfer : isInlineTransfer;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.stdc.stdlib : abort;

enum size_t TypedCapacity = 8;
private enum size_t WorkerCount = 2;

struct InlineResults(R)
    if (isInlineTransfer!R)
{
    size_t count;
    R[TypedCapacity] values;
}

/++ Specialized header-first, address-stable record; no record copying. +/
private struct TypedRecord(P, R)
    if (isInlineTransfer!P && isInlineTransfer!R)
{
    @disable this(this);

    alias Operation = R function(P) @safe pure nothrow @nogc;
    TaskHeader header;
    Operation operation;
    P input;
    R output;

    static assert(header.offsetof == 0);

    void prepare(Operation functionPointer, P copied) @safe
    {
        operation = functionPointer;
        input = copied;
        header.execute = &execute;
    }

    TaskRef reference() @system
    {
        return TaskRef(cast(shared(TaskHeader)*) &header);
    }

    private static TypedRecord* fromHeader(shared(TaskHeader)* raw)
        @trusted nothrow @nogc
    {
        // Header offset = 0; only this record's matching execute thunk
        // is installed. Every record address stays stable through join.
        return cast(TypedRecord*) raw;
    }

    private static void execute(shared(TaskHeader)* raw) @safe nothrow
    {
        auto record = fromHeader(raw);
        record.output = record.operation(record.input);
    }
}

/++ The records are noncopyable; this is a concrete compiler restriction. +/
static assert(!__traits(compiles, {
    TypedRecord!(int, int) original;
    TypedRecord!(int, int) duplicate = original;
}));

// In contrast with a false promise of a recoverable join, uncertain native
// start/join leaves borrowed stack TaskRefs unfit for normal frame unwind.
// This fail-stop research fallback chooses safety over availability.
private void fatalNativeUncertainty() @system
{
    abort();
}

private final class WorkerQueue
{
    private Mutex mutex;
    private Condition changed;
    private TaskRef[TypedCapacity] items;
    private Thread[WorkerCount] workers;
    private size_t head;
    private size_t pending;
    private size_t started;
    private size_t accepted;
    private size_t completed;
    private bool closing;

    this()
    {
        mutex = new Mutex();
        changed = new Condition(mutex);
    }

    void start() @system
    {
        try
        {
            foreach (ref worker; workers)
            {
                worker = new Thread({ workerLoop(); });
                worker.start();
                ++started;
            }
        }
        catch (Throwable)
        {
            // A Thread.start Error may arrive *after* a native thread
            // started but before ++started. No safe stack unwind follows.
            fatalNativeUncertainty();
        }
    }

    void publish(TaskRef task) @system
    {
        synchronized (mutex)
        {
            assert(!closing && pending < TypedCapacity);
            items[(head + pending) % TypedCapacity] = task;
            ++pending;
            ++accepted;
            changed.notify();
        }
    }

    void closeAndJoin() @system
    {
        synchronized (mutex)
        {
            closing = true;
            changed.notifyAll();
        }

        Throwable workerFailure;
        foreach (i; 0 .. started)
        {
            Throwable problem;
            try
                problem = workers[i].join(false);
            catch (Throwable)
            {
                // Unlike a returned worker Throwable, a failed *native*
                // join does not prove quiescence of its TaskRef accesses.
                fatalNativeUncertainty();
            }

            if (workerFailure is null && problem !is null)
                workerFailure = problem;
        }

        if (workerFailure !is null)
            throw workerFailure;

        assert(pending == 0);
        assert(accepted == completed);
    }

    private void workerLoop() @system
    {
        while (true)
        {
            TaskRef next;
            synchronized (mutex)
            {
                while (pending == 0 && !closing)
                    changed.wait();

                if (pending == 0 && closing)
                    return;

                next = items[head];
                items[head] = TaskRef.init;
                head = (head + 1) % TypedCapacity;
                --pending;
            }

            // Real, unmodified M0 transport, with a CT-specialized thunk.
            dispatchTask(next);
            // No record accesses after dispatch; a native join is the
            // lifetime barrier, not the result value or completion count.
            synchronized (mutex)
                ++completed;
        }
    }
}

/++
 The private trusted boundary is a MANUAL RESEARCH HYPOTHESIS:
 only copied inline values and a noncapturing function pointer enter it.
 Task records are stack pinned and all normal accesses finish at join.
 It still includes a real worker lifecycle and is NOT production-certified.
+/
private InlineResults!R runCopied(P, R)(
    P[TypedCapacity] data,
    size_t count,
    R function(P) @safe pure nothrow @nogc action) @trusted
    if (isInlineTransfer!P && isInlineTransfer!R)
{
    if (count < 2 || count > TypedCapacity || action is null)
        throw new Exception("P10 invalid dispatch arguments");

    InlineResults!R results;
    results.count = count;

    TypedRecord!(P, R)[TypedCapacity] records;
    foreach (i; 0 .. count)
        records[i].prepare(action, data[i]);

    auto workers = new WorkerQueue();
    workers.start();
    try
    {
        foreach (i; 0 .. count)
            workers.publish(records[i].reference());
    }
    finally
        workers.closeAndJoin();

    foreach (i; 0 .. count)
        results.values[i] = records[i].output;
    return results;
}

/++
 This research-only @safe frontend is intentionally NOT a generic closure,
 TaskScope, or future. It snapshots all caller values before worker start.
 Count 0/1 avoids any trusted runtime and the worker pool entirely.
+/
InlineResults!R evaluateInline(P, R)(
    scope P[] input,
    R function(P) @safe pure nothrow @nogc operation) @safe
    if (isInlineTransfer!P && isInlineTransfer!R)
{
    if (input.length > TypedCapacity)
        throw new Exception("P10 capacity exceeded");
    if (operation is null)
        throw new Exception("P10 null operation");

    InlineResults!R result;
    result.count = input.length;
    if (input.length == 0)
        return result;

    P[TypedCapacity] copied;
    foreach (i, value; input)
        copied[i] = value;

    if (input.length == 1)
    {
        result.values[0] = operation(copied[0]);
        return result;
    }

    return runCopied!(P, R)(copied, input.length, operation);
}
