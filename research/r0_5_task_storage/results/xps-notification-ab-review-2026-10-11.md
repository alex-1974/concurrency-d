# R0.5 — Native Dell-XPS waiter-aware notification A/B qualification (2026-10-11)

**Decision: KEEP the current `always` notification strategy and
`freshGc` production storage; DEFER `waiterAware` promotion.**
This study resolves the pending five-round XPS measurement request.
No public API, queue/shutdown semantics, result ownership or
production scheduling algorithm is changed.

## Provenance and original evidence

Two user-uploaded native Dell-XPS archives were read as untrusted
tar streams without executing or extracting archive code. Both
`environment.txt` files identify **the same benchmark source
commit** `588cdcdbd87fb6c379074db179f6ccaeb13f2a7e`,
LDC **1.41.0**, DMD frontend **2.111.0**, LLVM **19.1.7**,
Linux **6.17.0-22-generic**, glibc **2.43**, x86-64.
The machine is an Intel **Core i7-9750H**, 6 physical cores /
12 logical CPUs; CPU0 governor was **`powersave`** when queried.
Thermal state, power supply and frequency throughout the runs
were **not controlled or logged**.

| Source file | Size (bytes) | SHA-256 |
|---|---:|---|
| `r05-xps-notification-ab.tar.gz` | 14,337 | `3a740bd0a6aa7e73e72dd885c81b241e6704f293f881fb5e90cd3f893c1c5ed5` |
| A/B `raw.csv` | 32,305 | `d3c19d21fb9c4498bb53bd561c03d7225347bca0d000ea29d22bda1f69c20d2e` |
| A/B `summary.csv` | 1,106 | `10254901206978af0b15a50f5508d583d2cc0db5cc2f908dc91befbf35578124` |
| A/B `environment.txt` | 5,714 | `adb1df6fe51c3b8add7384293a73ef5b7451c626bf68b4cd341f16035cfa6497` |
| `r05-xps-notification-idle.tar.gz` | 2,958 | `036239a68acb865a4d2c158bf1189d84dd847a404a43180ac691dda64268097b` |
| Idle `raw.csv` | 1,047 | `c1529e0b40e3e16cba766010b8a04df7f8ec212fc04d2b1cac224b9985dcdddd` |
| Idle `summary.csv` | 333 | `d75f927b38dccd315802d9c33713e4ce00cb7880b16632f72178e5f26b230412` |
| Idle `environment.txt` | 5,568 | `4dfddb8f88f802174834f04df856acd7eaf07afc9e889335020961cad1240577` |

The original user archives are the canonical **full raw evidence**.
This branch retains a normalized [12-row full A/B summary](./xps-notification-ab-2026-10-11-summary.csv),
[60 paired A/B comparisons](./xps-notification-ab-2026-10-11-paired.csv)
with selected rate, skip, no-work and condition-wait fields, the
[full 10-row latency/idle CSV](./xps-notification-idle-2026-10-11-raw.csv)
and the [exact latency/idle summary](./xps-notification-idle-2026-10-11-summary.csv).
The A/B paired file is **derived** from the 31-column original
240-row file; it is not lossless and does not replace that upload.

### Data validation

- A/B original: **240 observations × 31 columns**.
  Exactly 5 rounds × 2 workloads (`minimal`, `compute`) ×
  2 policies (`gc`, `recycle`) × 3 producer counts (1/4/8) ×
  2 notification policies (`always`, `waiter`) ×
  2 profile modes (`off`, `on`).
  All 240 keys unique; **60 paired unprofiled rate comparisons** and
  independent paired profiled diagnostic comparisons. Four workers,
  **30,000 accepted/completed tasks**, budget 512, striped counters.
- All profile-OFF diagnostic cells are empty. All profile-ON
  diagnostic cells exist. For every profiled case,
  `ingress_calls + ingress_skipped = 30,000`;
  all baseline `always` cases skip **zero** notifications;
  `steal_successes <= steal_attempts`;
  counted condition-wait/post-wait-search outcomes are conserved.
  `still_blocked = 0` in all profiled runs.
- **All 12 published A/B group medians and their per-round
  paired ratios were independently reproduced** within CSV
  output rounding. Full 60-pair derived Git CSV independently
  regenerates every recorded group throughput median/ratio,
  skipped ingress percentage, candidate waits/task and candidate
  empty-after-wait percentage.
- Idle/latency original: **10 × 17 fields** = five independent
  `always` and five `waiter` runs; four workers,
  **250 ms idle interval**, **256 submit-and-wait typed-result
  tasks** per run, 1 ms gaps. Each run reports 256 completions.
  Every published median and paired difference reproduced exactly.

No experiment or verification failure is present in the supplied
archives. This is not a claim about every possible thread interleaving.

## 1. Uninstrumented throughput — paired five-round control

All ratios are `waiter / always` **within the same round,
workload, storage policy and producer count**, not ratios of
independent group medians. `>1.0` favors `waiterAware`.

| Workload | Record policy | 1 producer | 4 producers | 8 producers |
|---|---|---:|---:|---:|
| minimal | fresh GC | **0.9192×** (2/5 wins) | **1.0142×** (3/5) | **0.9848×** (2/5) |
| minimal | typed recycle | 1.0746× (3/5) | 0.9911× (2/5) | 0.9935× (1/5) |
| compute-1024 | fresh GC | 1.0142× (3/5) | **1.0186×** (3/5) | **0.9889×** (1/5) |
| compute-1024 | typed recycle | 0.9814× (2/5) | 0.9983× (2/5) | 1.0113× (4/5) |

Across all 60 matched rate pairs, `waiterAware` won **28/60**;
the **median of all 60 ratios is 0.9937×**.
Pooling diverse workloads is a descriptive diagnostic, **not** a
universal performance estimate or a distribution-weighted workload.

For fresh GC with **four producers**:
- minimal: baseline 197,128 tasks/s vs candidate 199,700 tasks/s
  (separate five-run throughput medians); **paired rate +1.42%**.
  Five individual paired ratios span **0.9433×–1.0351×**.
- compute-1024: baseline 233,367 vs candidate 233,914 tasks/s;
  **paired rate +1.86%**, span **0.9779×–1.0493×**.
- At **eight producers**, both variants reverse sign
  (minimal **−1.52%**, compute **−1.11%** paired median).

**Critical contradiction to hosted CI:** the short two-round,
1,200-task LDC x86-64 hosted trial had shown `waiter/always`
**1.1362×** for minimal/4 producers and **1.1022×**
for compute/4 producers. On the five-round actual Dell XPS
the gains are only **1.0142× / 1.0186×** and disappear at
eight producers. Do not promote hosted speedups or inferred
C++/Rust performance parity into a scheduler contract.

## 2. How many notifications were actually skipped?

Within the separately instrumented **candidate** processes:

| Workload | GC producers | Ingress `notify` skipped (median) |
|---|---:|---:|
| minimal | 1 | 17.80% |
| minimal | 4 | **11.44%** |
| minimal | 8 | **11.47%** |
| compute-1024 | 1 | 38.77% |
| compute-1024 | 4 | **28.84%** |
| compute-1024 | 8 | **26.30%** |

Thus the implementation does reduce `notify()` calls when no
registered waiter exists, while still advancing the wake
generation. But this **does not substantially reduce** the
previously identified empty first post-wait searches.

A directly comparable profile-ON control in the **same** XPS
A/B archive (fresh GC, **4 producers**) reports:
- minimal: `always` median **43.39%** empty first search,
  `waiter` **43.28%**; **median round-paired difference
  −0.17 percentage points**, candidate lower in 3/5 rounds.
- compute-1024: `always` median **36.10%**, candidate
  **35.55%**; median round-paired difference
  **−0.40 percentage points**, candidate lower in 4/5.

The specific 44.50% empty-search result from an **earlier**
native XPS archive used a different run/revision and must
not be substituted as the A/B control.
In the current same-source, same-session A/B runs, skipping
10–30% of ingress `notify` calls barely changes the
empty-wake-search fraction.

The candidate only suppresses calls with **zero registered
waiters**. It cannot intentionally prevent a wakeup when
another worker would win the subsequent task-claim race,
so this negative result is consistent with the narrow
semantics of the candidate.

## 3. Idle CPU and low-arrival submit-to-result latency

Separate Linux benchmark: 4 workers already started, 250 ms
of idle/waiting, then 256 typed-result tasks spaced by 1 ms.
The timing encompasses submission through `TaskHandle.get`
completion. It does **not** isolate the OS notify-to-run interval.

| Metric | Five-run baseline median | Five-run candidate median |
|---|---:|---:|
| idle CPU in 250 ms | 384 µs | 278 µs |
| p50 submit→result | **85.289 µs** | **85.205 µs** |
| p95 submit→result | **122.803 µs** | **111.623 µs** |
| p99 submit→result | **149.802 µs** | **164.790 µs** |

**Aggregation subtlety:** independent p99 group medians make
the candidate look worse, whereas **round-paired p99
differences** are `[−5.998, −13.336, −10.829, −27.904,
+57.364] µs`: it is lower in **four of five** pairs,
median paired delta **−10.829 µs**. Both calculations are
correct because median(`waiter - baseline`) need not
equal median(`waiter`) − median(`baseline`).
The large +57 µs outlier and only five p99 observations
prevent declaring a stable tail-latency improvement.
p95 paired differences
`[−4.859, −7.187, −8.246, −8.142, −11.180] µs`
favor the candidate in all five rounds, but the absolute
timing remains subject to dynamic frequency/scheduling.

The five **paired idle CPU differences** (candidate − baseline)
are `[−179, +291, −106, −170, −76] µs`; median
**−106 µs across a 250 ms interval**. This is tiny
absolute accounting time with a change of sign in one
round, and **cannot justify a power/CPU efficiency claim**.
The process-wide CPU sample does not measure individual
worker idle spin or package energy.

## 4. Engineering decision and promotion gate

**KEEP** on `develop`:
- the existing unconditional `notify()` publication policy;
- the generation + inbox-state guarded `Condition.wait`;
- fresh-GC owned-task record baseline;
- exact accepted/completed execution, typed-result,
  record lifetime, backpressure and shutdown semantics.

**DEFER** production promotion of `waiterAware`.
The five-round XPS trial supplies **no stable throughput win**,
does not meaningfully reduce post-wait empty searches,
and is inconclusive on p99 and idle CPU. Preserve its
prototype and tests on the grandfathered research branch
rather than discarding the negative evidence or merging
the whole Draft PR.

**Do not yet implement** aggressive notification coalescing,
spin-before-park, holding/batching submissions, new queues
or typed-node recycling. Before testing a more invasive
variant, qualify **per-worker dispatch fairness**, blocked
and nested wait workloads, long-idle CPU, observable p95/p99,
and generation-safe lost-wakeup/close behavior. A useful
next research approach would be *observing which worker
claims work after a notification*, rather than assuming
the notify count itself causes producer scaling losses.

**No source implementation changes** are part of this
XPS-evidence archival step; checked-in benchmark source
remains exactly the user-qualified `588cdcdb...`.
Prior [DMD/LDC/native ARM64 consumer CI](https://github.com/alex-1974/concurrency-d/actions/runs/38131825949)
and [LDC native CI diagnostic](https://github.com/alex-1974/concurrency-d/actions/runs/38131825947)
passed on that implementation.

Tracked by [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
and [issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
`develop` remains untouched.
