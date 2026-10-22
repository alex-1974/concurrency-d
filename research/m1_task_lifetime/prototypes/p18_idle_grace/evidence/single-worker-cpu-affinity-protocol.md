# P18 — Single-worker 1/2/4-core process-affinity native XPS intervention (2026-10-14)

**STATUS: source-pinned, uninstrumented experiment PREPARED; no native affinity archive yet.**
**Decision unchanged: KEEP P18 narrowly in research / DEFER general production adoption.**

## Research question, source-locked evidence

The independently audited [full native one-worker ingress ABBA benchmark](xps-2026-10-14-single-ingress-review.md) found, at **512 iterations**, P18/M0 median `waves_ns` ratios **1.0627 / 1.0392 / 1.0539 / 0.9875** for inbox capacities 8/64/256/2048, respectively, with full-inbox retries exactly zero at 2048. The [phase-stamped diagnostic](xps-2026-10-14-phase-boundary-review.md) localized most of the difference to the producer submission span (~+221/+258/+250 µs for ingress 8/64/256, near parity at 2048), without proving its cause.

The attempted external `perf` scheduler-event capture was denied by the unprivileged Linux tracefs policy. The independently audited [complete /proc per-thread polling study](xps-2026-10-14-procfs-full-review.md) completed 32 processes and 384 matched TaskRef comparisons, but all `sched_schedstats=0`; runnable/runqueue wait **UNAVAILABLE**, and incomplete observed CPU/context-switch data were highly session-dependent. More copies of the same trace would not isolate the mechanism.

**New testable hypothesis:** The relative P18 512-work penalty under producer-full backpressure may depend on **producer/worker concurrency capacity**. With just one process-affined logical CPU, both threads cannot execute simultaneously; with two or four distinct physical cores they can, subject to the OS. This is a **CPU-availability intervention**, not per-thread pinning and not a measurement of runnable delays.

## What is deliberately unchanged

The [new native-affinity collector](../../../../tools/research/m1_p18_affinity_xps.sh) directly reuses the already qualified exact-source P18 generator and **existing P13 TaskRef kernel and driver**. It builds two immutable LDC release binaries, original M0 vs the **same single-bounded-idle-retry P18**, once before measurement. The original production M0 Git blob remains **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**; unchanged source-locked P13 kernel blob **`3852e8788757b62c5000ad55565359d6a20a78c1`**, driver **`723de6bf76ac838b10de4b3f1cb901315a5ced38`** and race fixture **`f158e14ef7a69cff1d2a5005090926794a5846ce`**. No revised `Thread.yield()` policy, queue behavior, worker algorithm, spin loop, additional timestamp or /proc poll is introduced.

Only a **child-process CPU mask** changes between otherwise identical original M0 and P18 executions:

| Affinity name | Linux process CPU mask | Required physical-core interpretation |
|---|---|---|
| `cpu1` | `0` | producer and 1 pool worker share a logical CPU |
| `cpu2` | `0,1` | allow concurrent execution on up to two physical cores |
| `cpu4` | `0,1,2,3` | allow concurrent execution on up to four physical cores |

The collector requires Linux `taskset` support for all CPU IDs and reads sysfs `physical_package_id/core_id` for CPUs 0–3; it **fails closed** if any selected CPU IDs share one physical core, are unavailable or topology cannot be established. Worker and producer are **not individually pinned**; migrations within the chosen mask are possible. The mask does not control other system workload, CPU frequency governor, turbo, interrupts, cache allocation or SMT behavior elsewhere.

## Balanced XPS procedure and complete-cardinality gates

- Exactly **six sessions** and all **three masks**. The affinity-block order uses the six permutations of 1/2/4 cores, so every mask appears **twice in each block position**, counteracting simple thermal/order drift. Sessions alternate **M0/P18/P18/M0** and **P18/M0/M0/P18**. This permits adjacent matched A/B pairs within each session and mask.
- Exactly **one worker**, **2048 TaskRefs/wave × three waves**, iterations **128 / 512 / 1024**, ingress capacity **8 / 64 / 256 / 2048**: **12 cases** per measured/warmup round. Each whole process has **two warm-up rounds and five measured rounds**, with seeded, checked case ordering.
- **72 whole native release processes** = 6 sessions × 3 masks × 4 process arms; **2,160 directly matched measured TaskRef pairs**, **864 matched warm-up pairs**. For a given `cpuN, iteration, ingress` cell: **60 matched measured comparisons** (6 sessions × 2 adjacent halves × 5 rounds), not 60 independent hosts.
- Prebuilt immutable M0/P18 binaries and SHA-256 retained. Run both native close/producer races at CPU masks `0` and `0,1,2,3` before performance collection, still using unchanged exact-source TaskRef semantics and fail-stop worker lifetime.
- Per-process exact-work, seed, workload matrix, result checksum, stage-time conservation and zero full-inbox retries at ingress 2048 are enforced by the existing [single-worker ingress oracle](../../../../tools/research/m1_p18_single_ingress_check.py). The [new independent matrix/factor validator](../../../../tools/research/m1_p18_affinity_compare.py) requires **all 72 expected process CSV files**, validates cross-mask **identical iteration-specific TaskRef checksums**, exact matched M0/P18 seed/order/work per pair, and reports session medians, raw paired `P18/M0 waves_ns` ratios and a **diagnostic-only** 512-vs-128/1024 control ratio. It has a deliberately corrupted checksum negative test. No CI speed threshold.
- Foreground runner retains original stdout, normalized CSV, symmetric read-only thermal/CPU-frequency snapshots and a 500-ms sysfs telemetry trace, plus hostname/compiler/topology/affinity/source/binary provenance. Sampled temperatures do not establish fixed CPU clocks or energy use; investigate process-specific throttle count increments before interpreting any ratio.
- Original whole-release pairs are **unmodified by tracepoints or periodic /proc thread sampling**; this returns to real uninstrumented scheduler timing evidence. The external telemetry runs asynchronously and samples system temperature/frequency, not individual thread internals.

## Interpretation rules and decision boundaries

For every task size and ingress, report **median of individual matched P18/M0 wave-time ratios** within the same affinity, with session/half distributions and thermal flags. In particular, examine **512-work, ingress 8/64/256 versus 2048** across `cpu1/cpu2/cpu4`. Also inspect the *absolute* P18/M0 difference; a relative-to-neighbor-size diagnostic cannot replace or normalize away regressions. Do not aggregate pairs across CPU masks as if CPU concurrency were equal.

If a systematic 512 deficit appears only where producer and worker can execute on different cores, that **supports a producer/worker concurrency-capacity interaction hypothesis**, not a proven per-yield or lock mechanism. If the deficit occurs under the forced one-logical-CPU mask as well, simultaneous execution is **not necessary** for the effect. If results reverse between host sessions, remain **INCONCLUSIVE** until environmental reproducibility improves. None of these scenarios proves a specific CPU runqueue waiting time or supports automatically changing worker policies.

**Causal caveat:** Changing process CPU affinity changes *more than* overlapping CPU execution: clock/turbo behavior, OS migration options, cache placement, kernel scheduling order, interrupt background noise and CPU resources. It is **not** a direct controlled attribution to `Thread.yield()`, mutex contention, wake notifications or power consumption. A promising producer-side optimization still requires a separate isolated code candidate, TaskRef/lifetime/race qualification and **new exact-source native whole-release uninstrumented A/B/B/A** against M0/P18.

## Native invocation (no sudo/sysctl/tracefs required)

Use a fresh detached worktree pinned to the reviewed exact research HEAD. Collector refuses to overwrite the destination:

```bash
P18_AFFINITY_SESSIONS=6 bash tools/research/m1_p18_affinity_xps.sh ldc2 \
  /tmp/p18-affinity-YYYYMMDD
```

On incomplete execution, retain the original partial output without presenting an incomplete factor or speed qualification. Keep raw host-bearing logs out of the public Git repository; publish only the independently audited digest/report. Do not change any kernel permission or security policy.

**KEEP narrow research; DEFER unconditional production.** `source/`, `develop`, accepted M0, TaskRef lifetime and public `@safe TaskScope` NO-GO, ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38 and grandfathered R0.5 PR #35 remain unchanged.
