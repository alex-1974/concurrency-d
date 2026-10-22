module negative_move_result;
import concurrency : Executor;
private struct Result { @disable this(this); }
private struct Job { Result opCall() { return Result.init; } }
void main() { auto executor = new Executor(1, 2); executor.submit(Job.init); }
