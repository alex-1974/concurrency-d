import concurrency : Executor;

private struct Job
{
    int opCall() @safe { return 42; }
}

@safe void cannotUseSystemJoin(Executor executor)
{
    executor.join(Job.init, Job.init);
}

void main() {}
