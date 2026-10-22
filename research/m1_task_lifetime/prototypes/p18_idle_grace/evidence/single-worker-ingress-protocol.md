# P18 — Single-worker ingress/backpressure isolation (2026-10-14)

**Status: source-pinned research experiment prepared; no native XPS results yet.** This is neither a new scheduler algorithm nor an adopted API. Production M0, existing P18 implementation and historical short/long/ABBA/trace archives remain unchanged.

## Motivation: the one-worker counterexample

The complete [Focus512 uninstrumented ABBA evidence](xps-2026-10-14-focus512-abba-review.md) shows at **one worker and 512 iterations** a median paired P18/M0 wave-time ratio of **1.0119** (120 pairs). This is small compared with per-pair variability and changes direction between sessions. Median measured producer-full retry counts were about **5,812 (M0)** versus **5,556 (P18)** per 2,048-TaskRef × 3-wave measurement; median real Condition parks were **3 (M0)** versus **0 (P18)**. [Independent event-only traces](xps-2026-10-14-focus512-event-trace-review.md) recorded **181** P18 second searches across 60 matched 512/one-worker trace measurements (approximately 3.0 per measurement), **zero foreign steals** in both arms and **120** recoveries. The counter data came from separate instrumented processes and MUST NOT be used as timed native evidence.

The original pinned P13 producer calls `Thread.yield()` after every `SubmissionResult.full`; a worker can instead yield at most once after each empty local/inbox/steal search before falling back to the generation-guarded original Condition protocol. The large asymmetry in producer versus worker yield counts motivates a *controlled ingress-capacity intervention*.

**Hypothesis, not conclusion:** at 512 iterations, observed latency shifts may be driven partly by producer backpressure/worker scheduling interaction rather than the intrinsic cost of approximately three bounded worker retries.

## Controlled experiment

The generated P18-only P13 driver adds the research profile `singleingress`; source-locked original P13 driver and task kernel remain untouched, as does the exact M0 source blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.

- **Exactly one worker**, eliminating foreign stealing.
- Same TaskRef record layout, pure task kernel, return/execute oracle, 2,048 TaskRefs/wave and 3 waves.
- Iteration counts **128 / 512 / 1024**; ingress capacities **8 / 64 / 256 / 2048**. Total **12 cases** per measured round. The three iteration counts isolate whether 512 behaves differently from adjacent task lengths; there is no assumption of monotonic task-time dependence.
- **Capacity 2048 and count 2048:** one entire producer wave fits in the inbox without any full-inbox rejection, even if the worker makes no progress. The previous wave completes before submission of the next. The [independent CSV admission oracle](../../../../tools/research/m1_p18_single_ingress_check.py) requires **zero full-inbox retries** for this cell in *every process*, fails unexpected/missing settings, and retains lower-capacity retry diagnostics. Other capacities intentionally retain possible backpressure.
- **No changes to the actual producer loop:** on a full inbox it still performs `Thread.yield()` until accepted. Capacity changes both queue residency and timing; therefore this experiment is an ingress/backpressure *contrast*, not a laboratory isolation of a single `Thread.yield()` instruction.
- **Prebuilt immutable LDC whole-release** original-M0 and P18 binaries, no compilation inside timed processes; retain separate binary checksums.
- Four ABBA/BAAB sessions (16 processes), **two adjacent paired comparisons per session**; every process records exactly **12×(2 warmups + 5 measured) = 84 scenario rows + one header**, and all comparisons enforce equal order/seed/TaskRef/checksum/stage conservation. **480 matched measured pairs**, 160 per task size, 120 per ingress capacity; at **512 iterations and capacity 2048**, **40 measured matched pairs**. These are correlated within four host sessions, not forty independent host configurations.
- Symmetric read-only 500-ms temperature/frequency/throttle telemetry is retained and flagged, not an automatic speed verdict. Native close/producer race fixtures run on real M0/P18 before measurements. Process affinity `0,1,2,3` allows one worker plus a producer to run on separate available cores but does **not** individually pin either thread.

## Native Dell-XPS command

Run from a **fresh detached worktree pinned to the exact current research HEAD**, without touching `develop` or any other repository:

```bash
P18_SINGLE_SESSIONS=4 P18_SINGLE_CPUSET=0,1,2,3 \
    bash tools/research/m1_p18_512_single_ingress_xps.sh ldc2 \
    /tmp/p18-single-ingress-YYYYMMDD
```

[Collector](../../../../tools/research/m1_p18_512_single_ingress_xps.sh) refuses to overwrite output, stores original raw process logs and sampled sysfs telemetry, verifies all scenario counts and zero-full admission in the 2048-capacity cells, writes exact-work per-half A/B checks, and creates a checksummed archive outside Git. Retain partial evidence on interruption. Review original manifest/logs for private machine identifiers before publishing.

## Interpretation rules and next decision

Inspect separately by ingress, iteration count, session, half, and worker count (fixed at one). The primary metric is **paired uninstrumented `waves_ns` P18/M0 ratio**, with `total_ns` as a secondary boundary, `retries` and `park_count` as diagnostic counts. Evaluate both absolute ratios and the paired 512-vs-128/1024 contrast, without using the controls to normalize away actual regressions. Explicitly report any thermal counter increases and process order dependence.

If the 512 penalty largely disappears under the verified zero-full 2048-capacity workload but persists under low capacity, **producer/ingress/backpressure interaction is supported as a further hypothesis**, not yet proven causal. If it persists under both, full-inbox retries alone cannot explain it; inspect producer thread/worker wake, critical sections and other shared state separately. If the data reverse between sessions, keep the effect qualified as unstable and avoid modifying the scheduler.

DMD 2.111.0 and LDC 1.41.0 CI must prove correct profile/TaskRef checksum, invalid-input rejection and 2048-slot no-full invariant; LDC release native XPS must establish any performance finding. **No new event-only trace elapsed time is a speed qualification.**

**Current disposition: KEEP P18 narrow research / DEFER universal production.** No public `@safe TaskScope`, power/energy, scheduler fairness, general GUI workload or API promise follows.
