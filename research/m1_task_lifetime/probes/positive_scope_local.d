// Positive control: local use of a non-escaping borrowed slice.
module positive_scope_local;

int sum(scope const(int)[] values) @safe pure nothrow @nogc
{
    int total = 0;
    foreach (value; values)
        total += value;
    return total;
}

int localUse() @safe pure nothrow @nogc
{
    int[3] storage = [2, 3, 5];
    return sum(storage[]);
}
