# P18 — Focus512 separate event-only trace protocol (2026-10-14)

**State:** source-pinned research probe prepared, no XPS trace artifact supplied yet. This is **not a third performance benchmark**, a new scheduler variant, or a production API change.

## Motivation and prior non-instrumented evidence

The complete [Focus512 ABBA review](xps-2026-10-14-focus512-abba-review.md) verifies all 1,080 native measured matching M0/P18 pairs from original archive SHA-256 `df4b1e1f60a0f95d4e7a6523f8af3e390e1138402fa1ab3e0718a77f84a61da6`. The 512-iteration ratio favors M0 modestly overall (**1.0119**), while 128 (**0.9559**) and 1024 (**0.9829**) favor P18, and the 512 direction reverses over Sessions 1–2 versus 3–4. One Session-3 grace process had observed package thermal throttling; excluding that *one process's* 45 paired 512 cases still gives **1.0108**. These results do not identify the actual extra yield/search time cost.

**Do not mix event-trace execution time with this independent, uninstrumented speed evidence.** Instrumentation may alter worker scheduling, memory placement and lock timing.

## Exact source discipline

The [event-only pool generator](../../../../tools/research/m1_p18_512_make_event_pair.py) separately instruments:
- Original M0 at exact Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- The exact generated P18 one-yield/one-retry pool, byte-compared against the P18 generator's output from that same pinned original. An edited source copy must be rejected.

The original `source/` M0, generated uninstrumented P18 and all previously recorded archives stay untouched. The trace generator creates differently named `m1_p18_trace_control_pool` and `m1_p18_trace_grace_pool` under ignored `generated/` paths. Per-worker cacheline-aligned counters use single-writer increments. The source still uses the original Condition Mutex to count real waits under its existing lock. Values are only read **after successful native join**.

The [trace-only P13 TaskRef driver](../../../../tools/research/m1_p18_512_make_trace_fixture.py) independently checks exact source blobs for the original P13 kernel and driver. It adds **no task computation changes** and supports the 27-case focus512 settings. Trace DUB configs `trace-control` / `trace-grace` are distinct from `control` / `grace`.

## Event interpretation and conservation

Per-worker aggregated counters record first/second local pop hits/misses, inbox takeBatch attempts/nonempty claims/claimed TaskRefs, foreign steal attempts/successes, park attempts, actual `Condition.wait` entries with accepted−completed zero/positive, and executed TaskRefs. P18 adds these classified outcomes:

- `grace_searches`: exactly one additional worker-local `Thread.yield()` search was scheduled;
- `grace_recovered_local`: second pass found local work;
- `grace_recovered_inbox`: second pass claimed ingress work;
- `grace_recovered_steal`: second pass successfully stole work;
- `grace_fallbacks`: second pass failed and continued into original generation-guarded park;
- `grace_drain_exits`: second pass found the pool fully drained.

**Invariants:** `grace_searches = grace_recovered_local + grace_recovered_inbox + grace_recovered_steal + grace_fallbacks + grace_drain_exits`. All grace counts are zero for original M0. Actual park waits equal the existing `parkCount`, and the no-outstanding/with-outstanding bins sum to those waits. Claimed/executed TaskRefs equal the original task oracle. The [strict trace CSV validator](../../../../tools/research/m1_p18_512_trace_compare.py) checks each matched M0/P18 row's workload, result checksum, stage conservation, and event invariants, **never a speed threshold**.

## Native XPS collection

The [independent event-only XPS runner](../../../../tools/research/m1_p18_512_trace_xps.sh) precompiles LDC whole-release trace-control and trace-grace binaries **before measurement**, reruns unchanged-M0 and P18 actual close/producer race fixtures, pins the process to CPUs 0–3, rotates the two trace-arm process orders over four sessions, and records raw CSV plus symmetric read-only 500-ms temperature/frequency/throttle series. Expected: **8 trace processes**, 189 rows each, and 540 matched measured event observations (4 sessions × 27 settings × 5 rounds). This trace event corpus is not directly paired with uninstrumented ABBA samples in time.

From a fresh detached worktree at the approved research commit:

```bash
P18_TRACE_SESSIONS=4 P18_TRACE_CPUSET=0,1,2,3 \
  bash tools/research/m1_p18_512_trace_xps.sh ldc2 \
  /tmp/p18-focus512-trace-YYYYMMDD
```

The runner rejects existing output paths and creates a TAR.GZ with binary hashes and exact-source provenance. On error retain and archive the partial output without touching other worktrees. Review local host/path data before external publication. CI smoke checks DMD 2.111.0 and LDC 1.41.0 debug, as well as LDC whole release, plus an intentional mutated-source rejection and synthetic negative event-oracle tests.

## Decision boundary

**No mechanism verdict without native event data.** Counts can determine whether the extra yield/search most often recovers useful ingress/local/steal work or merely repeats an empty scan before parking. They **cannot** measure search duration, prove why the 512-work release waves became slower, or establish energy efficiency. Any subsequent adjustment needs a separately controlled uninstrumented A/B result and native lifecycle/race proof.

P18 remains **KEEP narrow research / DEFER universal production**; ADR-0001 PROPOSED; PR #38 DRAFT; Issue #17 OPEN; production `source/`, `develop` and grandfathered PR #35 unchanged.
