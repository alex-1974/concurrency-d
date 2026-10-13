// EXPECT COMPILE FAILURE with -preview=dip1000.
// A scope parameter may not be stored in longer-lived module storage.
module negative_scope_global;

private int[] escaped;

void illegal(scope int[] values) @safe
{
    escaped = values;
}
