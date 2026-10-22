// EXPECT COMPILE FAILURE: pointer payload cannot satisfy P09 trait.
module negative_borrowed_pointer;
import concurrency.research.m1_typed_transport : evaluateInline;

private int count(int* p) @safe pure nothrow @nogc { return p is null ? 0 : 1; }

void invalid() @safe
{
    int value;
    int*[2] inputs = [&value, &value];
    auto result = evaluateInline(inputs[], &count);
}
