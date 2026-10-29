# Roadmap

## M0 — Public CPU executor (v0.1.0, released)

The bounded CPU executor, typed task handles, explicit `closeAndJoin`,
per-handle task-error delivery, and independent CPU/completion consumer shipped
as v0.1.0 on DUB and GitHub. Submission remains `@system`; capture lifetime and
shared-state synchronization remain the caller's responsibility. The accepted
native-lifecycle policy is documented in [the API guide](docs/EXECUTOR.md).

The release passed the pinned DMD/LDC/native ARM64 CI and the scoped Dell XPS 15
/ LDC 1.42 performance qualification; see
[the qualification record](docs/M0-PERFORMANCE-QUALIFICATION.md). This evidence
is limited to the recorded machines, kernels, and scenarios.

## M1 — Structured tasks and practical lifetime control (v0.2.0, released)

M1 separates independently owned tasks from scope-bounded tasks.
[ADR-0002](docs/adr/0002-task-lifetime-families.md) records the accepted
lifetime contract. Version 0.2.0 includes structured task groups / `TaskScope`, a
typed two-way `join`, a cooperative cancellation token, and an evidence-based
choice of task storage while preserving a small D-native API.

Detailed prototypes and measurements, including P42.20, remain in the research
repository at its [pinned evidence corpus](https://github.com/alex-1974/concurrency-d-research/tree/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9).
They do not authorize a general `@safe` capture contract or platform-general
performance claim. [ADR-0003](docs/adr/0003-coalesce-idle-publish-notifications.md)
selects their narrowly qualified conditional publish-notification policy while
retaining portable condition parking and all other wake sites. The published
v0.1.0 public API remains available; M1 additions are included in v0.2.0.

The current compiler evidence selects `@system` for owned submission and scoped
borrows: DIP1000 rejects ordinary safe calls and scope-value copies, but cannot
prevent deliberate raw-pointer escape or prove transitive capture ownership.
The scope supplies the runtime join fence; callers supply capture validity and
synchronization.

[ADR-0004](docs/adr/0004-defer-sender-receiver-layer.md) keeps typed `join` and
lexical groups as the v0.2 composition boundary. A general lazy Sender/Receiver
layer is deferred until a real consumer demonstrates a need for scheduler
handoff or asynchronous operation graphs and can qualify their additional
lifetime and cancellation semantics.

## M2 — Consumer and performance qualification (v0.3.0, released)

The current unreleased work adds independent CPU-heavy and event-loop-style
consumer examples, including completion handoff to a consumer-controlled
thread. `Executor.parallelFor` provides fixed-maximum dynamic ranges;
`parallelForAdaptive` provides guided ranges for callers who prefer a minimum
grain and accept larger early claims. `WorkSize` lets callers identify
substantially longer submitted callables without implying automatic splitting
or runtime prediction. End-to-end and bounded-streaming diagnostics compare
these paths with checksummed alternatives. The executor guide records practical
batching, worker-count, grain and work-size tuning advice.

Version 0.3.0 shipped on 2026-10-27. The exact release tree passed DMD/LDC,
public package consumers, cross-language checksum validation and native
ARM64/LDC correctness and performance workflows. See the
[release qualification](docs/V0.3-RELEASE-QUALIFICATION.md) and the pinned
[performance evidence](https://github.com/alex-1974/concurrency-d-research/tree/fb32f4455b223206f017959d54c140aa1f0a8d7b/research/m2_end_to_end_qualification).
The range helpers serve consumer-controlled scheduling; no universal speedup
over Phobos is claimed. Fibers, an I/O reactor, NUMA policy, and a general
Sender/Receiver framework remain outside the shipped scope.

## M3 — Measured performance improvements (active; release target TBD)

The v0.3.0 release remains the performance baseline. PR #56 integrated cyclic
block work-stealing for fine `parallelForAdaptive` calls with
`minGrainSize == 1`; fixed `parallelFor` and larger adaptive minimums retain
their prior scheduling paths. On the XPS and a native ARM64 runner, paired
captures showed improved fine-work medians. An extended ARM64 run with 240
samples per workload and arm found no p95 regression above 10%; details and
limits are recorded in the
[v0.4 performance baseline](docs/V0.4-PERFORMANCE-BASELINE.md), [PR #56](https://github.com/alex-1974/concurrency-d/pull/56), and [raw ARM64 capture](https://github.com/alex-1974/concurrency-d/actions/runs/40561700792).

PR #57 adds matched grain/batch sweeps for fixed concurrency, adaptive
concurrency and Phobos on x86_64 and native ARM64. Larger 16,384-item workloads
are within roughly 4–40% of tuned Phobos medians; 1,024-item workloads remain
about 6–112% slower, with short uniform tasks the largest gap. Grain winners
vary by host and distribution. See the [direct comparison and limits](docs/V0.4-PERFORMANCE-BASELINE.md#tuned-direct-comparison-with-phobos),
[PR #57](https://github.com/alex-1974/concurrency-d/pull/57), and
[240-sample ARM64 run](https://github.com/alex-1974/concurrency-d/actions/runs/40566914191).

Short-task profiling separated callback cost from range scheduling. At 16,384
short uniform items and four workers, adaptive grain 1 was substantially
faster than fixed grain 1 in the local XPS capture; isolated samples showed
the adaptive claim path was a small part of runtime. A lower split-block
density experiment did not produce a consistent cross-workload improvement,
so the existing scheduler was retained. The expanded two-size adaptive matrix
and host-specific results are recorded in [the benchmark guide](benchmarks/README.md).

The current implementation target is synchronous batch record storage:
multi-item `submitBatchAndWait` calls use one executor-rooted record array,
while a single-item call keeps its record inline. An alternating local LDC
comparison showed 8–18% lower four-producer medians at batch grains 16–256;
one-producer gains were smaller, and measured allocation bytes varied. This
optimization changes no public scheduling API. Repeatable native ARM64
performance evidence is still needed for this path. Keep v0.4.0's release
target unset until the performance work and exact release-candidate gates
pass. Do not change task-record/parking policies without a measured need.
