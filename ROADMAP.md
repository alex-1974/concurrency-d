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

## M2 — Consumer and performance qualification (release candidate, target v0.3.0)

The current unreleased work adds independent CPU-heavy and event-loop-style
consumer examples, including completion handoff to a consumer-controlled
thread. `Executor.parallelFor` provides fixed-maximum dynamic ranges;
`parallelForAdaptive` provides guided ranges for callers who prefer a minimum
grain and accept larger early claims. `WorkSize` lets callers identify
substantially longer submitted callables without implying automatic splitting
or runtime prediction. End-to-end and bounded-streaming diagnostics compare
these paths with checksummed alternatives. The executor guide records practical
batching, worker-count, grain and work-size tuning advice.

The implementation is merged to `develop`; the v0.3.0 release candidate is being validated on a branch targeting `main`.
Local DMD 2.111 and LDC 1.42 unit, lifecycle, public-consumer, worktree-package,
event-loop and benchmark smoke checks pass. Optimized measurements are retained
with host and workload limits; streaming comparisons fence Phobos producers
from executing their own queued tasks so both arms use the stated worker budget.
Remaining work is the final full-diff review and pinned CI matrix, including
native ARM64 on LDC 1.41. Fibers, an I/O reactor, NUMA policy, and a universal
sender/receiver API remain outside the M2 release prerequisites.
