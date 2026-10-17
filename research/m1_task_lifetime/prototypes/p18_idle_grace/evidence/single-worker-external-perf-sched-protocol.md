# P18 — Linux external CPU-scheduler trace, single worker at 512 iterations (2026-10-14)

**State: RESEARCH COLLECTOR PREPARED; NO NATIVE XPS `perf` TRACE HAS YET BEEN COLLECTED.** No production scheduler, TaskRef/lifetime contract, adaptive policy or benchmark result is changed.

## Source-grounded motivation

The independent Dell XPS phase-boundary audit ([archived research report](xps-2026-10-14-phase-boundary-review.md); source `1c402593`; archive SHA-256 `05a1de88e6c700908e78b3cb1e72f01f370203a6ac421fa22d72cb22476ffc6d`) isolates most of the **512-iteration** P18/M0 difference to submission between first and last successful TaskRef admission when ingress is 8/64/256 (**+221/+258/+250 µs paired median P18−M0**), not post-submission completion waiting (within a few µs). Ingress 2048 has **zero full-producer retries**, and the submission delta is near zero (**−28 µs**). Both arms have almost identical fractions of already-completed work at final admission within each ingress case. These measurements were identically *phase-stamped*, not the original uninstrumented throughput baseline. The separate true uninstrumented 480-pair ABBA corpus remains authoritative for scheduler performance (SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`).

The external Linux scheduler trace asks: **Is producer/worker runnable queue delay, actual CPU runtime, context-switching, or CPU migration different in the backpressured case compared with the retry-free case?** This is mechanism research, not an acceptance test for speed.

## No source or semantic changes

The [original P18 fixed-source generator](../../../../tools/research/m1_p18_make_fixture.py) still checks the exact P13 TaskRef **kernel** blob `3852e8788757b62c5000ad55565359d6a20a78c1`, **driver** blob `723de6bf76ac838b10de4b3f1cb901315a5ced38`, race fixture blob `f158e14ef7a69cff1d2a5005090926794a5846ce`, and unchanged M0 production source `submission_pool.d` blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. Research-only source generation adds two **single-case CLI profiles** without touching the original P13 benchmark, TaskRef execution, M0/P18 algorithms, yield/Condition/Mutex behavior, native join or completion semantics:

| Profile | Workers | Iterations | Ingress | Tasks/wave | Waves |
|---|---:|---:|---:|---:|---:|
| `sched8` | 1 | **512** | **8** | 2048 | 3 |
| `sched2048` | 1 | **512** | **2048** | 2048 | 3 |

Each full XPS process uses 2 warmups + 24 measured rounds of exactly **one** case. Other prior research profiles remain unchanged.

## External Linux perf scope, permissions, privacy

The [dedicated foreground XPS collector](../../../../tools/research/m1_p18_sched_perf_xps.sh) uses **Linux kernel scheduler tracepoints** `sched:sched_switch`, `sched:sched_wakeup` and `sched:sched_migrate_task`, captured with `perf record -a -C 0,1,2,3` (configurable CPU affinity) and read via `perf sched timehist`. The latter offers per-task runtime, scheduling-delay estimates, wakeup and CPU-migration event context (see [Linux perf-sched manual](https://man7.org/linux/man-pages/man1/perf-sched.1.html) and [perf-record manual](https://man7.org/linux/man-pages/man1/perf-record.1.html)). The produced timehist must be checked for **producer main-thread PID and native worker TIDs**; a tool exit code by itself does **not** prove complete thread capture or attribution.

**CRITICAL:** `perf record -a -C` records scheduler events for **OTHER programs and users on the selected CPUs**, even though a later `--pid` filter generates target-specific text reports. Unfiltered binary `perf.data` therefore contains host-sensitive process/thread metadata and MUST NOT be publicly committed or uploaded to GitHub without independent privacy review. Retain original raw TAR.GZ locally; extract/redact only necessary target-process text for any public summary. GPU, other CPU cores and background-load effects are not comprehensively controlled by process affinity.

**Linux `perf` availability and security privileges vary across machines.** Before touching DUB/build state the collector runs a small real tracepoint recording and `perf sched timehist` decode capability preflight. If `perf` is missing, tracepoints are unavailable, or `perf_event_paranoid`/capabilities deny access, it **fails closed** and preserves its diagnostics; it does **not** use `sudo`, lower kernel protections or silently substitute incomplete task-local tracepoints. Do not instruct the user to change system-wide security configuration merely to collect this research.

## Qualification and interpretation

- Build separate immutable whole-release M0 and bounded-one-retry P18 binaries **before** trace collection and retain SHA-256; run native close/producer race preflights for both arms.
- Four sessions; in each, both ingress settings have M0/P18/P18/M0 or reverse (alternating); **32 whole traced processes**. Each process has **2 warmups + 24 measured rounds**, producing **384 matched measured** TaskRef-correct pairs and 32 warmup pairs across profiles/sessions. Process stdout CSV, exact SHA/checksum/seed/phase and timing-stage invariants are verified by the [separate strict workload oracle](../../../../tools/research/m1_p18_sched_check.py), including **zero full-inbox retries with `sched2048`**.
- A shell wrapper records the benchmark's main Linux process PID before `exec`; `perf sched timehist -p PID` is saved with summary/migration and wakeup detail. A specific **worker-TID identification/coverage audit** must verify every inference based on worker scheduling. System-wide perf samples may be lost under buffer pressure; inspect stderr/lost-event diagnostics and omit incomplete traces from conclusions.
- CPU process affinity `0,1,2,3` uses four physical cores on the original XPS, but threads are **not individually pinned**; that is intentional because migrations are part of the question. Pre-/postflight sampled sysfs thermal snapshots are observational, not constant-frequency proof.
- **No automatic speed verdict from perf-recorded processes.** Tracepoints introduce overhead and can alter interleavings. Analyze (a) producer runnable delay/actual run time, (b) worker run versus blocked/runnable wait, (c) voluntary/involuntary context switching where directly supported by source data, (d) migrations and CPU residency, **separately by ingress 8 vs 2048**, arm, session and ABBA half. Never equate an event count with CPU time, and never infer Mutex contention or pure `Thread.yield()` cost without narrower evidence.
- The existing original uninstrumented ABBA and phase-stamped audit remain separate. A favorable external scheduling mechanism observation can justify further research; a production optimization still requires independent unchanged-work, **uninstrumented native LDC-release A/B**, lifecycle/race/safety gates and CPU thermal/frequency provenance.

### Reproducible native XPS invocation

Run in a detached worktree at the reviewed exact research commit, keeping existing work/branches untouched:

```bash
P18_SCHED_SESSIONS=4 P18_SCHED_CPUSET=0,1,2,3 P18_SCHED_ROUNDS=24 \
  bash tools/research/m1_p18_sched_perf_xps.sh ldc2 \
  /tmp/p18-sched-perf-YYYYMMDD
```

On a capability failure **do not rerun with `sudo` automatically**; inspect `diagnostics/perf-capability.txt`, `perf-preflight.stderr` and `perf-preflight-summary.err`, and report whether raw Linux scheduler events were available. On success the collector archives its logs and binary `perf.data` with a checksum, but the raw archive may be PRIVACY-SENSITIVE and should be reviewed before sharing.

**Decision: KEEP the P18 one-retry variant narrowly in research; DEFER unconditional production**. ADR-0001 remains PROPOSED; Issue #17 OPEN, PR #38 DRAFT, production M0, `develop`, grandfathered R0.5 PR #35 and historical benchmark evidence are unchanged.
