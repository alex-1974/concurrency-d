# R0.5 — Native Dell XPS fairness and blocked-task qualification

**Date:** 2026-10-11. **Evidence-only research conclusion.**
**KEEP** existing production `freshGc` and unconditional `always`
notification. No scheduler, public API, CI or runtime change is
justified by this dataset. **DEFER** promoting `waiterAware`,
node recycling, blocking compensation and queue redesign.

## 1. Provenance and lossless archive audit

The user supplied `r05-xps-fairness-blocking.tar.gz`, a three-file
native XPS research archive. It was inspected without executing
archive data. The original compressed archive and members are
authoritative; all checksums below refer to the **original bytes**:

| File | Bytes | SHA-256 |
|---|---:|---|
| `r05-xps-fairness-blocking.tar.gz` | 3,761 | `3f8519d307136a5b08e32b602e1552e17bd9ff32410f9db68feedb9c29bbb93f` |
| `raw.csv` | 4,261 | `b8c4d5799159c933d3a8b39740e2764d97f1f74519f14942a69b1c58de74c001` |
| `summary.csv` | 325 | `204dcf2d3f4accecce5b91d3de4eab4f194b70660656c6a2ce99eed1789f432f` |
| `environment.txt` | 5,527 | `df63000bf04e8ade34bafd2573bf52d0476c32c6a3a207a8c8ba9f7afb6e88b4` |

The source CSVs use CRLF. Both files are stored in Git with
**LF-only line ending normalization and otherwise byte-for-byte
equivalent content**, verified by independently computing the
expected Git blob identifiers from each normalized original:

- [60 complete XPS records, **all original 19 columns**](./xps-fairness-blocking-2026-10-11-raw.csv):
  Git blob `144eb34fda6a86376400253476311d5d8d6fa1e2`.
- [4 complete group summaries, all original 9 columns](./xps-fairness-blocking-2026-10-11-summary.csv):
  Git blob `379d5f7b95432fc07ceacdba548d338a3c1670c4`.

`environment.txt` identifies the exact original source revision
**`c702c65c5687f06d45a0203ffc9c62162741f573`**,
optimized **LDC 1.41.0** (DMD frontend 2.111.0, LLVM 19.1.7),
Linux **6.17.0-22-generic**, glibc **2.43**, on the
Intel **i7-9750H** (6 physical cores, 12 logical processors).
Unlike earlier XPS notification datasets, this particular
environment output does **not** record a CPU governor.
Do not silently transfer the earlier `powersave` observation
to this test. Temperature, power input, background load and
frequency during trials were not recorded.

Configuration: four executor worker threads and four producers;
1,024 accepted tasks per fairness run, 32 queued siblings for
one-blocker scenario, one queued sibling for four-blocker scenario.
Five rounds, both `gc` and `recycle` storage, both
`always` and `waiter` notification variants.

## 2. Completeness and independent validation

The original `raw.csv` has exactly **60 cases, 19 columns**:

```text
5 rounds × 2 storage variants × 2 notify variants
         × 3 scenarios (fair / block-one / block-four) = 60
```

- All 60 (round, scenario, storage, notification, blocked) keys
  are unique and complete.
- In each of 20 fairness trials, `active_workers=4`;
  every reported Jain index is within [0.25, 1] and the
  `max_worker_share` within [0.25, 1].
  The underlying D executable already verified every accepted
  unique task ran exactly once and its per-worker dispatch sum
  matched 1,024 before producing the row.
- All 20 block-one cases reported
  `progress_before_release=1`, `completed=33`.
- All 20 block-four cases reported
  `progress_before_release=0`, `completed=5`.
- All four supplied group medians were recomputed independently
  from the five corresponding `raw.csv` rows, with no discrepancy.

These are **tested interleavings**, not a proof of all progress and
fairness properties of the generic scheduler.

## 3. Per-worker task distribution

The median of five independently calculated per-run Jain indices:

| Storage | Notify | Active workers | Median Jain index | Median largest worker share | Median total run time |
|---|---|---:|---:|---:|---:|
| fresh GC | `always` | 4 / 4 | **0.990426** | 27.0508% | 5.274 ms |
| fresh GC | `waiter` | 4 / 4 | 0.982247 | 30.0781% | 5.239 ms |
| typed recycle | `always` | 4 / 4 | **0.996783** | 27.3438% | 4.983 ms |
| typed recycle | `waiter` | 4 / 4 | 0.973840 | 31.9336% | 5.301 ms |

Jain's fairness index describes **observed dispatch-count
distribution**, not fairness over time, queue latency or starvation.
The task payload is short; the fairness benchmark also blocks
each producer briefly on every 17th typed result, which changes
its injection pattern and therefore worker distribution.

Pair-matched Jain differences `waiter - always`:
- GC: `[-0.033200, +0.033653, -0.001243, -0.011899,
  +0.021153]`, median **−0.001243**; waiter higher 2/5.
- Recycle: `[-0.054382, -0.010927, -0.023140, -0.002149,
  +0.006785]`, median **−0.010927**; waiter higher 1/5.

The modest differences, five rounds, and narrow microtask
workload **do not** establish an inherent fairness win for
`always` or a starvation problem for `waiter`.
All 20 fairness trials used every worker, and all four
storage/notification combinations were correct.

The reported `elapsed_ns` includes producer thread creation,
task submission, intermittent typed-result waits, and
`closeAndJoin()`; it is **not** per-task latency or isolated
scheduler runtime. Paired GC median `waiter - always` time
was **−0.050645 ms**; recycling **+0.373521 ms**.
Neither is a sound algorithmic speedup claim due to instrumented
worker counters and limited trials.

## 4. Semaphore progress versus saturated pool

The blocking probe starts and confirms each blocker **sequentially**
before submitting the sibling tasks, to distinguish actual
worker occupancy from mere task admission.

- **One of four workers blocked:** 32 sibling tasks
  finished **before** release in all **20 of 20** cases
  (4 storage/notification variants × five rounds).
  After release, all **33** accepted tasks finished.
- **All four workers blocked:** the single sibling
  did **not** run before release in **20 of 20** cases.
  After release, all **5** accepted tasks finished and joined.
- In both configurations the observed execution count and
  released blocker count matched the test contract.

**Important CPU accounting caveat:** the four-blocker probe
polls for approximately **100 ms with `Thread.yield()` in the
controlling thread**. Across all 20 four-blocker cases the
median summed **whole-process CPU** time is approximately
**101.9 ms**; that is primarily an artifact of its active
polling and **cannot** be treated as the executor workers'
idle-power or parking cost. A proper idle-CPU investigation
must avoid busy yielding in the measuring controller.

The known prior failed burst-blocker setup
[documented in the protocol](../r05-fairness-blocking-protocol.md)
showed that multiple accepted blocking tasks can be batched
into one worker's local queue and not all start promptly.
**Sequentially confirmed starts avoid that conflation**, but
do not eliminate or refute the burst-placement head-of-line
risk. The current archive did **not** rerun an independent
burst-start experiment.

## 5. Decisions and next research gates

**KEEP**:
- current `always` policy and generation-safe
  condition-variable worker parking;
- existing `freshGc` owned-record baseline;
- the tested exact-completion, backpressure, typed-result
  and shutdown contracts;
- bounded worker-distribution and blocked-task probes in research.

**DEFER**:
- production promotion of `waiterAware`;
- declaration of equal-share scheduling or general starvation-freedom;
- typed-record recycling as a universal faster default;
- work-stealing or inbox redesign, compensating threads,
  nested blocking `get()` support and busy-spinning.

**NEXT:** Isolate the earlier **burst admission / owner deque
head-of-line** behavior with explicit task-start and queue-claim
counters, bounded observation and guaranteed external gate
release. Also test longer heterogeneous CPU-bound tasks,
p50/p95/p99 scheduling latency under realistic load, and
adversarial nested result dependencies. Any follow-up
idle-CPU probe must sleep rather than spin during its
no-work window.

**No code or production CI changes** are proposed by this
XPS-evidence archival step. Research is tracked in
[Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
and [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
Preserve the grandfathered research branch; do not merge it
wholesale into `develop`.
