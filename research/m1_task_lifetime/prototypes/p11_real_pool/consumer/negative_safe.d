// EXPECT COMPILE REJECTION: actual P11 scheduler entry remains @system.
module concurrency.research.p11_negative_safe;

import concurrency.research.m1_real_pool : evaluateWithRealPool;

private int addOne(int value) @safe pure nothrow @nogc
{
    return value + 1;
}

void forbiddenSafe() @safe
{
    int[2] values = [1, 2];
    auto answer = evaluateWithRealPool(values[], &addOne, 2, 2);
}

void main() { forbiddenSafe(); }
