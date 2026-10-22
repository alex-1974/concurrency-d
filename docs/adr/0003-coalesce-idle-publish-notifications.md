# ADR-0003 — Coalesce publish notifications without changing parking

- **Status:** Proposed for v0.2; implementation qualified locally
- **Issue:** [#21 — worker parking and wake policy](https://github.com/alex-1974/concurrency-d/issues/21)
- **Research basis:** [P42 conditional-notification study](https://github.com/alex-1974/concurrency-d-research/tree/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9/research/m1_task_lifetime/prototypes/p42_notification_coalescing)

## Decision

Keep the portable mutex, `Condition`, generation ticket, complete victim scan,
and zero-spin idle path. Adapt only external publication: increment the
generation for every accepted task, but call `Condition.notify` only when at
least one worker is enrolled in `Condition.wait` under the same inbox mutex.

Do not suppress notifications for work moved to an owner deque. Keep the
close and final-completion broadcasts. Do not add a Linux futex path, bounded
spin, wake-many burst heuristic, or active-searcher limit without new evidence.

## Correctness argument

Publication, waiter enrollment, and the park predicate use one mutex. If a
worker is enrolled when publication commits, the publisher notifies it. If no
worker is enrolled, there is no current condition waiter to notify. A worker
whose search ticket predates publication observes the changed generation before
waiting; a worker that captures a later ticket searches the inbox afterward.
The notification is therefore an acceleration for an enrolled waiter, not a
durable work token.

This argument assumes the native mutex/condition contract, no generation wrap
during one search, eventual scheduling of runnable workers, and terminating
task callbacks. It establishes neither bounded latency nor universal fairness.

## Evidence

The source-pinned P42.18 and cooled P42.19 XPS/LDC studies compared the minimal
conditional policy with unconditional publication notification over identical
tasks. In P42.19, the conditional arm's median paired elapsed-time change for
four producers and four workers was **−7.69%** for light tasks and **−4.82%**
for medium tasks; it won 29/36 and 27/36 pairs. The predeclared session and
thermal screens passed. One-producer/one-worker controls were −1.21% and
+0.38%, so the result does not indicate a broad single-worker improvement.

P42.20 then passed pinned DMD 2.111/LDC 1.41 CI and local LDC 1.42 checks for
controlled ticket/search/park, local-handoff and close races; typed, void and
error results; dropped handles and GC graphs; concurrent admission/close; and
controller-thread completion handoff. Deliberately suppressing a confirmed
waiter's publication wake or the local-handoff wake was detected by the
negative controls.

The transferred implementation passed the complete local DMD 2.111 and LDC
1.42 public API and lifecycle/fault gates; LDC included assertions-on `-O3`.
Its internal unit binary also passed 100 consecutive runs. A 2026-10-22 XPS
smoke used LDC release, 256 isolated wakes per run, three repetitions and
1/2/4 workers. Eight of nine P99 values were 120–129 µs; one two-worker run
reported 458 µs. All 2,304 tasks completed, and each 300 ms idle window used
0.00015–0.00049 CPU cores. Package temperature was 58°C before and after the
measurement. This confirms the transferred path's basic latency and idle
behavior on this machine; it is not a new conditional-versus-baseline A/B.

The maintained parking benchmark continues to measure fully parked isolated
wakes and idle CPU. It is a smoke/diagnostic check, not a fixed timing gate on
shared CI. P42.18/19 provide the sustained throughput comparison that justified
this narrow adaptation.

## Consequences

The hot multi-producer path avoids redundant notify calls when all workers are
running or between searches. Idle workers still block with negligible steady
CPU use. The design adds one mutex-protected waiter counter; exceptional wait
exit decrements it with `scope(exit)`.

This decision does not claim platform-general speedups. Native ARM64 remains a
correctness target for this portable path; no platform-specialized primitive
is introduced. Revisit more complex parking variants only with a representative
workload that shows a material remaining problem.
