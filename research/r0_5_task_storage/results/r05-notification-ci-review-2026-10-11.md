# R0.5 notification policy A/B — native hosted qualification

**Date:** 2026-10-11. **Decision:** retain `NotificationPolicy.always`
as the default and **defer** any replacement pending the five-round
Dell-XPS qualification, especially latency and fairness.

## Tested code and platforms

- Exact tested source SHA **`fdc07d36d2be2a1dbeeb10405626562010e2821a`**;
  later commits preserve documents and extracted CI evidence only.
- [Native LDC 1.41 optimized x86-64/ARM64 matrix](https://github.com/alex-1974/concurrency-d/actions/runs/38131825947):
  both jobs **PASS**, including the pre-existing storage benchmarks,
  new notification A/B, and idle/latency control.
- [DMD 2.111 + LDC 1.41 + native ARM64 consumer CI](https://github.com/alex-1974/concurrency-d/actions/runs/38131825949):
  all three jobs **PASS**, including unit tests and the new DUB
  latency executable under both research notification policies.
- [Eight paired hosted throughput summaries](./r05-ci-notification-ab-2026-10-11.csv).
- [Eight individual 100 ms idle / 40-task latency results](./r05-ci-notification-idle-2026-10-11.csv).
- [Protocol, correctness contracts and XPS reproduction](../r05-notification-policy-ab.md).

Two paired rounds per case, 1,200 accepted tasks/process for the
throughput control, four workers, producer counts 1 and 4, retention
budget 512, striped execution atomics, storage policy fresh GC.
The diagnostic matrix additionally records actual/skipped
`notify` calls, condition waits, useful search and worker churn
when enabled, but the **throughput comparison uses profiling OFF**.

The baseline is the **`always` mode of this modified research
source**, not byte-for-byte equivalent generated code to the old
`develop` implementation. The new policy dispatch branch remains
in both A/B variants. Do not make a cross-revision speedup claim.

## Uninstrumented throughput: waiterAware / always

| Platform | Workload | Producers | Paired median | Waiter wins | Candidate publication notify skipped |
|---|---|---:|---:|---:|---:|
| x86-64 | minimal | 1 | 1.0704× | 2/2 | 1.33% |
| x86-64 | minimal | 4 | **1.1362×** | **2/2** | **2.88%** |
| x86-64 | compute-1024 | 1 | 0.9928× | 1/2 | 7.38% |
| x86-64 | compute-1024 | 4 | **1.1022×** | **2/2** | **51.54%** |
| ARM64 | minimal | 1 | 1.0283× | 1/2 | 5.79% |
| ARM64 | minimal | 4 | **1.0677×** | **2/2** | **4.25%** |
| ARM64 | compute-1024 | 1 | 1.0411× | 2/2 | 15.08% |
| ARM64 | compute-1024 | 4 | **1.0572×** | 1/2 | **40.00%** |

In these **short hosted samples**, the candidate sometimes wins.
But only ~3–4% of ingress publications skip `notify` for
4-producer minimal tasks, while the apparent end-to-end rate
difference is 7–14%. That imbalance could reflect scheduling
noise rather than a large underlying notification cost.
The compute workload has a more substantial fraction of skipped
calls, but equally lacks stable native-XPS evidence.

The candidate **still notifies every publication with a registered
waiter** and never changes the generation/queue predicate. It
cannot directly solve all of the previously observed 44.5%
empty first searches after actual condition waits.

## Low-load latency and idle CPU

An independent executable samples **process-wide CPU** over a
100 ms interval after starting four empty workers. Then it
submits and awaits **40 typed-result tasks** with 1 ms gaps,
reporting nearest-rank per-run p50/p95/p99 latency.
These are *submit-to-result* latencies, not measured OS
notify-to-execution times.

| Platform | Variant | Median idle CPU, 100 ms | Median p95 | Median p99 |
|---|---|---:|---:|---:|
| x86-64 | always | 63.5 µs | 34.8 µs | **40.0 µs** |
| x86-64 | waiterAware | 71.0 µs | 31.5 µs | **58.2 µs** |
| ARM64 | always | 108.0 µs | 81.7 µs | **206.5 µs** |
| ARM64 | waiterAware | 136.0 µs | 129.1 µs | **224.6 µs** |

These are **two-run medians**, not distributions across a
controlled machine. A single background scheduling event can
dominate 40-task p99. The apparent p99 deterioration on both
architectures is a warning to qualify latency further, **not**
proof of a deterministic regression. No idle CPU improvement is
established; the observed CPU deltas are extremely small and
depend on clock/accounting precision.

## Semantic and progress checks

The research variant counts sleepers under the existing inbox
mutex immediately around `Condition.wait()`. Every acceptance
still advances generation. The wake predicate and close/final-drain
broadcasts do **not** change. An accepted task published before
a waiter registers is protected by the unchanged generation
and nonempty-queue checks. The candidate calls `notify`
whenever any waiter is registered.

Regression tests include:
- no-waiter submission skips the call without losing the task;
- one actually sleeping worker receives and completes its task;
- four concurrent producers publish 2,048 tasks under bounded
  ingress, all execute **exactly once**;
- existing wake-generation, close/join, GC/result and
  multi-worker parking tests;
- new low-arrival typed-result executable on DMD/LDC/native ARM64.

These demonstrate correctness in tested interleavings, not a
formal lock-free progress proof or quantified scheduler fairness
under arbitrary blocking user tasks.

## Research decision

**KEEP:** default `NotificationPolicy.always`, production
`freshGc`, generation-safe `Condition.wait()`, exact task
completion and record ownership semantics.

**DEFER:** promotion of `waiterAware`, aggressive notification
coalescing, spin-before-park, delayed batches, recycling, and
new admission queues. No claims of an XPS speedup, improved
p99, fairness or lower idle CPU are supported yet.

**NEXT:** run both A/B scripts on the Intel i7-9750H XPS at
30,000 tasks/5 rounds, 256 low-arrival samples/5 rounds,
preserve the raw CSV and exact environment/Git SHA. Then
inspect paired ratios, skip counts, idle CPU, p95/p99,
voluntary context switches and the existing useful-wakeup
fraction. A work-conserving fairness/blocking test remains
necessary before considering any production notification policy.
