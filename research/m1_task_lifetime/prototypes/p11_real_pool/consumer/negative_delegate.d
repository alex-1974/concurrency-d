// EXPECT COMPILE REJECTION: arbitrary closure context is not an op pointer.
module concurrency.research.p11_negative_delegate;

import concurrency.research.m1_real_pool : evaluateWithRealPool;

alias Closure = int delegate(int) @safe pure nothrow @nogc;

void forbidden(int[2] inputs, Closure callable)
{
    auto result = evaluateWithRealPool(inputs[], callable, 2, 2);
}

void main() {}
