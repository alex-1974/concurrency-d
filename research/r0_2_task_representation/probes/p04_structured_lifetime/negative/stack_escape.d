module stack_escape_negative;

struct TaskHeader
{
    ulong metadata;
}

struct TaskRef
{
    shared(TaskHeader)* ptr;
}

/*
 * This must not compile in @safe DIP1000 mode: the returned TaskRef would
 * outlive the stack record it references.
 */
@safe TaskRef escapeStackTask()
{
    shared TaskHeader local;

    return TaskRef(
        &local);
}
