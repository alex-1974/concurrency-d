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

## M3 — Measured performance improvements (proposed; release target TBD)

Use the exact v0.3.0 release as the baseline before selecting an optimization.
The first diagnostic is profiling fine adaptive range work: the ARM64 capture
shows a repeatable, roughly 3% median gap to Phobos, while the XPS tail varies
substantially between sessions. This does not yet justify a scheduler change
or a v0.4.0 release target. The
[v0.4 performance baseline](docs/V0.4-PERFORMANCE-BASELINE.md) records the
reproduction protocol and evidence.

Do not add public scheduling or composition APIs as part of this work unless a
real consumer demonstrates a gap. Keep GC-owned task records and the current
portable parking policy unless new, semantically fair measurements identify
them as the limiting factor. Assign a v0.4.0 release target only after a
candidate produces a repeatable improvement with no material regression in
the rest of the baseline matrix.
