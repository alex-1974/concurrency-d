/** Internal fatal boundary for unproved worker lifetime; not a public API. */
module concurrency.internal.lifecycle;

import core.stdc.stdio : fputs, fflush, stderr;
import core.stdc.stdlib : abort;

/** Misuse rejected before admission/close state changes or native join. */
package(concurrency) final class WorkerSelfJoinException : Exception
{
    this()
    {
        super("an executor worker cannot close and join its own pool");
    }
}

package(concurrency) enum LifecycleFailure
{
    start,
    join,
    close,
    worker,
    drain,
    owner
}

/**
 * No recovery/stack unwind is permitted when worker lifetime is unproved.
 * Static C diagnostics avoid D allocation or exception construction here.
 */
package(concurrency) void lifecycleFailStop(LifecycleFailure phase)
    nothrow @nogc
{
    final switch (phase)
    {
        case LifecycleFailure.start:  fputs("CONCURRENCY_FATAL_START\n", stderr); break;
        case LifecycleFailure.join:   fputs("CONCURRENCY_FATAL_JOIN\n", stderr); break;
        case LifecycleFailure.close:  fputs("CONCURRENCY_FATAL_CLOSE\n", stderr); break;
        case LifecycleFailure.worker: fputs("CONCURRENCY_FATAL_WORKER\n", stderr); break;
        case LifecycleFailure.drain:  fputs("CONCURRENCY_FATAL_DRAIN\n", stderr); break;
        case LifecycleFailure.owner:  fputs("CONCURRENCY_FATAL_OWNER\n", stderr); break;
    }
    fflush(stderr);
    abort();
}
