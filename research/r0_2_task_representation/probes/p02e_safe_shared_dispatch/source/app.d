module app;

import core.atomic :
    MemoryOrder,
    atomicLoad;

import std.stdio :
    writefln,
    writeln;

alias ExecuteFn =
    ulong function(
        shared(TaskRecord)*,
        size_t)
        @safe @nogc nothrow;

struct TaskRecord
{
    ExecuteFn execute;
    ulong payload;
    ubyte kind;
}

struct TaskRef
{
    shared(TaskRecord)* ptr;
}

private ulong workA(
    shared(TaskRecord)* task,
    size_t rounds)
    @safe @nogc nothrow
{
    ulong x =
        atomicLoad!(
            MemoryOrder.raw)(
                task.payload) +
        0x9e37_79b9_7f4a_7c15UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x >> 12;
        x *=
            0x2545_f491_4f6c_dd1dUL;
        x +=
            cast(ulong) i + 1;
    }

    return x;
}

private ulong workB(
    shared(TaskRecord)* task,
    size_t rounds)
    @safe @nogc nothrow
{
    ulong x =
        atomicLoad!(
            MemoryOrder.raw)(
                task.payload) ^
        0xbf58_476d_1ce4_e5b9UL;

    foreach (i; 0 .. rounds)
    {
        x ^= x << 13;
        x *=
            0x94d0_49bb_1331_11ebUL;
        x +=
            cast(ulong) i + 3;
    }

    return x;
}

private ulong dispatchFunction(
    TaskRef task,
    size_t rounds)
    @safe @nogc nothrow
{
    const execute =
        atomicLoad!(
            MemoryOrder.raw)(
                task.ptr.execute);

    return execute(
        task.ptr,
        rounds);
}

private ulong dispatchTag(
    TaskRef task,
    size_t rounds)
    @safe @nogc nothrow
{
    final switch (
        atomicLoad!(
            MemoryOrder.raw)(
                task.ptr.kind))
    {
        case 0:
            return workA(
                task.ptr,
                rounds);

        case 1:
            return workB(
                task.ptr,
                rounds);

        case 2:
            return workA(
                task.ptr,
                rounds);

        case 3:
            return workB(
                task.ptr,
                rounds);
    }
}

void main()
{
    writeln(
        "R0.2 P02e safe shared dispatch");

    static assert(
        __traits(
            compiles,
            {
                shared TaskRecord record;

                ExecuteFn execute =
                    atomicLoad!(
                        MemoryOrder.raw)(
                            record.execute);

                ulong payload =
                    atomicLoad!(
                        MemoryOrder.raw)(
                            record.payload);

                ubyte kind =
                    atomicLoad!(
                        MemoryOrder.raw)(
                            record.kind);

                if (
                    execute is null ||
                    payload == ulong.max ||
                    kind == ubyte.max)
                {
                }
            }
        ),
        "shared dispatch metadata must support safe atomic loads");

    shared TaskRecord a;
    shared TaskRecord b;

    a.execute = &workA;
    a.payload = 11;
    a.kind = 0;

    b.execute = &workB;
    b.payload = 22;
    b.kind = 1;

    const af =
        dispatchFunction(
            TaskRef(&a),
            4);

    const at =
        dispatchTag(
            TaskRef(&a),
            4);

    const bf =
        dispatchFunction(
            TaskRef(&b),
            4);

    const bt =
        dispatchTag(
            TaskRef(&b),
            4);

    assert(af == at);
    assert(bf == bt);

    writefln(
        "TaskRecord size=%s align=%s TaskRef=%s ExecuteFn=%s",
        TaskRecord.sizeof,
        TaskRecord.alignof,
        TaskRef.sizeof,
        ExecuteFn.sizeof);

    writeln(
        "@safe @nogc nothrow atomic metadata dispatch PASS");

    writeln(
        "R0.2 P02e PASS");
}
