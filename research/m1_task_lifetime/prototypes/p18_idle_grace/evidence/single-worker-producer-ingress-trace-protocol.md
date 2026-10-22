# P18 — Single-worker producer/ingress event-only diagnostic (2026-10-14)

**Status: research-only instrumentation prepared; no new Dell-XPS producer/ingress trace collected.** The uninstrumented M0/P18 schedulers, public API, P13 workload, all prior XPS archives and lifetime contracts remain unchanged.

## Why this experiment exists

[Complete native Single-Worker Ingress ABBA audit](xps-2026-10-14-single-ingress-review.md), original SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`, reported **480 valid uninstrumented measured matched comparisons** (two ABBA half-pairs per four sessions). At 512 iterations, the paired wave-time P18/M0 medians at ingress **8/64/256/2048** were **1.0627/1.0392/1.0539/0.9875**. The 2,048-slot inbox had **zero full-inbox retries for both arms in every round**. No causal time attribution was made: capacity also changes queue residency, contention and thread interleavings.

The fixed P13 producer retries `trySubmit` on `full`, increments the retry counter, then calls `Thread.yield()`. The worker claims ingress work via `takeBatch` under the inbox mutex and may yield once more under P18 before repeating local/inbox/foreign search. One worker has **zero foreign steal attempts**. We want to distinguish *how much* backpressure, queue occupancy and worker/inbox control-flow change, **not** time those mutex accesses with added probes.

## Strict source boundaries

- Original M0 source must match Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. P18 candidate must be **byte-identical to the source-locked one-bounded-idle-retry generator** output.
- The [PI instrumenter](../../../../tools/research/m1_p18_pi_make_pair.py) first runs the existing independently audited [event-only source generator](../../../../tools/research/m1_p18_512_make_event_pair.py) against both inputs. Only then does it add new **mutex-owned counters** under the *already existing* `TaskInbox` mutex in separate modules `m1_p18_pi_control_pool` and `m1_p18_pi_grace_pool`. No new locking, atomics, queue policy, wake predicate or critical-section timing calls.
- The [PI TaskRef consumer generator](../../../../tools/research/m1_p18_pi_make_fixture.py) derives both task kernel and driver from exact SHA-locked P13 source via the previously qualified trace fixture generator. It adds only `singleingress` settings, post-join snapshots, a completion polling-yield counter, event invariants and new CSV columns.
- Distinct `pi-control` and `pi-grace` DUB configurations keep all new counters outside uninstrumented throughput builds; original historical trace behavior remains replayable.

## Metrics and invariants

All inbox counters are incremented under the **original inbox mutex**:

| Metric | What it counts | Strict relationship |
|---|---|---|
| `submitCalls/Accepted/Full/Closed` | Individual producer admission results | calls = accepted + full + closed; full = original measured producer retries; accepted = TaskRefs |
| `takeCalls/takeEmpty/takenTasks` | Worker mutex-protected batch claims | nonempty take calls = existing `batchClaims`; takenTasks = existing batchTasks = TaskRefs |
| `peakUsed` | Highest occupied inbox slots after successful submit | 1 ≤ peakUsed ≤ capacity; any full result implies peakUsed = capacity |
| `acceptOccupancy1to8/9to256/257Plus` | Histogram of inbox occupancy immediately after an accepted publication | bucket counts sum exactly to accepted TaskRefs |
| `completeCalls` | Existing post-dispatch completion-accounting operations | completeCalls = TaskRefs |
| `wakeReads/drainReads/announceCalls` | Mutex-protected worker generation checks, drained checks and new local-deque publications | generation reads ≥ batch take calls; announcements ≤ batch claims |
| `pollYields` | Producer-thread polling of completed wave after all TaskRefs have been admitted | nonnegative; **distinct** from the retry count whose original source calls `Thread.yield()` |

For every one-worker 2,048-TaskRef wave with 2,048 ingress slots, `submitFull=0` is an enforced property, independently verified in the existing native run. For smaller capacities, nonzero full results are expected but are **not** a requirement for every small-CI smoke run. Trace-arm phase/order/task/seed/checksum, kernel correctness, stage conservation, existing steal/park/grace event accounting and post-join lifecycle still pass the [independent PI CSV checker](../../../../tools/research/m1_p18_pi_compare.py).

**Counts are not durations.** A change in `takeEmpty` or `wakeReads` is *not* direct evidence that inbox mutex contention caused an observed throughput change. Trace arm instrumentation perturbs scheduling; its elapsed-time columns **MUST NOT** decide performance. The previous uninstrumented ABBA archive remains the speed reference.

## Native XPS protocol

[Foreground PI XPS collector](../../../../tools/research/m1_p18_pi_xps.sh) regenerates both exact-source arms, compiles independent immutable whole-release binaries **before** measurement, runs both original native close/producer race fixtures, and records four sessions of alternating M0-trace/P18-trace process orders, one worker, iterations 128/512/1024, ingress capacities 8/64/256/2048, 2,048 Tasks per wave × three waves, two warm-ups and five measured rounds per setting. It retains source/binary/compiler/affinity metadata, raw process CSV and symmetric 500-ms temperature/frequency/thermal-throttle traces.

Expected collection: **8 complete processes × 12 cases × (2 + 5) rounds = 672 scenario records across both arms (336 per arm)**, comprising **96 matched warm-up and 240 matched measured event pairs** (not the 480 ABBA speed pairs of the earlier uninstrumented experiment). The collector requires exact 85-line process CSVs and both the original per-case zero-full admission oracle and new PI event conservation.

Use a *fresh detached worktree* pinned to the exact research HEAD, preserving existing worktrees and all raw artifacts:

```bash
P18_PI_SESSIONS=4 P18_PI_CPUSET=0,1,2,3 \
  bash tools/research/m1_p18_pi_xps.sh ldc2 \
  /tmp/p18-pi-xps-YYYYMMDD
```

The result is a checksummed TAR.GZ archive outside Git. If interrupted, preserve partial evidence for separate diagnostic review, not as a complete qualification. Remove or redact private host paths before public sharing. Thermal observations flag environmental uncertainties; no single package-temperature threshold decides a performance verdict. CPU frequency samples do not establish per-worker constant effective clocks.

## Subsequent bounded decision

Examine event distributions **per ingress, task size and host session**, especially 512/ingress 8–256 versus **retry-free 2048**. Producer full counts are already known to be zero at 2048; compare occupancy buckets, peak occupancy, empty versus successful takeBatch calls, generation/drained checks, completion-poll yields, actual Condition waits and P18 recovery counts. Determine whether these mechanisms change *together* or whether a narrower further hypothesis is justified. **Do not** attribute elapsed-time cost from these event counts alone.

Only if this diagnostic motivates a bounded *producer retry policy* or *inbox policy* candidate should a **new, independent uninstrumented paired LDC release study** be constructed, with unchanged M0/P18 semantics and native race/close/join qualification. Avoid blind busy-spins, oversubscription, relaxed memory ordering, fairness degradation or accidental performance regressions. No general scheduler production promotion, public `@safe TaskScope`, energy claim or adaptive policy follows from this trace alone.

**Disposition remains KEEP narrow research / DEFER general production.** ADR-0001 PROPOSED, Issue #17 OPEN, PR #38 DRAFT; original M0, `develop` and grandfathered R0.5 PR #35 remain untouched.
