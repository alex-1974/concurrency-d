// EXPECT COMPILE FAILURE with -preview=dip1000.
// Returning a local stack slice would dangle after this function returns.
module negative_stack_escape;

int[] illegal() @safe nothrow @nogc
{
    int[3] storage = [2, 3, 5];
    return storage[];
}
