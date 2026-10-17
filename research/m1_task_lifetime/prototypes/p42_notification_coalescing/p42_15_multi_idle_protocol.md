# P42.15 — four-worker idle publication gate

P42.14 found similar median single-worker publish-to-execute latency, with insufficient evidence for a tail-latency benefit. P42.15 adds a **correctness-first** multi-worker test using the exact original and source-derived conditional pool modules.

Each of 12 rounds per shape creates four workers and waits until at least four historical condition-wait entries have been recorded. It then submits **1, 4 or 32** tasks with capacity 64, waits until all have executed, and only then closes the pool to exclude shutdown broadcasts as a means of completing the workload. Both arms validate accepted/completed counts and exactly-once executions. Monotonic timestamps offer a preliminary **maximum submission-start-to-task-start** bound for each burst, reported in ticks.

**Limitations**: four wait entries are not proof that four distinct workers remain asleep; the producer may observe repeated wait calls from one worker. For the 32-task burst, late tasks have a longer publication offset; the maximum is not a pure wakeup or per-task publish latency. Single-task and four-task cases cannot establish how many workers actually woke or executed, and a finite smoke test does not establish starvation freedom or performance. CI debug tests must pass before even the correctness gate is qualified. An optimized, prebuilt XPS multi-worker timing runner and worker identity / confirmed waiter tracking are deliberately deferred until the correctness gate is green.

No public API or production scheduler modification. Original and conditional only differ in the existing research-generated notification overlay.
