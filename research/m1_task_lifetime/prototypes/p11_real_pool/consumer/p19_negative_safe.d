// Compile-only: the actual M0 owned executor does not promise @safe
// cross-thread capture/ownership checking, even for a plain value callable.
module concurrency.research.p19_negative_safe;
import concurrency.internal.owned_task : OwnedTaskExecutor;
private struct Job
{
    int input;
    int opCall() { return input + 1; }
}
void forbiddenSafe(OwnedTaskExecutor executor) @safe
{
    Job job;
    job.input = 7;
    auto handle = executor.submit(job);
}
void main() {}
