module negative_move_callable;
import concurrency : Executor;
private struct Job { @disable this(this); int opCall() { return 42; } }
void main() { auto executor = new Executor(1, 2); Job job; executor.submit(job); }
