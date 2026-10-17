// EXPECT COMPILE FAILURE with -preview=dip1000.
// Contrast positive_scope_delegate.d: a scope delegate must not escape to
// longer-lived module storage.
module negative_scope_delegate_escape;

alias Job = int delegate() @safe;
private Job escaped;

void illegal(scope Job action) @safe
{
    escaped = action;
}
