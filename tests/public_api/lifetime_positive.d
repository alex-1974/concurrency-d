// External DIP1000 consumer: @system admits an explicit joined stack borrow.
module lifetime_positive;

import concurrency : Executor, TaskHandle;
import std.exception : enforce;
import std.stdio : writeln;

private struct BorrowedIncrement
{
    int* value;
    int opCall()
    {
        return ++*value;
    }
}

void main() @system
{
    int borrowed = 40;
    auto executor = new Executor(1, 2, 4);
    TaskHandle!int result;
    executor.withScope(1, (ref tasks) {
        BorrowedIncrement task;
        task.value = &borrowed;
        result = tasks.spawn(task);
    });
    enforce(borrowed == 41 && result.get() == 41,
        "joined DIP1000 borrow did not complete in scope");
    executor.closeAndJoin();
    writeln("PUBLIC_LIFETIME_POSITIVE_PASS joined_stack_borrow=true");
}
