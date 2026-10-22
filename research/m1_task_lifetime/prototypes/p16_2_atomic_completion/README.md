# P16.2 — Atomic-completion / closed-state handshake (research only)

**Date:** 2026-10-13  
**Status:** candidate **CORRECTNESS-QUALIFIED on pinned DMD/LDC** ([CI #38459761896](https://github.com/alex-1974/concurrency-d/actions/runs/38459761896)); the full native Dell-XPS uninstrumented A/B archive is now **RECEIVED and independently analyzed**. Candidate remains **NOT promoted** because performance is workload-dependent and the target CPU was at its reported thermal high threshold in all saved snapshots. This is an isolated alternate completion-state machine, not a production API or a repaired native-start/join exceptional contract.  
**Baseline:** original M0 `source/concurrency/internal/submission_pool.d` Git blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`.  
**Input evidence:** [P16.1 complete XPS evidence](../p16_completion_sampling/evidence/xps-2026-10-13-analysis.md), [P14 path events](../p14_scheduler_events/evidence/xps-2026-10-13-analysis.md), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Source audit: original ownership and state-machine invariants

The current M0 `TaskInbox` synchronizes the FIFO queue, accepted/completed obligations, closed flag, generation and Condition notifier with **one Mutex**. After `dispatchTask`, every worker enters `completeOne` under that Mutex, increments `_completed` and, only if `_closed && _completed == _accepted`, increments the generation and broadcasts. The controlling thread's `close()` also sets `_closed`, increments generation and broadcasts while holding the same mutex. Worker exit requires `_closed && _used == 0 && _completed == _accepted`. `parkUnlessChanged` rechecks under the Condition mutex and calls `Condition.wait`, which atomically releases that mutex while sleeping.

The required invariants are:

1. `0 <= completed <= accepted` and unsuccessful `full/closed` submissions never create obligations.
2. A successful `trySubmit` publishes its TaskRef and records the corresponding obligation before a worker can execute it.
3. No new TaskRefs become accepted once `close` linearizes.
4. After close, worker-exit and park predicates must observe all completions. The final completion must not be missed by sleeping workers.
5. Every successful admission is still executed exactly once, and record storage stays alive until **all real native worker Thread.join operations have completed**; an afterExecution marker alone does not certify full native thread quiescence.
6. The existing `wakeGeneration` / inbox publication / local-deque announcement / Condition.wait protocol is retained. Nonfinal completions introduce no new runnable work and need not send a new wake notification.

Source ownership and the failure semantics of native `Thread.start` / `Thread.join` (P06/P07) remain **unresolved**. This experiment may not be exposed as a general `@safe TaskScope`.

## Exactly one alternative: seq-cst atomic completed count with conditional final notification

[The pinned generator](../../../../tools/research/m1_p16_2_make_atomic_completion.py) checks the *exact* original source Git blob, fails on any changed or ambiguous source anchor, then generates a separately named `concurrency.research.m1_p16_2_pool`. **No production code, root DUB manifest or public API is edited.**

The original `_accepted`, FIFO/queue state, `_closed`, `_generation`, and `Condition` stay protected by their original Mutex. The variant adds three scalar atomics:

- `_acceptedPublished` (`shared size_t`): a seq-cst shadow written *inside* successful producer publication under the mutex; preserves the debug `completed<accepted` invariant without a lock in the completion fast path.
- `_completedAtomic` (`shared size_t`): one **seq-cst** fetch-add per completion; worker completion accounting remains one-for-one. The completed counter is loaded atomically by `parkUnlessChanged`, `isDrained` and the public diagnostic accessor.
- `_closedFast` (`shared uint`): set to 1 with a **seq-cst store inside `close()`'s original Mutex**, before the close broadcast. Each completed TaskRef reads it with a seq-cst load after incrementing the completion count.

When `_closedFast == 0`, an ordinary completion takes **no inbox mutex**. If the closed flag is observed true, that worker re-enters the existing Mutex and, if `_closed && completed == accepted`, performs the same generation increment and `notifyAll()`. Multiple workers may redundantly issue the **final** broadcast under races; the internal generation can advance extra times, but no post-closure TaskRef can be accepted and the wake predicate remains true. There is **no Promise of a lock-free whole scheduler**: sequentially consistent atomics may be expensive or introduce false sharing, and the original ingress, generation, work stealing and parking paths remain unchanged.

### No-lost-final-notify interleaving argument

Let:

- **C**: the *last* worker's seq-cst `_completedAtomic.fetchAdd` reaching `accepted`;
- **LC**: that worker's seq-cst read of `_closedFast`;
- **S**: the controlling thread's seq-cst store of `_closedFast = 1` inside `close`;
- **LS**: its later seq-cst load of `_completedAtomic` while still inside the same Mutex.

Program order requires **C < LC** and **S < LS**. There is one total sequentially consistent order for these operations.

- **C < S:** completion is already counted before the close store. `close` broadcasts under the Condition mutex **after the final count is visible**, and park/isDrained checks see the final predicate.
- **S < C:** completion reads the already-closed flag (because **C < LC** in the same seq-cst total order), enters the Condition mutex, validates `_closed && completed==accepted`, and broadcasts after the final count. If a worker was about to sleep, the mutex-protected Condition.wait exchange prevents a lost notification.

No ordering permits both `close` to miss a pre-close final count **and** the final worker to miss the closed state. A [bounded enumerator](../../../../tools/research/m1_p16_2_sc_handshake.py) checks **all six** two-thread seq-cst interleavings respecting program order. This is a narrowly scoped ordering argument, **not** a complete model checker for Thread.join exceptions, collector/lifetime correctness, every scheduling interleaving, or system-wide fault handling.

The `_acceptedPublished` seq-cst publication is ordered before the queue mutex releases its accepted TaskRef. Thus a worker cannot execute and complete a task before its accepted obligation is visible. Debug mode compares the previous atomic completed count with this published accepted count; the live-task lineage and final joins are additionally tested with explicit checked outputs in release.

### Other state transitions remain intentionally unchanged

| Event | Original M0 | P16.2 research variant |
|---|---|---|
| Successful `trySubmit` | FIFO slot, accepted++, generation++, notify under Mutex | Same, plus seq-cst accepted shadow |
| Full/closed attempt | No obligation transferred | Identical |
| `takeBatch` | Under Mutex, up to eight TaskRefs | Identical |
| Ordinary `completeOne` while open | Mutex, completed++ | Seq-cst completed++, seq-cst closed load, no Mutex if open |
| `close` | Mutex, closed=true, generation++, broadcast | Same, plus seq-cst closed store and seq-cst completed check |
| Final `completeOne` after close | Mutex, final predicate, generation++, broadcast | Atomically count; if closed, lock and check final predicate, broadcast |
| `parkUnlessChanged` | Mutex/Condition, generation and drained predicate | Same, atomic completed load for predicate |
| `isDrained` | Mutex-protected closed, slots, completed | Same Mutex plus atomic completed load |
| `closeAndJoin` | Close, native join every worker | **Identical** |
| afterExecution callback | After completion, before worker returns to deque | **Identical** |

## Tests before performance

[Same-work P13 exact fixture generator](../../../../tools/research/m1_p16_2_make_fixture.py) pins the source blobs of the already qualified P13 kernel and driver, compiles both variants against the same real M0 TaskRef and containers-d 0.2.0 WorkStealingDeque. [Independent CSV validator](../../../../tools/research/m1_p16_2_check.py) rejects mismatched `phase/round/order/seed/workers/count/waves/iterations/ingress/checksum` and invalid stage sums. CI **never** gates on measured speed.

The [adversarial race consumer](race/main.d) tests original and candidate separately with *the same* fixtures:

1. **Closed before last completion:** hold an actual worker inside a blocking task, start `closeAndJoin` in another thread, verify close has linearized using the existing `hasIngressCapacity()==false` on an already drained inbox, *then* release the task. A missed final wake is a deadlock caught by the external timeout.
2. **Last completion before close:** release and observe the original `completedCount()==1`, then close and join.
3. **Concurrent producers and close:** three independent producer threads attempt unique TaskRefs while controlling thread closes/joins, checking `executions == admissions` per record and the final admitted/completed counts.

The original and candidate are run across **1/2/4 workers**, **ingress 1/8/64** and repeated rounds, with both debug and LDC whole-package release checks. Assertions essential to sampled/race semantic correctness are explicit exceptions surviving release builds. The `@system` native exception boundary retains the **research-only fail-stop** rule rather than claiming safe unwinding after a possibly failed join.

[CI #38459761896](https://github.com/alex-1974/concurrency-d/actions/runs/38459761896) **PASS** on DMD 2.111.0 and LDC 1.41.0, including LDC debug `-O3`, whole-package release, and prior P01–P16.1 regressions. The adversarial consumer ran **135 scenarios in each of the original/atomic variants** in debug, and again under LDC release; the complete 45-configuration target preflight validated exact matching input/output checksums and stage timing partitions. No CI performance ratio is an acceptance gate. The [P16.2 DMD/LDC CI runner](../../../../tools/research/m1_p16_2_probe.sh) also executes a bounded full 45-configuration target-profile preflight (0/8/32/128/512 iterations × ingress 8/64/256 × 1/2/4 workers), including the correct per-task oracle and native join/accepted obligations; LDC additionally checks debug `-O3` and release.

## Native performance protocol: TWO UNINSTRUMENTED implementations

Unlike P15/P16.1, **both variants are uninstrumented**: there are no clock reads in `completeOne`, no event counters, and no claimed correction factor.

The foreground [P16.2 native XPS runner](../../../../tools/research/m1_p16_2_xps.sh) builds both release variants, runs deterministic close/park/producer races **before** timing, then compares the full 45-case P13 scenario matrix. The default uses three sessions, two warm-ups and seven measured shuffled sweeps per session, **identical seeds for control and candidate within each session**, alternating whole-process order control→candidate / candidate→control / control→candidate. Worker counts 1/2/4; 2,048 Tasks per wave × three waves; compute 0/8/32/128/512; ingress capacities 8/64/256. Process affinity restricts the workload to four logical CPUs drawn from **distinct physical cores** where possible; this does not pin each worker individually or record dynamic CPU clock frequency.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git fetch origin research/m1-task-lifetime-boundaries
git worktree add --detach ../concurrency-d-p16-2 \
    origin/research/m1-task-lifetime-boundaries
cd ../concurrency-d-p16-2
bash tools/research/m1_p16_2_xps.sh \
    ldc2 /tmp/p16-2-xps-2026-10-13
```

The XPS runner refuses to overwrite an output path. It saves a manifest, full per-sample CSV/raw logs, comparison and sensor snapshots, and a `/tmp/p16-2-xps-2026-10-13.tar.gz` archive. Local raw logs contain host/username/path data; review before public publishing. The runner was executed on the Dell XPS independently of CI; the complete native artifact was subsequently provided and audited. CI does **not** execute remotely on that machine. See the received XPS evidence section below for the actual outcome and its limitations.

## Promotion limits

**KEEP:** one separately named, exact-source, auditable atomic completion hypothesis, strong no-lost-final-wake argument, fixed workloads and checked native-join/lifetime races.

**DEFER:** calling this **lock-free** (other paths are mutex-protected), weakening seq-cst, redesigning shutdown/ingress/parking, production promotion, public `@safe TaskScope`, native start/join exception recovery and C++ parity. The alternate candidate may be slower due to seq-cst fence/atomic cache-line contention; a speed win in a single narrow microbenchmark would not justify merging to `develop`.

Any further work must separately qualify **task latency**, worst-case shutdown, exact accepted/completed obligations under repeated close and adversarial scheduling, and optimized LDC release performance versus unchanged M0. ADR-0001 remains **PROPOSED**, Issue #17 **OPEN**, Draft PR #38 **DRAFT**, and the grandfathered R0.5 work and `develop` are untouched.


## P16.2 native XPS evidence received and qualified — 2026-10-13

**[Complete original-artifact integrity, paired performance and safety interpretation](evidence/xps-2026-10-13-analysis.md).** User-supplied `p16-2-xps-2026-10-13.tar.gz`, SHA-256 **`b56aeb2ee0c0ff3ba49946865b4646ed3d0afae149d7487c74bf1ea7f294758a`**, produced from pinned source commit **`000ca04d7a4f3d2e63e22826dca75b959c06eb0d`** using LDC 1.41.0 whole-release on i7-9750H. **The original raw archive/manifest are not in public GitHub** because they contain local user/host/path metadata.

**Integrity PASS:** all six per-mode/session CSVs matched the CSV output from corresponding original raw logs exactly. **2,430 original rows** = 540 warm-ups + **945 measured original M0 controls** + **945 measured seq-cst candidates**, with every one of the 54 full sweeps containing the expected 45 configurations. All paired `phase/round/order/seed/workers/count/waves/iterations/ingress/checksum` and sum-of-stages timing equations match, preserving the existing P13 result/oracle and TaskRef/native join success semantics. The runner includes adversarial close/completion/producer races before timing; their console transcripts were **not archived**. The previous [DMD/LDC race/optimized/release CI #38459761896](https://github.com/alex-1974/concurrency-d/actions/runs/38459761896) remains the explicit captured race-gate evidence.

**Observed uninstrumented atomic/original wave-time ratios**: aggregate median **0.926×** across all 945 matching measured workcases (atomic wins 592/945), but strong nonuniformity by worker and task size:

| Workers | 0 iterations | 8 | 32 | 128 | 512 | Median over all kernels |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.831× | 0.831× | 0.862× | 0.561× | 0.947× | **0.837×** |
| 2 | **1.165×** | **1.144×** | **1.093×** | 0.649× | 0.840× | **1.028×** |
| 4 | **1.100×** | **1.111×** | **1.105×** | 0.935× | 0.691× | **1.027×** |

Each worker/kernel cell is a **median over 63 matching samples** (3 sessions × 7 measured sweeps × 3 ingress settings); **less than one favors the candidate**. Tiny TaskRefs at 2 or 4 workers usually regress, despite the removed common completion Mutex acquisition. The original four-worker/two-worker crossover persists; the seq-cst candidate's tiny-task four-worker throughput is still worse than at two workers. Some larger-task gains are striking and warrant compiler/codegen/thermal investigation, not unqualified credit to a single synchronization mechanism.

**Scheduler event differences:** at 4 workers, 0 iterations, median observed park entries increased from **169** (original) to **317** (candidate), while median producer retries fell from **32** to **15**, across 63 different-workload/ingress measurements. The source observation does **not** time parked duration or identify a causal mechanism; it establishes that the candidate changed scheduling interleavings, not only lock implementation cost.

**CRITICAL native performance gate:** all **six** saved per-session before/after `coretemp` snapshots show **CPU Package +100.0°C (reported high=100.0°C)**, with fans near the reported upper speed. There is no in-run frequency/thermal-throttling trace, so sustained throttling is **not proven**, but this benchmark must **NOT** be promoted as thermally stable optimized-release evidence. Three sequential sessions with alternating whole-process mode order do not eliminate temperature/frequency and OS scheduling confounders.

**Decision:** KEEP P16.2 as a correctness-qualified **RESEARCH hypothesis** and archive its native A/B evidence; **NO-GO** for unconditional production promotion, changing the MemoryOrder.seq handshake, general public `@safe TaskScope`, new worker defaults or C++ parity. Next evaluate stable-frequency XPS sessions and compiler optimized-code differences, particularly 1-worker/128-iteration acceleration and increased tiny-task parking. The original M0, production code, `develop` and grandfathered R0.5 work are untouched; ADR-0001 remains PROPOSED, Issue #17 OPEN and PR #38 DRAFT.
