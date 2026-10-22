// EXPECT COMPILE FAILURE with -preview=dip1000.
// Contrast positive_return_ref.d: a ref without return permission cannot
// leak an address into the caller.
module negative_ref_escape;

int* illegal(ref int value) @safe nothrow @nogc
{
    return &value;
}
