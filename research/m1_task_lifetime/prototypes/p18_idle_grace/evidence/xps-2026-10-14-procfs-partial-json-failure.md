# P18 — Dell XPS `/proc` collector first-process JSON failure (2026-10-14)

**Evidence classification: PARTIAL / collector failure after one complete original-M0 workload. NOT a completed ABBA study, NOT a scheduler performance result.**

## Immutable original evidence

- User-supplied original partial archive: `p18-sched-proc-20261014-184200-partial.tar.gz`
- SHA-256: **`d51ff78705efd1c041a05feb1df481854ac8dd551a348a31e3a7265f00832a36`**
- Observed research HEAD `0adf2e801c026e7f4e7975a0f7957ae79d5a3c0d`; unchanged production M0 `submission_pool.d` Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.
- Compiler **LDC 1.41.0 / LLVM 19.1.7**, DUB 1.40.0, Ubuntu Dell XPS 15 (Linux 6.17.0-22), process mask CPUs 0–3. Exact M0/P18 release binaries built with *different* recorded SHA-256; both real native close/complete/park/producer-race preflights **PASS 324 scenarios per arm**. The real producer/ingress program launched.
- Only the first planned **`session1-sched8-control1` original M0 process** ran. Its raw stdout contains **2/2 warm-ups and 24/24 measured rounds**, one worker, 512 iterations, ingress 8, 2,048 TaskRefs × 3 waves, fixed seed/checksum. All 26 rows have identical work identity and valid stage-time conservation. No P18/grace process or paired experimental result was collected.
- One per-thread sample CSV contains **592 timestamped rows, 38 observed distinct TIDs** (162 main-thread observations), spanning about **308 ms**. Thirty-eight TIDs are successive transient thread epochs and unverified helpers, **not** 38 concurrently active pool workers. Nine TIDs were observed only once; do not interpret thread deltas as full lifetimes. There is NO raw/summarized complete event trace or qualified causal scheduling comparison.
- Thermal preflight: **64 °C** package sample, observational only, insufficient to establish full-process thermal behavior; no postflight because the collector terminated before generating it.
- The archive includes local host paths, PIDs and thread metadata. Keep it outside public Git; this report deliberately does not reproduce identifying process metadata.

## Exact collector failure, not a D fault

At the end of the first successfully executed benchmark process, `m1_p18_sched_proc_sampler.py` called `json.dumps(metadata)`. The `command` entry included a `pathlib.PosixPath` item originating from `--binary`. Python 3.14 reports:

```text
TypeError: Object of type PosixPath is not JSON serializable
when serializing list item 3
when serializing dict item 'command'
```

Consequently there is no `session1-sched8-control1-summary.json`, no full sequence of processes and no P18/M0 paired samples. **Fail closed**: preserve the original partial archive as negative instrumentation evidence rather than inferring that P18 stalled, regressed or succeeded.

## Independent host capability observation

The uploaded `proc-capabilities.json` reports readable own `/proc/<pid>/task/<tid>`, available thread-migration field, but **`kernel.sched_schedstats=0`** and `runnable_wait_time_available=false`. Any zero-looking `schedstat` runqueue-wait counter is **UNAVAILABLE** in this configuration, not proof of zero runnable delay. The central runnable-queue-wait hypothesis therefore cannot be confirmed or refuted by this backend on this host without further explicitly approved host instrumentation. No kernel security setting was changed.

## Research-only correction

In the same grandfathered `research/m1-task-lifetime-boundaries` branch, **only** the per-thread `/proc` collector is corrected to construct its argument list using `str(args.binary)` before retaining the command as JSON provenance. A regression self-test serializes and decodes the same metadata shape (including a synthetic originally-path-typed executable), alongside existing thread-status/stat/schedstat tests. DMD and LDC CI continue testing source-locked M0 and bounded P18 TaskRef/race contracts. No production implementation, historical benchmark, public `@safe` guarantee or API is changed.

**A newly collected and independently checked XPS /proc archive is still necessary before any cross-arm observational conclusions.** Retrying remains an **explicit user choice**. Use the new exact research HEAD, a fresh detached worktree and new output path; do not overwrite or splice the partial archive. Data from `/proc` remain polling-perturbed lower bounds and **must not be ranked as P18 speed evidence**.

**Disposition: KEEP narrow P18 research / DEFER universal production.** ADR-0001 PROPOSED; Issue #17 OPEN; PR #38 DRAFT; `source/`, `develop`, grandfathered R0.5 PR #35 all unchanged.
