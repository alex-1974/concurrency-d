# P18 — native Dell-XPS partial A/B review (2026-10-13)

**Status: PARTIAL / THERMAL NO-GO / research only.** This is neither a qualified performance promotion nor a change to the scheduler or lifetime contract.

## Provenance

- Research source HEAD: `fe6eccb7553b857b44e7fa7114e85d930344f339`.
- Unchanged production M0 `submission_pool.d` Git blob: `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- Input archive: `p18-xps-20261013-233551-partial.tar.gz`; SHA-256: `a601030e2ab2e3c4c381cf3080b8b641dedb130d55f2cfe836e25a013db2d0e3`. Original raw archive retained outside this Git tree; the report alone does not reproduce raw data.
- Dell XPS 15 / Intel i7-9750H, process affinity CPUs 0,1,2,3 (separate physical cores), no worker-specific pinning; LDC 1.41.0 / LLVM 19.1.7, release.
- Candidate is original M0 **plus one bounded worker-local `Thread.yield()` and one full extra idle search before unchanged generation-guarded `Condition.wait`**. This is **not** the P16.2 atomic-completion alternative.

## Completeness and oracle

The original script aborted upon a 98 °C package preflight before finishing session 3; its final thermal summary/aggregate archive was not generated. The partial directory was archived without replacing or discarding earlier data.

- Complete A/B sessions: **1** (M0 then grace), **2** (grace then M0). Session 3 has M0 only; session 4 never ran.
- Five existing process CSVs, each 45 configurations × (2 warm-up + 5 measured) = 315 rows, i.e. 1,575 rows total: 450 warm-up and 1,125 measured.
- 630 paired rows across sessions 1–2, including 180 paired warm-ups; **450 measured A/B pairs**, each with identical session/phase/round/order/seed/workload/checksum.
- 45 configurations = 1/2/4 workers × 0/8/32/128/512 integer iterations × ingress 8/64/256. Each measurement executes three waves of 2,048 accepted TaskRefs.
- Independent CSV checks confirmed complete pairing for available A/B runs, matching checksums and nonnegative timing/accounting fields. Both native close/complete/producer race fixtures passed 324 scenarios each before timing.

## Uninstrumented throughput evidence (NOT thermally qualified)

Values are medians of **matched, measured** `grace.waves_ns / original.waves_ns` ratios (below 1 favors grace); each cell includes three ingress choices, two sessions and five repetitions. This is an equally weighted synthetic matrix, not an application-level average.

| Workers | 0 iterations | 8 | 32 | 128 | 512 |
|---:|---:|---:|---:|---:|---:|
| 1 | 0.888 | 0.927 | 0.913 | 0.941 | **1.043** |
| 2 | 0.922 | 0.854 | 0.927 | 0.965 | **1.022** |
| 4 | 0.857 | 0.816 | 0.830 | 0.936 | 0.992 |

- Overall median paired ratio **0.9403**; 337/450 measured pairs favor P18; 38/45 setting medians <1, 34/45 settings <1 in both complete sessions.
- At **1 worker / 0 iterations / ingress 8**, paired median = **0.5058** (session medians 0.5171 and 0.4984). Park-count median falls 438 → 1, but park-count reduction alone does not establish causal time savings.
- At **4 workers / 8 iterations** across ingress settings, median ratio = **0.816**. At **512 iterations**, ratios for 1 and 2 workers = **1.043 and 1.022**: plausible regression warning.
- Session-level all-configuration paired medians: **0.9535** (session 1) and **0.9290** (session 2).
- With one worker, there is no foreign deque to steal from. The large ingress-8 signal merits follow-up on producer backpressure and the search-to-park transition; it is **not** evidence of improved stealing.

## Thermal screen — promotion blocked

500-ms telemetry was symmetrical but sparse (three to five package-temperature samples per process). Per-CPU package-throttle counters are not independent events and must not be summed.

| Session | Arm | Sampled package °C | Observed per-CPU throttle-counter increase |
|---:|---|---:|---|
| 1 | M0 | 84–93 | +54 on each CPU |
| 1 | P18 | 83–95 | +21 on each CPU |
| 2 | P18 | 83–88 | 0 |
| 2 | M0 | 86–91 | 0 |
| 3 | M0 only | 86–99 | +6 on each CPU |

A 98 °C preflight then stopped the run. Initial process preflights below 95 °C did **not** prevent in-process throttling. Session 2 is more favorable thermally but has sparse sampling and cannot rescue full acceptance. Sampled reported frequencies are not proof of constant clocks, nor is absence of a sampled throttle increment proof of no thermal influence.

## Disposition and next gate

**KEEP P18 as a narrow research candidate; DEFER production promotion.** The independent partial comparison is promising for very small tasks, especially ingress 8. It is neither a thermally qualified full A/B measurement nor evidence that the extra search is universally beneficial.

Next: preserve original archive and SHA-256; rerun the **same pinned source and original runner** with improved cooling, new output destination, default `P18_ALLOW_HOT=0`, all four sessions and both mode orders; preserve and review every thermal trace, including any partial output on abort. Separately quantify long-task effects and idle CPU/power before any promotion. No P19, `source/`, `develop`, PR #35, accepted ADR, or public `@safe TaskScope` change follows from this partial result.
