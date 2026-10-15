# M1 P29 — Generation-tagged owner slots, stale-handle ABA and saturation

**Date:** 2026-10-15. **Status:** bounded research qualification;
**not a public API, not an optimized benchmark result and not a
native OS join-failure recovery proof**.

[Issue #17](https://github.com/alex-1974/concurrency-d/issues/17) ·
[ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md) ·
[Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38)

Previous evidence:
[P23 real M0 deferred start](../p23_real_owned_lifecycle/README.md),
[P24 independent process roots](../p24_durable_root/README.md),
[P26 registry contention](../p26_token_registry_safety/README.md),
[P27 explicit exit](../p27_registry_transitions/README.md),
[P28 bounded orphans](../p28_bounded_orphans/README.md).

## Question: can a recycled owner slot be addressed with an old handle?

P28 uses bare `size_t` indices for two fixed owner slots. Once a
joined or never-started slot is vacated, a subsequent registration
reuses that index. Without a generation or equivalent capability
identity, an old controller could mistakenly start, submit to,
or close the *new* executor. A mutex alone cannot distinguish
the old and new meanings of an identical slot index.

P29 tests a **two-part `OwnerHandle { slot, generation }`**. The
`generation` counter belongs to the slot and **never resets on
release**. Registration increments it before publishing a new
handle; the zero generation is reserved as invalid. Generation
wraparound is a deliberate fail-stop in the research prototype
rather than silent ABA resurrection. No slot index is sufficient
to authorize a lifecycle operation.

The [source](../p11_real_pool/consumer/p29_generational_owner.d)
runs against a **byte-source-pinned research copy** of the actual M0
`OwnedTaskExecutor`, using the unchanged real
`SubmissionWorkerPool`, TaskRef, queues, work stealing,
completion and task record reclamation.

Production source remains unchanged:

- `source/concurrency/internal/owned_task.d` Git blob
  `e74d6a73f956c562eab176e27687a47249f5815d`;
- `source/concurrency/internal/submission_pool.d` Git blob
  `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

The existing [P23 generator](../../../../tools/research/m1_p23_make_owned.py)
rejects source changes, produces a temporary separate research
module and removes it after the [runner](../../../../tools/research/m1_p29_generational_owner.sh)
finishes.

## Ownership contract exercised

A fixed, mutex-protected `GenerationalManager` contains two
`Entry` records. Each holds a generation, a strong
`OwnedTaskExecutor` reference, lifecycle phase, explicit
orphan flag, and count of active **external submission operations**.

Registration requires a constructed, never-started executor. It
installs an explicit `GC.addRoot` **before** native worker startup,
assigns the new generation and returns `OwnerHandle`. Admission
at a full quota **rejects** the candidate without starting or
rooting it and returns an invalid-generation handle.

All lifecycle calls validate `slot` bounds, nonzero generation,
equality with the slot's current generation and a non-vacant phase
**under the same manager Mutex as recycling**. Invalid or stale
handles cause rejection, not a fallback to the currently
occupying executor.

The tested state flows are:

```text
vacant → reserved → starting → active → orphaned → draining
                                               → joined → vacant
           |                     |
           └── never-started ──→ vacant
                                 ^
                                 |
                uncertain → draining (known synthetic proof only)
                              → joined
```

A shutdown-uncertain slot retains its GC root and continues to
consume capacity. It is **not evicted** to admit a replacement.
A slot reenters `vacant` only after an actual successful native
join with `accepted == completed`, `retained == 0`, and zero
in-flight manager operations, or a separate never-started
certificate.

`publish(h, job)` takes a *short-lived operation claim* and
a local owner reference under the manager mutex, then calls
the unchanged actual M0 `trySubmit()`. It later releases the
operation claim. This prevents manager-level root removal while
the operation is in flight; the original M0 admission mutex
resolves publication versus native shutdown.

**Performance cost is not free:** P29 adds manager mutex
acquisition/release on the *submission path*. It does not
instrument the native worker dispatch/deque/steal hot path, but
submission throughput, tail latency and contention still require
matched native XPS measurements. No throughput claim follows
from the CI's wall-clock duration.

## Exactly what the tests establish

The positive DUB binary repeats the following **eight times each**:

| Scenario | Evidence |
|---|---|
| ABA / stale operations | Create and cancel an unstarted owner; immediately reuse its slot with a **different generation**; start a real M0 worker and admit a blocked nested-GC task. Four native threads then attempt 100 complete sequences of **all management operations** using the stale handle. All operations must reject. The new owner remains active; supervisor performs a real join before root release; task executes once and checksum matches. |
| Saturation / unknown capacity | A native M0 worker was successfully started, then its research owner recorded a **synthetic post-launch uncertain state**. A second slot is filled; a third owner is refused. Four GC passes cannot turn uncertainty into a free slot. After **certified never-started cancellation** of the second slot, that slot is reused with a *new generation*; the old handle cannot operate on it. The uncertain worker remains occupying the first slot until a **known synthetic** proof permits the **first actual native join** and release. |

Each repeat verifies paired `GC.addRoot/removeRoot` on
successfully discharged slots, rejection of a second release,
no stale owner mutation, and explicit application-exit closure.

A separate native process uses `P29ExitUnknown` to prove the
application close policy: attempting shutdown with a registered,
unjoined synthetic-uncertain worker prints the specific
`P29_UNFINISHED_OWNER_FAILSTOP` marker and ends via
`SIGABRT` (exit **134**) **before D runtime teardown**.
This is consistent with P27's counterexample against relying
on `shared static ~this()`.

**No actual OS start/join failure is injected or recovered.**
The exceptional recovery path is restricted to the known P23
synthetic after-successful-launch fault, before any native join.
The original P23 source-copy fails closed for real ambiguous
start/join behavior.

Expected positive marker:

```text
P29_GENERATIONAL_OWNER_PASS aba=8 contention=8 unknown_quota=8
```

Expected negative marker:

```text
P29_UNKNOWN_OWNER_FAILSTOP_PASS exit=134
```

## Reproduce / CI

```sh
bash tools/research/m1_p29_generational_owner.sh dmd
bash tools/research/m1_p29_generational_owner.sh ldc2
```

The runner uses pinned original blobs, DMD 2.111.0 and LDC 1.41.0,
debug plus full `-release`, extra LDC debug `-O3`, executable
timeouts, source cleanup and native SIGABRT inspection.
No production `source/`, root DUB API, `develop`, `main`,
or unrelated research PR #35 is edited.

**Initial source + CI gate:**
[`77451995`](https://github.com/alex-1974/concurrency-d/commit/774519958978440fd4f90e7e8be503231da055cb).
**CI:** [Actions #38737890373](https://github.com/alex-1974/concurrency-d/actions/runs/38737890373).
Check the actual run outcome and final documentation HEAD
before marking P29 fully qualified.

## P30 matched benchmark follow-up

[P30](../p30_ownership_benchmark/README.md) now compares the
**same P29 `GenerationalManager` implementation** against direct
source-pinned P23 and the original, unchanged M0
`OwnedTaskExecutor`. P29's `publish` operation was generalized
from a single concrete `Job` parameter to `publish(F)(...)`,
without changing its per-submission mutex/generation/active-call
protocol. The benchmark exercises actual typed TaskRef execution,
real bounded admission, parallel producers and native joins.

P30's CI verifies *equal work and timing sample structure only*.
The optimized XPS script records phase-separated timing and
producer-thread allocation metrics; no XPS performance verdict
exists until those artifacts are executed and reviewed. The
unmanaged original M0 arm has a **weaker native-failure/owner
lifetime contract**, so faster timings alone cannot justify
replacing the managed production candidate.

## Important limitations / next steps

- **Generation is identity, not authority or borrow safety**:
  the test does not prove an unforgeable capability, revocation of
  previously returned raw D class references, or a general
  `@safe TaskScope` for stack captures.
- **Only bounded tested races**: the test stresses stale management
  traffic while a *new* executor owns a reused slot. Arbitrary
  concurrent adopt/start/orphan/join/reclaim interleavings and
  GC-safepoint corner cases still require further qualification.
- **Capacity policy is finite and explicit**: when native shutdown
  liveness remains unproven, no automatic eviction, retry or
  hidden new executor is allowed. A permanently uncertain slot
  can deny new workloads indefinitely. The application must
  choose a user-visible refusal or an explicit fail-stop on exit;
  a timeout must not pretend native quiescence.
- **Registration and submission costs are unmeasured**. Future
  optimized-XPS benchmarks must separate per-owner registry
  admission/reclamation, contention on submission, and the
  unchanged worker hot path. Compare semantically identical
  TaskRef work; do not treat generic throughput as proof of
  scope/owner semantics.

**Disposition:** KEEP P29 as a candidate owner-handle protocol,
NOT a promotion decision. Issue #17 OPEN, ADR-0001 PROPOSED,
PR #38 DRAFT, PR #35 untouched, and no production merge.
