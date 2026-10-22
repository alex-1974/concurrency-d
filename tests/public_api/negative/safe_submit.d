module negative_safe_submit;
import concurrency : Executor;
private struct Job { int opCall() @safe { return 42; } }
void forbidden(Executor executor) @safe { executor.submit(Job.init); }
void main() {}
