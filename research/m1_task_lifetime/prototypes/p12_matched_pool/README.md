# M1 P12 — matched-semantics M0 scheduler/record-storage benchmark

**Research date:** 2026-10-13  
**Status:** correctness-qualified benchmark harness; performance decision **DEFER** pending repeatable native target measurements.  
**References:** [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [ADR-0001 (PROPOSED)](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38), [P11 real work-stealing qualification](../p11_real_pool/README.md).

## Exact question

P11 confirmed P09/P10 typed scalar/POD records execute on the **unchanged real M0** `SubmissionWorkerPool` and a controlled test actually ran seven cross-worker steals. It **did not** justify timing P11 against `OwnedTaskExecutor`: P11 returns a synchronous inline result after join while OwnedTaskExecutor has GC-owned callable nodes, per-task `ResultCell`/`TaskHandle`, independently awaited results, different allocation/ownership guarantees, and potentially a longer-lived pool.

P12 asks a smaller, **actually matched** question: **what is the end-to-end cost of storing otherwise identical record batches in caller-stack memory versus a contiguous GC array, while processing exactly the same work on the same M0 scheduler?**

This is a data-placement/storage experiment. It is **not** a comparison of a public owned task API with `TaskScope`, an allocation-count benchmark, or a C++ parity test.

## Implementation

The independent research-only [DUB application](dub.sdl) depends on the **unchanged root concurrency-d package** and its real `containers-d 0.2.0`. [Code: m1_matched_pool_benchmark.d](concurrency/research/m1_matched_pool_benchmark.d).

Both arms execute the **same typed `BenchRecord`**, with `TaskHeader` at offset zero, `shared uint returned`, `int input`, `int result`:

- same compile-time linked static execute thunk and **same `kernel(int)`** (32 integer update iterations);
- same one-word M0 `TaskRef`, `SubmissionWorkerPool` admission, real local deques/work stealing and wake/park behavior;
- same `afterExecution` release-atomic return mark and post-join acquire-load check;
- same thread count, ingress capacity, input sequence `cast(int)(i * 3) - 300`, exact oracle and final `long` checksum;
- same synchronous publication/backpressure-yield/close/join lifecycle; pool created once per sample, used for thousands of jobs, then fully joined;
- **same fixed storage capacity (16,384 records)**, including when fewer jobs are active. This keeps the number of initialized stack/heap slots comparable. All records are retained until successful join and read only after quiescence;
- no virtual task hierarchy; no task handle/cell; no `OwnedTaskExecutor` is included in the timing comparison.

The **only experimental difference** is the record buffer:

- `stack`: `BenchRecord[16_384]` in the calling frame, valid until all threads have joined;
- `heap`: `new BenchRecord[16_384]` contiguous GC array, rooted by the current call and valid until all threads have joined.

The placement does create differences in acquisition/initialization cost, cache/TLB locality and potential GC/runtime effects, all of which the **total** metric deliberately includes. We do not infer a particular cache/GC mechanism from timing alone.

The profiler uses an `@system` API, with a short **`@trusted` header cast** mirroring actual M0 transport, not a public `@safe` task promise. The research `closeOrAbort` aborts if the unchanged pool throws during join, because that event may leave a worker using task-record pointers. This severe fallback remains NO-GO for public availability contracts; native OS errors were not injected here. The M0 start-after-launch failure remains unqualified.

## Recorded metrics and boundaries

[Driver: consumer/main.d](consumer/main.d) prints *machine-readable CSV*. Each sample contains:

```
phase,pair,mode,count,workers,ingress,prepare_ns,pool_start_ns,
submit_join_ns,verify_ns,total_ns,retries,checksum
```

The stage clocks are `MonoTime` deltas, converted using `ticksToNSecs`:

| Field | Start → end | Meaning / non-meaning |
|---|---|---|
| `prepare_ns` | before record declaration/allocation through initialization | Includes stack/GC storage setup and writing active input values. Does **not** count GC allocations separately. |
| `pool_start_ns` | after preparation through pool constructor and native worker startup | Includes pool/deque/Thread setup. Depends on OS scheduling. |
| `submit_join_ns` | pool-ready through all admissions, accepted work, shutdown and joining | **Submission overlaps execution**. This is **not** per-dispatch nanoseconds and cannot be decomposed by subtraction into admission and callback time. |
| `verify_ns` | post-join through input, returned-flag, per-task oracle and checksum validation | Explicit `Exception` checks survive compiler release mode; not part of the actual worker execution. |
| `total_ns` | before storage setup through final verification | Whole synchronous batch including pool lifecycle and verification; first-choice conservative end-to-end comparison. |
| `retries` | occurrences of ingress-full followed by producer yield | Diagnostic work/backpressure, not a direct work-steal counter. |
| `checksum` | signed 64-bit sum of correctly validated results | Must match in **each paired** stack/heap comparison. |

Do not claim that faster `submit_join_ns` establishes fewer dispatch instructions, more steals, fewer cache misses or allocation savings without additional instrumentation. The P11 **deterministic steal test** proves the steal path exists but does not quantify its frequency in this benchmark.

### Sampling protocol

- Warm-up pairs precede measurements; warm-up samples are excluded from medians.
- Every pair executes **both** storage modes; order alternates **AB / BA** across pairs to reduce systematic temporal bias.
- Keep compiler/version/build, inputs, ingress, workers and work kernel unchanged within each paired comparison.
- Report both absolute sample medians/spread and **paired stack-minus-heap** time differences. A positive delta means heap is faster for that sample, not that one model is universally superior.
- Observe and report hardware/runtime configuration, CPU affinity and frequency/thermal uncertainty. Shared CI machines provide **only noisy correctness diagnostics**.
- No test has a speed threshold; a surprise performance result triggers targeted native remeasurement, not an automatic architecture change.

## CI matrix and evidence boundary

The research runner is [`tools/research/m1_matched_pool_benchmark.sh`](../../../../tools/research/m1_matched_pool_benchmark.sh). It runs:

1. DMD 2.111.0 and LDC 1.41.0 **debug/preview DIP1000**: count 2,048, workers 2, ingress 64, warm-up 1 pair, measured 3 pairs.
2. LDC 1.41.0 **debug + `-O3`**, asserts enabled: count 8,192, warm-up 2 pairs, 5 measured pairs.
3. LDC 1.41.0 **DUB release mode** (root package and its dependency graph in release configuration): 8,192 tasks, same pair protocol. The actual P12 oracle/returned-flag/checksum validations use explicit throws and remain live when compiler assertions are disabled.

Each build executes the real same M0 scheduler. The runner strips DUB's build/status chatter from benchmark CSV before parsing, then rejects any incomplete pair, negative field or unequal checksum. It reports median/min/max for diagnostics. The **native XPS capture script is syntax-checked, not executed on CI**.

An initial [CI run #38407124106](https://github.com/alex-1974/concurrency-d/actions/runs/38407124106) produced correct worker outputs, but the Python parser failed because DUB status lines preceded the CSV header (`KeyError: mode`). The parser was corrected without changing the task implementation; [#38407313932](https://github.com/alex-1974/concurrency-d/actions/runs/38407313932) passed DMD and LDC, including the first optimized LDC diagnostic. [#38407680608](https://github.com/alex-1974/concurrency-d/actions/runs/38407680608) passed after adding a release build and explicit always-on checksum/oracle validation; that runner initially did not include the release.csv filename in its final median parser.

**Final pinned research CI:** [GitHub Actions #38408522901](https://github.com/alex-1974/concurrency-d/actions/runs/38408522901), **DMD 2.111.0 / LDC 1.41.0 both PASS**, including all previous P01–P11 gates, P12 benchmark pair/shape/oracle checks, LDC debug `-O3` and **LDC release.csv with five complete checked pairs**. Final test/source/report baseline commit before this annotation: `9f4941105baee6f27806e397addbf85d50dbd14e`.

**Illustrative CI diagnostic only:** on the shared LDC runner, five release-mode 8,192-task pairs produced median **stack 3,899,628 ns**, **GC-array 3,570,603 ns**. Stack range: **3,696,598–4,077,790 ns**; heap range: **3,235,466–4,545,594 ns**. The distributions overlap and the sample size is small. This is **not** a benchmark selection or a proof of GC-array superiority. Absolute times and direction varied across debug/optimized CI attempts and different shared hosts; no production change follows.

**Important:** DMD and LDC ran on distinct shared Azure hosts, which reported different CPUs. Their raw times cannot be divided to form a compiler throughput ratio. Single-run CI results sometimes favor either representation; that is noise/uncertainty, **not an accepted performance finding**. CPU affinity/thermal controls and repeated measurements on the actual target XPS remain necessary.

## Native XPS evidence capture (no CI background job)

[`tools/research/m1_matched_pool_xps.sh`](../../../../tools/research/m1_matched_pool_xps.sh) is an **opt-in foreground** release-mode evidence collector:

```bash
# Run from the concurrency-d checkout on the actual Dell XPS:
bash tools/research/m1_matched_pool_xps.sh ldc2 /tmp/p12-xps-2026-10-13

# Optional: restrict benchmark process-tree to explicit cores
P12_CPUSET=2,3 bash tools/research/m1_matched_pool_xps.sh \
    ldc2 /tmp/p12-xps-affinity-2026-10-13
```

The script runs the *same* real M0 pool on **1, 2, 4 workers × 2,048 and 16,384 tasks**, with ingress 64, three warm-up pairs and **11 measured AB/BA pairs** per workload. It retains:
- `manifest.txt`: source commit, compiler/DUB version, OS/CPU description, kernel, order, workload and affinity choice;
- `raw/*.log`: unmodified DUB/build/prototype output;
- `csv/*.csv`: normalized machine-readable per-sample telemetry;
- `summary.csv`: per-mode median/min/max/p80–p20 spread, and paired stack-minus-heap deltas;
- `<output-directory>.tar.gz`: bundled complete original evidence for upload/re-analysis.

Output is recorded in the user-selected **local directory**; no other repository needs modifying. This command **cannot be executed on the user's XPS from this GitHub-only session**, and no XPS numbers are invented.

To qualify a performance conclusion, run multiple independent native repetitions in a controlled setup, check frequency/SMT/thermal drift, compare paired direction with absolute end-to-end times, and investigate observed material gaps. Use hardware counters and optimized codegen to explain large effects rather than inferring causes from this source layout. Treat a C++ comparison as a **separate, matched-semantics experiment**.

## Status and next step

**KEEP (benchmark/reference only):** controlled, repeatable, pairwise comparison of stack-buffer vs contiguous GC-buffer record placement with **equal semantics** on the unchanged real M0 pool, while explicitly preserving the original P11 owned-executor difference.

**DEFER architecture/optimizations:** CI timing is not XPS evidence; no allocation count, per-dispatch cost or C++ parity has yet been measured. P12 does not remove the known native-lifecycle hazard or approve a public `@safe TaskScope`. No `source/`, production package manifest, `develop`, or grandfathered R0.5 PR #35 is changed.

**P13 candidate after native evidence:** isolate record allocation counts and M0 thunk/execute codegen under pinned optimized LDC, or construct a truly **equivalent owned-result semantics** reference before comparing the public-family costs. Preserve P01–P11 and the proposed ADR/Issue #17/Draft PR #38 contract.


## Native Dell XPS evidence received (2026-10-13)

The previously pending actual-XPS run is now **available and independently reviewed**. See the [native evidence report](evidence/xps-2026-10-13-analysis.md) and [sanitized original summary CSV](evidence/xps-2026-10-13-summary.csv). The user's original 7.8-KiB archive was inspected and hash-pinned in the report, but **not posted to the public repository** because its manifest contains a local username/hostname/path.

**Machine/build:** Dell XPS 15, Intel Core i7-9750H 6 cores/12 threads, Ubuntu Linux x86-64, LDC 1.41.0, DUB 1.40.0, release, no explicit CPU affinity. The recorded archive source commit is `6ef0e9353359bbab6571a3f31eef83bcd1915ebb`.

**Integrity:** all six workloads (1/2/4 workers × 2,048/16,384 tasks) contain 3 warm-up pairs + 11 complete measured pairs. In all **66 measured pairs**, source/task counts, AB/BA order, checksums, stage sums, and summary statistics were verified. Both configurations perform exactly the same M0 TaskRef work and per-result oracle validation.

**Observed (per-mode whole-batch medians, stack vs contiguous GC buffer):** 1w/2,048: 0.725 vs 0.841 ms; 1w/16,384: 4.725 vs 4.844 ms; **2w/2,048: 0.628 vs 0.834 ms**; **2w/16,384: 4.134 vs 4.379 ms**; 4w/2,048: 0.988 vs 1.160 ms; 4w/16,384: 6.903 vs 7.001 ms. The 2-worker cases favored stack in **11/11 paired runs** each; the 1- and 4-worker/16,384-task cases were mixed at 6/11.

**Important causal limitation:** heap record *preparation* typically cost an additional ~137–148 µs **per fixed-capacity batch**. The buffer is **16,384 records even in the 2,048-task cases**, so this constant cost biases whole-batch contrast in small workloads. Post-preparation paired runtime differences are much smaller and mixed. **This does not establish better per-task TaskRef dispatch from stack memory**, nor superior general borrowed-vs-owned executor performance.

**Worker scaling concern:** for stack/16,384, two workers improve only ~1.14× over one, while four workers take ~1.67× as long as two; the 2,048-task case similarly regresses at four workers. This is an important reproducible-once workload-specific observation, not proof of a scheduler bug. The six workloads were run sequentially, with no frequency/thermal trace or core pinning, and may be confounded by load/power/SMT.

**Disposition:** P12 benchmark is qualified as a **single native research session**, but **NO-GO for storage/ownership selection, scheduler optimization or public `@safe` API promotion** until replicated frequency-controlled sessions and more targeted dispatch/scaling experiments. The native source evidence now motivates P13's first focus on worker scaling, separately from a follow-up to isolate preparation versus long-lived pooled dispatch.
