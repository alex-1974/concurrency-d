// EXPECT COMPILE REJECTION: pointer-bearing payload fails P09 trait.
module concurrency.research.p11_negative_borrow;

import concurrency.research.m1_real_pool : evaluateWithRealPool;

struct Borrowed { int* pointer; int id; }

private int takeId(Borrowed value) @safe pure nothrow @nogc
{
    return value.id;
}

void main()
{
    int value;
    Borrowed[2] inputs;
    inputs[0] = Borrowed(&value, 1);
    auto result = evaluateWithRealPool(inputs[], &takeId, 2, 2);
}
