# M1 P16.1 — Lower-intrusion completion-call sampling and null-clock control

**Research date:** 2026-10-13  
**Status:** separate exact-M0 three-arm correctness apparatus **PASS DMD 2.111.0 and LDC 1.41.0**, including LDC optimized debug and release ([pinned CI #38453547267](https://github.com/alex-1974/concurrency-d/actions/runs/38453547267)). **The complete P16 native Dell-XPS archive has now been received and independently reviewed**, with no decision yet to modify production.  
**Decision class:** research/diagnostic only, not a public scheduler/API optimization.  
**References:** [P15 complete XPS lock timing evidence](../p15_mutex_timing/evidence/xps-2026-10-13-analysis.md), [P14 native events](../p14_scheduler_events/evidence/xps-2026-10-13-analysis.md), [P13 workload](../p13_worker_scaling/README.md), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Why another experiment?

P15's real XPS observations were internally consistent but **the timed research variant took 2.145× the control's wave time at median**, and ~2.747× for zero-iteration tasks. P15 placed extra timestamps and statistics **inside the shared TaskInbox mutex**, measurably changing its critical section. Consequently, P15's 2.66 µs observed four-worker `completeOne` acquisition interval was **not** a trustworthy estimate of the untouched M0 mutex's waiting time. P15 nevertheless confirmed from **unchanged M0** the task-granularity reversal previously observed by P13/P14.

**P16.1 tries a lower-intrusion, explicitly narrower measurement**: rather than attempt to split mutex acquisition and hold, record the elapsed duration of the *entire* `completeOne()` call for only **one of every 64 tasks per worker**. A companion **null-clock** version reads the same two clocks adjacently before calling `completeOne()`, to characterize timestamp-pair cost and branch/storage perturbation. The exact unchanged production M0 remains the third, **unprobed** timing reference.

Three-arm comparison:

| Arm | M0 module | Every TaskRef | Every worker's 64th completion |
|---|---|---|---|
| `control` | unchanged real `concurrency.internal.submission_pool` | Original dispatch, completion, afterExecution, native join | No extra clocks, no samples |
| `null-clock` | generated copy of exactly pinned M0 | Exact same dispatched task and original `completeOne()` | Read two adjacent `MonoTime` ticks **before** calling `completeOne()`; aggregate after the real call |
| `sampled` | same generated copy | Exact same task, result, completion and native join | Read `MonoTime` immediately **before and after the entire call**; aggregate after it returns |

The two generated modes have the same record allocation, per-worker counter slots, sampling branch, and **two clock calls on sampled jobs**. Their only intended difference is the *position of the second clock*. The third control has neither sampling branch nor timer data structure; a `null/control` ratio is a useful **perturbation diagnostic**, not a perfect isolation of every codegen/allocation difference. The samples do **not** represent all tasks and are not independently selected: every 64th completion may correlate with a worker's scheduling history.

**The P16 measured interval is NOT a mutex acquisition interval:** it includes the real `completeOne()` method entry/return, lock acquisition, critical-section body, lock release, additional function-call and timing costs, and possible OS descheduling. It cannot resolve wait versus hold, and even this 1/64 sampling can change contention or cache behavior. Do not subtract mean null-clock time from mean sampled duration to claim an exact uncontended mutex cost.

## Implementation and ownership guardrails

[Research-only P16 M0 generator](../../../../tools/research/m1_p16_make_sampled_pool.py) checks original M0 Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`, rejects source drift and ambiguous anchors, and produces a separately named `concurrency.research.m1_p16_pool` module in an ignored `generated/` directory. **Production `source/`, root `dub.sdl`, and all published task APIs are unchanged.**

Every worker writes a single **cache-line-aligned, worker-owned** counter struct; there are no additional cross-worker Atomic increments, added Mutex acquisitions, per-task heap allocations, or clock reads inside the inbox critical section. Worker completion counters/sample sums are read only **after full successful native join**. The exact original `completeOne` and afterExecution ordering is retained. The P13 oracle, task scope and record retention remain intact, but the **known native start-after-launch and join-on-failure uncertainties are still unresolved**, so both experimental modes remain `@system`/research fail-stop and must not be promoted to general `@safe`.

[Exact P13 fixture generator](../../../../tools/research/m1_p16_make_fixture.py) checks the previously qualified P13 kernel and driver blobs (`3852e8788757b62c5000ad55565359d6a20a78c1`, `723de6bf76ac838b10de4b3f1cb901315a5ced38`). It creates the **same** 1/2/4-worker, 0/8/32/128/512-iteration kernel, 8/64/256 ingress, wave boundaries, seed/order and task output oracle for all three arms. Compile-time version flags select the imported module.

No source file in the main published library or in any other workspace repository is edited.

## Correctness and instrumentation accounting

The generated fixture verifies **inside the running D binary**, including with assertions disabled in LDC release:

- `accepted == completed == count × waves`; all afterExecution flags, input/output and the independent kernel checksum match;
- `sampled.calls == count × waves`, and the sample-count total is exactly the sum of **floor(perWorkerCompleted / 64)**, not necessarily `floor(allCompleted / 64)`;
- each worker's sample count equals `floor(perWorkerCompleted / 64)`; clocks are monotonic and no timing anomalies are allowed;
- per-worker sums equal the returned snapshot, and individual maximum duration does not exceed the total;
- a small 32-task × two-wave CI test is allowed to have zero samples for a particular worker, because sample scheduling is deterministic per worker and the full configuration only guarantees 64 total tasks;
- an unchanged M0 control emits zero P16 counters.

The independent [P16 three-way CSV validator](../../../../tools/research/m1_p16_compare.py) requires identical **`phase/round/order/seed/workers/count/waves/iterations/ingress/checksum`** in every control/null/sample row, valid sample-count bounds, and valid durations. It **does not gate on speed ratios** and reports a diagnostic per-configuration median `null/control` and `sample/control`. The measured mode's duration-per-sample and null-clock average are given as **different, non-subtractable descriptive signals**.

## Matrix, CI and compiler policy

**Compiler-qualified evidence:** [GitHub Actions #38453547267](https://github.com/alex-1974/concurrency-d/actions/runs/38453547267) **SUCCESS DMD and LDC**, including earlier P01–P15 research and negative gates. The [P16 compiler runner](../../../../tools/research/m1_p16_sampling_probe.sh) compiles the same source for all three modes under DMD **2.111.0** and LDC **1.41.0**, with the research-only DIP1000 preview enabled in its private DUB manifest.

- Two smoke kernel settings (0/128 iterations), ingress 64 and 1/2/4 workers, count 128, waves 3, with two measured randomized sweeps and one warm-up.
- All **45 target combinations** are tested on **both** pinned compilers with 32 tasks per wave × two waves, covering the full native case list but no meaningful performance sampling.
- LDC additionally runs an assertions-on debug **`-O3`** build and a whole-package **release** build with 3 measured sweeps. The P13 kernel result checks and the sampling conservation checks remain active in release mode.
- P01–P15 tests are retained. CI host clock/wake timings are **diagnostic noise** and do not constitute a benchmark acceptance threshold.

## Foreground Dell-XPS run

The native runner [`tools/research/m1_p16_xps.sh`](../../../../tools/research/m1_p16_xps.sh) uses the previous P13/P14/P15 matched native profile:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin research/m1-task-lifetime-boundaries
git worktree add --detach ../concurrency-d-p16 \
    origin/research/m1-task-lifetime-boundaries
cd ../concurrency-d-p16
bash tools/research/m1_p16_xps.sh \
    ldc2 /tmp/p16-xps-2026-10-13
```

The program refuses to overwrite a preexisting directory or archive. It selects four allowed logical CPUs from **distinct physical cores**, applying a **process-affinity mask** only, not individual worker pinning; `P16_CPUSET` overrides this. There are three default sessions (adjustable with `P16_SESSIONS`), **all 45 configurations per sweep**, two warm-up and seven measured sweeps per session. **Three process orders rotate** across sessions: control/null/sample; sample/control/null; null/sample/control. Each session uses the same seed/order and inputs for all three modes. Raw logs, normalized per-sample CSV, exact source/toolchain/affinity metadata, optional snapshots from `sensors`, and validated session comparisons are archived to `/tmp/p16-xps-2026-10-13.tar.gz`.

The native script is CI syntax-checked; it was executed on the user's XPS and the complete original native archive was subsequently supplied and inspected. No remote execution occurs through CI. Original XPS raw manifests/logs may contain user and machine identifiers; inspect them before publication. No continuous frequency/temperature trace or CPU PMU/cycle counter has been collected. The absence of a measurable sampled/control difference does **not** prove the shared inbox mutex is free of contention.

## Next decision and P16.2

**KEEP** the three-arm low-perturbation design only if both compilers and native CPU hardware confirm exact task-result/sample-count conservation and the null/control penalty is acceptably small for the intended granularity. **DEFER** identifying a lock bottleneck or changing production until native data establish what the probes do and do not isolate.

Potential **P16.2** should compare a single alternative completion accounting/wake predicate to unchanged M0 with **both performance arms uninstrumented**, validated against exactly equivalent accepted/completed/closed transitions, park/wake race tests and full native worker joins. Only after those guarantees are proved would any `@trusted`/public `@safe` promotion be contemplated; P06/P07's unresolved exceptional lifecycle remains a separate NO-GO.


## Dell-XPS P16.1 native archive received — 2026-10-13

The complete nine-CSV/raw-log archive has been inspected. See the [native source-integrity and complete interpretation report](evidence/xps-2026-10-13-analysis.md), original SHA-256 **`c256cb16e0dc15d2bfd69f3bd216d3f57b233d34d0d1522ce2d3de870114d816`**, source commit **`69ae6de917b743f2b4f08ca421a2dcd08558951d`**, LDC 1.41.0 DUB release on i7-9750H, process affinity four distinct physical cores. User-identifying host/paths exist in the original logs, which have **not** been copied to public GitHub.

**All 3,645 original CSV rows** have matching workloads, randomized run-order/seed, result checksums, stage sums, valid completion samples and zero clock anomalies. These comprise **945 measured controls, 945 null-clock, 945 sampled and 810 warm-ups** over three sessions. The modes are run in a three-way rotating process order, not simultaneous same-run sampling.

- **Median measured-mode `waves_ns` ratio:** null-clock/control **1.015×**, sampled/control **1.035×**, sampled/null-clock **1.017×** over 945 matched scenarios each. P15's earlier *invasive* timed/control median was **2.145×**: P16.1 has materially reduced the observed perturbation, although per-case ratios still vary substantially.
- With one/two/four workers, per-run mean of the observed **whole** `completeOne()` sampled call had medians **160/316/606 ns**, while the **adjacent-clock null** had **21.0/22.3/22.8 ns**. These describe a workerlokal one-in-64 sampled research clone, **not** uninstrumented Mutex wait/hold times. A simple `sampled-minus-null` correction is **not valid** across separate processes and interleavings.
- **Only unchanged-M0 control** for worker-scaling: median 4w/2w ratios for 0/8/32/128/512 compute iterations **1.563/1.540/1.344/1.069/0.864** across 63 comparisons per workload. Four workers won **0/0/1/20/56 of 63** respectively, consistent in direction with P13–P15.
- The process-level four-physical-core affinity does **not** fix individual worker residency; the optional temperatures are session-boundary snapshots only. No uninstrumented lock wait/hold, hardware PMU, native start/join fault or task-scope `@safe` proof is present.

**Disposition:** KEEP the P16.1 null-clock and lower-intrusion method as qualitative evidence. **DEFER** production completion rewrites, a claimed exact per-task synchronization cost, worker-default policy, C++ performance claims and public `@safe TaskScope`. A bounded P16.2 may research an **un-instrumented, semantically equivalent alternate completion state machine** only after checking accepted/completed/closed/generation/wake invariants and native join obligations under adversarial interleavings. Keep ADR-0001 PROPOSED, Issue #17 OPEN, Draft PR #38 DRAFT and `source/`, `develop`, grandfathered R0.5 unchanged.
