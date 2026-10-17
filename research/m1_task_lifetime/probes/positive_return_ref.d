// Positive control: a returned pointer may be derived from an explicitly
// return-ref parameter; ownership remains with the caller.
module positive_return_ref;

int* passBorrow(return ref int value) @safe nothrow @nogc
{
    return &value;
}

int localUse() @safe nothrow @nogc
{
    int storage = 17;
    auto borrowed = passBorrow(storage);
    return *borrowed;
}
