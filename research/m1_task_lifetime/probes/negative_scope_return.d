// EXPECT COMPILE FAILURE with -preview=dip1000.
// Contrast positive_return_scope.d: scope without return may not be returned.
module negative_scope_return;

int[] illegal(scope int[] values) @safe nothrow @nogc
{
    return values;
}
