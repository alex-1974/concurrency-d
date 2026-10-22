// EXPECT COMPILE FAILURE: result is a class reference.
module negative_class_result;
import concurrency.research.m1_typed_transport : evaluateInline;

class Node { int value; }
private Node get(int value) @safe pure nothrow @nogc { return null; }
void invalid(int[2] inputs) @safe
{
    auto result = evaluateInline(inputs[], &get);
}
