// Intentional compile-only limitation probe. Never execute: @system permits a
// raw pointer to the callback's stack-resident TaskScope to escape DIP1000.
import concurrency : Executor, TaskScope;

private TaskScope* escaped;

void demonstrateUnprovedEscape(Executor executor) @system
{
    executor.withScope(1, (ref tasks) {
        escaped = &tasks;
    });
}

void main() {}
