module app;

import containers :
    WorkStealingDeque;

import std.stdio :
    writefln,
    writeln;

import std.traits :
    hasElaborateAssign,
    hasElaborateCopyConstructor,
    hasElaborateDestructor;

struct TaskRecord
{
    ulong payload;
}

alias ExecuteFn =
    void function(
        shared(TaskRecord)*)
        @safe @nogc nothrow;

struct PointerOnlyRef
{
    shared(TaskRecord)* ptr;
}

struct PointerExecuteRef
{
    shared(TaskRecord)* ptr;
    ExecuteFn execute;
}

struct TwoSharedPointersRef
{
    shared(TaskRecord)* ptr;
    shared(void)* metadata;
}

struct TaggedPointerRef
{
    shared(TaskRecord)* ptr;
    ubyte kind;
}

private void noop(
    shared(TaskRecord)*)
    @safe @nogc nothrow
{
}

template QueueOperationsCompile(T)
{
    enum bool QueueOperationsCompile =
        __traits(
            compiles,
            {
                alias Q =
                    WorkStealingDeque!(
                        T,
                        8);

                Q queue;

                T value =
                    T.init;

                T[4] batch;

                bool pushed =
                    queue.tryPush(
                        value);

                auto popped =
                    queue.pop();

                auto stolen =
                    queue.steal();

                size_t count =
                    queue.stealBatch(
                        batch[]);

                bool sink =
                    pushed ||
                    popped.found ||
                    stolen.found ||
                    count != 0;

                if (sink)
                {
                }
            }
        );
}

private void report(T)(
    string name)
{
    writefln(
        "%-22s size=%2s align=%2s queue=%-5s "
        ~ "copy=%-5s assign=%-5s destructor=%-5s",
        name,
        T.sizeof,
        T.alignof,
        QueueOperationsCompile!T,
        hasElaborateCopyConstructor!T,
        hasElaborateAssign!T,
        hasElaborateDestructor!T);
}

private void pointerOnlyRuntime()
{
    alias Queue =
        WorkStealingDeque!(
            PointerOnlyRef,
            8);

    Queue queue;

    shared TaskRecord a;
    shared TaskRecord b;
    shared TaskRecord c;

    a.payload = 11;
    b.payload = 22;
    c.payload = 33;

    PointerOnlyRef ra =
        PointerOnlyRef(
            &a);

    PointerOnlyRef rb =
        PointerOnlyRef(
            &b);

    PointerOnlyRef rc =
        PointerOnlyRef(
            &c);

    assert(queue.tryPush(ra));
    assert(queue.tryPush(rb));
    assert(queue.tryPush(rc));

    const stolen =
        queue.steal();

    assert(stolen.found);
    assert(stolen.value.ptr is &a);

    PointerOnlyRef[2] batch;

    const taken =
        queue.stealBatch(
            batch[]);

    assert(taken == 2);
    assert(batch[0].ptr is &b);
    assert(batch[1].ptr is &c);

    assert(!queue.steal().found);
}

void main()
{
    writeln(
        "R0.2 P01 task-reference capability/layout");

    report!PointerOnlyRef(
        "PointerOnlyRef");

    report!PointerExecuteRef(
        "PointerExecuteRef");

    report!TwoSharedPointersRef(
        "TwoSharedPointersRef");

    report!TaggedPointerRef(
        "TaggedPointerRef");

    writefln(
        "%-22s size=%2s align=%2s",
        "ExecuteFn",
        ExecuteFn.sizeof,
        ExecuteFn.alignof);

    static assert(
        PointerOnlyRef.sizeof ==
        (void*).sizeof);

    static assert(
        QueueOperationsCompile!
            PointerOnlyRef,
        "8-byte pointer-only TaskRef must be queue-compatible");

    static assert(
        !hasElaborateCopyConstructor!
            PointerOnlyRef);

    static assert(
        !hasElaborateAssign!
            PointerOnlyRef);

    static assert(
        !hasElaborateDestructor!
            PointerOnlyRef);

    static assert(
        PointerOnlyRef.init.ptr is null);

    ExecuteFn fn =
        &noop;

    assert(fn !is null);

    pointerOnlyRuntime();

    writeln(
        "R0.2 P01 PASS");
}
