// EXPECT COMPILE FAILURE: hidden raw pointer in POD field.
module negative_borrowed_field;
import concurrency.research.m1_typed_transport : evaluateInline;

struct Borrowed { int* address; int value; }
private int calc(Borrowed item) @safe pure nothrow @nogc { return item.value; }
void invalid(Borrowed[2] items) @safe
{
    auto result = evaluateInline(items[], &calc);
}
