module negative_not_callable;
import concurrency : Executor;
void main() { auto executor = new Executor(1, 2); executor.submit(42); }
