# P42.15 — four-worker idle publication gate

P42.14 found similar median single-worker publish-to-execute latency, with insufficient evidence for a tail-latency benefit. P42.15 adds a **correctness-first** multi-worker test using the exact original and source-derived conditional pool modules.

Each of 12 rounds per shape creates four workers and waits until at least four historical condition-wait entries have been recorded. It then submits **1, 4 or 32** tasks with capacity 64, waits until all have executed, and only then closes the pool to exclude shutdown broadcasts as a means of completing the workload. Both arms validate accepted/completed counts and exactly-once executions. Monotonic timestamps offer a preliminary **maximum submission-start-to-task-start** bound for each burst, reported in ticks.

**Limitations**: four wait entries are not proof that four distinct workers remain asleep; the producer may observe repeated wait calls from one worker. For the 32-task burst, late tasks have a longer publication offset; the maximum is not a pure wakeup or per-task publish latency. Single-task and four-task cases cannot establish how many workers actually woke or executed, and a finite smoke test does not establish starvation freedom or performance. CI debug tests must pass before even the correctness gate is qualified. An optimized, prebuilt XPS multi-worker timing runner and worker identity / confirmed waiter tracking are deliberately deferred until the correctness gate is green.

No public API or production scheduler modification. Original and conditional only differ in the existing research-generated notification overlay.

## P42.16 research refinement: instantaneous waiter enrollment

The conditional research overlay now provides `waiterCount()`, read under the inbox mutex. It increments immediately before `Condition.wait()` and decrements after the call returns while reacquiring that mutex. With four pool workers, a count of four shows **four concurrent wait enrollments** (one per worker), rather than four potentially repeated historical wait entries. The conditional multi-idle consumer requires this new observation before publication. The original production baseline remains uninstrumented and is still gated only by historical `parkCount()`. Thus the two arms have **different pre-publication evidence** and cannot yet support a fair performance comparison, even though both execute the same tasks.

This does not establish that all workers have entered OS kernel sleep or that they stay parked throughout the time between the count observation and submission. The next research step is a **source-derived, similarly instrumented baseline overlay** and worker-specific entry/exit records before any comparative wakeup tail-latency claim. The original production pool and pre-existing P42.14 evidence are not modified.
