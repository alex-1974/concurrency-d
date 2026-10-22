module negative_assign_result;
import concurrency : Executor;
private struct Result { @disable void opAssign(ref const Result); }
private struct Job { Result opCall() { return Result.init; } }
void main() { auto executor = new Executor(1, 2); executor.submit(Job.init); }
