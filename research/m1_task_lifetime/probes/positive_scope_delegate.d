// Positive control: a locally captured @safe delegate may be invoked through
// a scope parameter while its lexical parent is still active.
module positive_scope_delegate;

alias Job = int delegate() @safe;

int invokeNow(scope Job action) @safe
{
    return action();
}

int localUse() @safe
{
    int value = 7;
    Job action = () @safe { return value + 1; };
    return invokeNow(action);
}
