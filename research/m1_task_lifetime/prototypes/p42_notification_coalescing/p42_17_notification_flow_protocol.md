# P42.17 — publication-notify and condition-wait return accounting

**Status:** experimental Research gate, not a production or lifetime API.
**Predecessor:** [P42.16 raw-only review](p42_16_raw_review_2026-10-18.md).
**Decision inherited:** no demonstrated benefit from conditional notification; no promotion.

## Question and observable boundary

The P42.16 XPS archive records valid concurrent four-worker wait enrollment,
task-start timing and executing worker IDs, but does not measure when the two
publication policies **issue** or **suppress** `Condition.notify()`, or which
workers return from `Condition.wait()`.

P42.17 measures these observable quantities without claiming that one
notification causes one wake, one task claim, or an OS kernel transition.

There are now four **distinct** source-derived research-only overlays:

- `m1_p42_baseline_pool` and `m1_p42_pool`: frozen P42.16 observed protocol;
- `m1_p42_flow_baseline_pool` and `m1_p42_flow_pool`: new P42.17 opt-in
  instrumentation.

Historical two-argument `legacy` generation and uninstrumented production
`source/concurrency/internal/submission_pool.d` remain unchanged.
A source-diff preflight normalizes the flow module name and the **single
publish-policy block** and requires the rest of the generated modules to
match exactly.

## What counts mean

Counters are protected by the original inbox mutex. They are local to a
freshly constructed pool, and each paired per-round report subtracts a
coherent **pre-submit** snapshot from a coherent **pre-close** snapshot.

| Field | Meaning |
|---|---|
| `publish_with_waiters` | Successful `trySubmit` while `_waiters > 0` |
| `publish_without_waiters` | Successful `trySubmit` while `_waiters == 0` |
| `notify_calls` | Publication-site calls made to `_changed.notify()` |
| `notify_skipped` | Publication notifications deliberately suppressed |
| `wait_returns` (four-vector) | Per-worker returns from `Condition.wait()` after mutex reacquisition |
| `predicate_changed` | Wait returns where epoch, inbox or drain predicate was changed at reacquisition |
| `predicate_unchanged` | Returns when all of those tested predicate components remain unchanged |

Required laws per burst of N accepted tasks:

- `publish_with_waiters + publish_without_waiters == N`;
- `notify_calls + notify_skipped == N`;
- baseline: `notify_calls == N`, `notify_skipped == 0`;
- conditional: `notify_calls == publish_with_waiters`,
  `notify_skipped == publish_without_waiters`;
- for each worker: `wait_returns == predicate_changed + predicate_unchanged`;
- P42.16 original criteria still hold: four enrolled workers before submit,
  once-only execution and counts, completion before close, worker IDs in range.

The consumer prints one `P42_FLOW` report per round and a `P42_FLOW_PASS` at
normal exit. P42.16 `P42_MULTI_IDLE_*` lines are retained, but adding flow
lines is allowed **only** in P42.17 opt-in builds. The P42.16 log shape and its
extractor are unchanged. The new extractor checks 36 paired raw logs,
15,984 task records, 1,296 worker/enrollment rounds and 1,296 flow deltas;
it writes `tasks.csv`, `rounds.csv` and `flow.csv`. Its positive and
negative flow-control fixtures are part of the CI gate.

## Bounded epistemic limits

The `_waiters` value describes enrollment in a condition wait under the
inbox mutex, **not a kernel-sleep guarantee**. A successful call to
`Condition.notify()` does not prove that a particular worker resumed.
A `Condition.wait()` return may follow the **local-work announcement**
notification, a prior publication notification or a spurious wake.
`predicate_changed` does not causally attribute the reason for return.
Worker IDs on executed tasks identify executors, not bystanders that woke
and found nothing. Snapshots are not atomically coupled to the entire task
burst; they bracket the burst under the same mutex but worker activity
continues between observations. The diagnostic counters themselves change
lock-critical-path cost in *both* arms, so this experiment cannot qualify
an optimized production throughput or tail-latency claim.

In particular, `notify_calls - wait_returns` is **not** a valid estimate of
lost/spurious/needless wakes. Neither a finite run nor a symmetric instrumented
overlay establishes starvation freedom.

## Exact-head CI and native protocol

The CI P42 gate builds the original P42.16 consumer variants and the
P42.17 flow variants in DMD 2.111.0 and LDC 1.41.0 debug mode, checks
source-generation symmetry, and runs parser self-tests. **Do not run a native
performance experiment until both compiler jobs pass on the exact current
branch head.**

From the dedicated XPS P42 worktree (do not move, reset, or overwrite
another worktree), after a green exact-head CI gate:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d-p42
git status -sb
git fetch origin
git pull --ff-only origin research/m1-task-lifetime-boundaries
# Choose a NEW, nonexistent path. No archive is overwritten.
bash tools/research/m1_p42_flow_native.sh "$HOME/Downloads/p42-17-xps-01"
tar -C "$HOME/Downloads" -czf "$HOME/Downloads/p42-17-xps-01.tar.gz" p42-17-xps-01
```

The source-pinned runner creates separate optimised LDC binaries, captures
source and binary hashes, exact commit, compiler, CPU/platform, builds,
thermal/frequency snapshots, warmups, 3 sessions x 6 alternating arm pairs,
and lossless logs and CSV. Source overlays are created exclusively in the
diagnostic prototype and removed by trap. **Retain the entire output directory
and upload the complete archive, not only `raw/`.**

Review the output for publication-policy consistency and genuine returns
*before* proposing any targeted wake-to-claim instrumentation. Each complete
capture still comprises only three sessions; analyses must use paired
run/session units, not assume 15,984 iid task observations.

**No change** to the M0 production scheduler, public API, ADR-0001 status,
PR #38 Draft state, baseline research evidence, `develop`, or any sibling
repository. No merge authorized.
