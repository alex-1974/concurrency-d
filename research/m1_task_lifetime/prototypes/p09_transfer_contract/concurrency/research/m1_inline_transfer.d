/++
 M1 P09 (RESEARCH ONLY): conservative structural *inline-data* transfer.

 This trait is NOT a proof that arbitrary callables or closures are
 transferable or that an executor is @safe. It permits a small set of
 primitive scalars, fixed-size arrays, and plain nonnested structs whose
 member field types are themselves permitted. No dynamic allocations,
 pointers, delegates, classes, slices, unions, functions or nested struct
 context pointers can pass through the exposed typed snapshot.

 No scheduler or @trusted bridge is used in this module.
+/
module concurrency.research.m1_inline_transfer;

import std.traits : Fields, hasNested;

private template isPrimitiveInline(T)
{
    enum bool isPrimitiveInline =
        is(T == bool) ||
        is(T == byte) || is(T == ubyte) ||
        is(T == short) || is(T == ushort) ||
        is(T == int) || is(T == uint) ||
        is(T == long) || is(T == ulong) ||
        is(T == float) || is(T == double) ||
        is(T == char) || is(T == wchar) || is(T == dchar);
}

// The recursive probe never implicitly converts field types. A pointer,
// dynamic array, class, delegate or other alien member makes its entire
// enclosing struct ineligible.
private template allInline(Types...)
{
    static if (Types.length == 0)
        enum bool allInline = true;
    else
        enum bool allInline =
            isInlineTransfer!(Types[0]) &&
            allInline!(Types[1 .. $]);
}

/++
 True only for payloads with a recursively checked plain inline
 representation. This is a conservative *sufficient* whitelist, NOT a
 complete definition of "owned data" in D: independently retained heap
 objects can also be owned, but cannot be proven from this shape alone.

 Rejected by design: aliases to caller-owned data, nested struct context
 pointers, and structs with nontrivial copy/move/destruction behavior.
+/
template isInlineTransfer(T)
{
    static if (isPrimitiveInline!T)
        enum bool isInlineTransfer = true;
    else static if (is(T == Element[n], Element, size_t n))
        enum bool isInlineTransfer = isInlineTransfer!Element;
    else static if (is(T == struct))
        enum bool isInlineTransfer =
            __traits(isPOD, T) && !hasNested!T && allInline!(Fields!T);
    else
        enum bool isInlineTransfer = false;
}

/++
 This value-copy operation is the only P09 surface: it performs NO
 cross-thread dispatch. It proves that a future executor can CONSTRAIN
 which representations it admits, not that it already has a safe worker.
+/
T snapshotInline(T)(T payload) @safe
    if (isInlineTransfer!T)
{
    return payload;
}
