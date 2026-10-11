# XPS R0.5 mixed-producer storage comparison — 2026-10-10

**Research evidence, not a production policy change.**

Source: user-supplied XPS terminal capture, `Eingefügter Text(20261010-213048).txt`.
No cryptographic digest of that original terminal capture has been
independently established; an earlier claimed SHA-256 was unverified and
has been removed. The capture contains 120 data rows, all 60 two-policy
pairs complete, and five rounds for each of 12 configurations.
The normalized observations are in
[xps-mixed-2026-10-10-raw.csv](./xps-mixed-2026-10-10-raw.csv);
the [exact follow-up environment and source revision](./xps-mixed-2026-10-10-environment.md)
were provided by the user after the run.

## Provenance and limitations

- Local machine: Dell XPS (terminal prompt `xps-15`), Intel
  **Core i7-9750H** (6 physical cores, 12 logical threads, 12 MiB L3).
  LDC **1.41.0** (based on DMD 2.111.0, LLVM 19.1.7), release build,
  four worker threads, 30,000 tasks per subprocess.
- OS string: `Linux-6.17.0-22-generic-x86_64-with-glibc2.43`.
  The compiler reports host CPU `skylake`; this is not independent
  confirmation of explicit code-generation CPU flags.
- Independent producer counts: 1, 4, 8. Retention budgets:
  8, 64, 512, 4096. Both `freshGc` and `recycleTyped` measured five
  times each; policy order alternated each round.
- Executed on the checked-out branch `perf/r05-owned-task-pipeline`.
  A subsequent `git rev-parse HEAD` **confirmed the exact local
  source commit** `2dd09d85235fde72279545d0efbdffb47b7c51c9`.
  The matrix harness uses `dub build --build=release --compiler=ldc2`.
  CPU governor, power state, thermals and explicit CPU tuning flags
  remain unobserved; `lscpu` reported a momentary 92% frequency scale,
  which is not a controlled clock setting.
- The initial `cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/concurrency-d`
  failed. Git commands and the benchmark nevertheless succeeded from the
  already-active `~/Programmiersprachen/dlang/concurrency-d` repository.
  Future local commands should use the actual checkout.
- The benchmark has a shared atomic execution counter and serialized
  producer submission; observations may reflect these costs as well as
  memory policy. No user-facing @safe API is implied.

## Results

Ratio is `recycleTyped.throughput / freshGc.throughput` computed within
**each** round. Table values are the **median of five paired ratios**;
unpaired median throughputs need not have the same ratio.

| Producers | Budget | Paired median ratio | Min–max paired ratio | Recycling wins / 5 | GC median tasks/s | Recycle median tasks/s | Median fresh recycled nodes |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 8 | 1.0379× | 0.6953–1.6217× | 3 | 314,148 | 322,517 | 1,014 |
| 1 | 64 | 0.9960× | 0.7382–1.0557× | 1 | 373,343 | 316,300 | 212 |
| 1 | 512 | **1.0960×** | 1.0085–1.1720× | **5** | 353,910 | 399,644 | 517 |
| 1 | 4096 | 1.0420× | 0.9481–1.0519× | 3 | 376,477 | 385,648 | 4,102 |
| 4 | 8 | 1.0124× | 0.9857–1.0506× | 3 | 192,553 | 192,711 | 2,131 |
| 4 | 64 | 1.0069× | 0.9075–1.0293× | 3 | 196,855 | 195,706 | 452 |
| 4 | 512 | 1.0120× | 0.9840–1.1024× | 3 | 197,030 | 201,007 | 556 |
| 4 | 4096 | **0.9623×** | 0.9388–1.0322× | 2 | 201,268 | 198,525 | 4,102 |
| 8 | 8 | **0.9696×** | 0.9392–0.9845× | **0** | 185,660 | 180,024 | 2,155 |
| 8 | 64 | 1.0069× | 0.9346–1.0194× | 3 | 190,955 | 189,815 | 639 |
| 8 | 512 | 1.0003× | 0.9824–1.0129× | 3 | 191,503 | 191,697 | 585 |
| 8 | 4096 | 0.9849× | 0.9595–1.0018× | 1 | 193,433 | 188,202 | 4,106 |

`freshGc` creates 30,000 concrete task nodes per case, while the
recycler may reuse most compatible nodes. **This is not a 30,000-to-500
reduction in total GC allocations**: each accepted task still creates
result/handle structures. Example: four producers, budget 512,
median producer-thread GC allocated bytes are about **12,148,048 B
(GC fresh) versus 12,242,096 B (recycling)**, a ~0.8% *increase*
despite median 556 freshly allocated task nodes in recycle mode.
Producer-thread GC bytes do not include worker allocations or describe
GC pause times.

Nearly all recorded subprocess peaks are **18,608 KiB RSS**, except
the first two rows (18,464 / 18,608 KiB). This coarse near-constant
high-water measurement cannot establish lower memory retention,
GC collection cost, or equal memory use for the two algorithms.

## Interpretation

1. **No universal speed win.** With eight producers and budget 8,
   recycling lost in **all five rounds** (~3.0% paired median).
   With one producer and budget 512, recycling won in all five rounds
   (~9.6% paired median). These are conditional observations.
2. **Severe instability in some light-load cases.** With one producer,
   budget 8, ratios ranged from **0.6953×** to **1.6217×**.
   A median of 1.0379× does not mean repeatable performance.
3. **Throughput does not scale with more producers** in this particular
   benchmark. For GC-fresh, budget 512, median total throughput is
   ~353,910 tasks/s at one producer, ~197,030 at four and ~191,503 at
   eight. This may be admission mutex contention, GC pauses, the common
   atomic counter, producer/worker scheduling and/or per-task handle
   costs; the current benchmark cannot attribute causality.
4. **The 256-byte GC-visible callable is one-third of mixed tasks.**
   Exact type equality in the spare-cache lookup reduces cache hits
   under mixed workloads; cache lookup and small-budget churn may hide
   allocation savings.

## Decision and next qualification

**KEEP:** `freshGc` default on `develop` with preallocation-free
full-ingress rejection already accepted through PR #36.

**DEFER:** universal `recycleTyped` promotion. Research PR #35
remains draft and no release/API performance claims are justified.

**Next measured investigations, before changes to the scheduler:**

1. isolate **producer admission throughput** from worker throughput;
   record admission mutex wait/hold distributions, retries and producer
   count in GC and recycle variants;
2. rerun with **separate per-worker counters** or computational work,
   keeping the semantically identical paired policies, to distinguish
   common atomic contention from storage costs;
3. record GC collection/pause information, allocated bytes across all
   threads, RSS under sustained longer runs, and controlled CPU-governor,
   power, thermal and LDC codegen-flag evidence. Exact compiler, OS,
   CPU model/topology and git commit are now captured in the
   [environment record](./xps-mixed-2026-10-10-environment.md);
4. qualify optional per-type spare lists only **after** profiling shows
   spare lookup is material. Type-indexed pools are not justified yet;
5. evaluate latency p50/p95/p99 as well as throughput, not only one
   aggregate tasks/s number.

This experiment has **no basis** for asserting C++/Rust parity or a
general-purpose optimal allocator.
