module concurrency.research.p41_real_pool_close;
import concurrency.research.m1_p38_pool : SubmissionWorkerPool;
import core.thread : Thread;
import std.stdio : writeln;
void main()
{
    foreach (iteration; 0 .. 8)
    {
        auto pool = new SubmissionWorkerPool(4, 2);
        if (iteration % 2 == 0)
        {
            foreach (_; 0 .. 200_000)
            {
                if (pool.parkCount() > 0) break;
                Thread.yield();
            }
        }
        pool.closeAndJoin();
        assert(pool.acceptedCount() == 0);
        assert(pool.completedCount() == 0);
    }
    writeln("P41_REAL_POOL_CLOSE_PASS");
}
