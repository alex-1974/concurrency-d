// EXPECT COMPILE FAILURE: delegates have arbitrary closure contexts.
module negative_delegate_operation;
import concurrency.research.m1_typed_transport : evaluateInline;

alias Closure = int delegate(int) @safe pure nothrow @nogc;
void invalid(int[2] inputs, Closure action) @safe
{
    auto result = evaluateInline(inputs[], action);
}
