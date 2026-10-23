import concurrency : Executor;

@safe void cannotUseSystemScope(Executor executor)
{
    executor.withScope(1, (ref tasks) {});
}

void main() {}
