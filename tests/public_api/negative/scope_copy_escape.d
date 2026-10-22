import concurrency : Executor, TaskScope;

private TaskScope escaped;

void forbidden(Executor executor) @system
{
    executor.withScope(1, (ref tasks) {
        escaped = tasks;
    });
}

void main() {}
