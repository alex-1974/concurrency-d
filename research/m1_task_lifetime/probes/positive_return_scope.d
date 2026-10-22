// Positive control: a borrow is returned only via an explicit return-scope channel.
module positive_return_scope;

int[] passBorrow(return scope int[] values) @safe nothrow @nogc
{
    return values;
}

int localUse() @safe nothrow @nogc
{
    int[3] storage = [2, 3, 5];
    auto borrowed = passBorrow(storage[]);
    return borrowed[0];
}
