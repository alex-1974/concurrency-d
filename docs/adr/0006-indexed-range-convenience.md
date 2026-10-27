# ADR-0006: Keep indexed range execution narrow

- Status: Accepted for the v0.3.0 candidate
- Decision: ADAPT
- Date: 2026-10-27

## Context

Issue #26 asks whether `concurrency-d` should add parallel range helpers or
defer to Phobos. The intended library role is a consumer-owned executor with
explicit task lifetime, admission and shutdown. Range helpers should make the
common “run this body for each index” case convenient without growing into a
second general-purpose algorithms package.

The CPU consumer already knows the collection cardinality and can choose a
grain size. A single opaque callable submitted with `submit` cannot be split
automatically; a range API can divide only work whose independent indices are
visible to the executor.

## Decision

Adapt the idea into two small methods on an explicitly owned `Executor`:

- `parallelFor(itemCount, grainSize, body)` uses fixed-size range claims.
- `parallelForAdaptive(itemCount, minGrainSize, body)` is an opt-in guided
  alternative for uneven item costs.

Both methods join all participating work before returning and require the
caller to provide the item count and scheduling granularity. Keep the calling
thread participating, keep executor creation and shutdown consumer-controlled,
and expose no global pool.

Defer `parallelReduce`, map/filter/scan families, and generalized range
concepts. They add result-combination, error and cancellation policy that
current consumers do not require; Phobos already supplies broad algorithms.
`WorkSize` remains a hint for opaque submitted callables and does not promise to
split one task.

## Evidence and tradeoffs

The headless CPU consumer uses indexed range execution; the event-loop example
demonstrates that work can complete through a consumer-owned handoff without
coupling the core to a UI framework. The API guide documents how to compare
fixed grains and when to test adaptive claims.

The repeated XPS end-to-end capture compares equivalent checksummed range work
against Phobos, Taskflow, oneTBB and Rayon. It does not show universal
superiority: on this host, the selected `parallelFor` settings remained about
11–15% slower than Phobos in the eight-wave workloads, while Rayon was close to
or slightly faster than Phobos. The feature is retained for its executor
ownership and integration contract, not as a replacement claim for Phobos or
as a guarantee of lower runtime. See the pinned raw capture and full caveats in
the [cross-language evidence report at signed research commit
`fb32f4455b223206f017959d54c140aa1f0a8d7b`](https://github.com/alex-1974/concurrency-d-research/blob/fb32f4455b223206f017959d54c140aa1f0a8d7b/research/m2_cross_language_reference/README.md).

## Consequences

- Keep the API small and document caller-controlled grain tuning.
- Preserve separate benchmarks for one-shot and reused-executor work.
- Treat lower scheduling overhead and tail latency as optimization targets.
- Revisit broader algorithms only when an actual consumer needs them and
  equivalent measurements justify their API and implementation cost.
