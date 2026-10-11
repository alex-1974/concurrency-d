# R0.5 native Dell XPS — rotating full-victim search, long mixed / idle qualification

**Status:** native research evidence; **do not promote** a rotating-sweep default. Existing production defaults stay `IngressBatchSize=8`, `freshGc`, `NotificationPolicy.always`.

**Measured Git SHA:** `3c8a5031ca437794afac77220b7b1adfc8584d40`.
**Original evidence:** uploaded `r05-xps-rotating-victim.tar.gz`, SHA-256 `7a58705a85854104c6e1af6161e505e525c65f392dcbe4c30ec42acdf12fe7e6` (not modified). Two evidence trees: `r05-xps-rotating-default` and `r05-xps-rotating-controls`. Their 14 original files should remain the immutable benchmark evidence. All reports below were recomputed from them.

## Measurement environment and completeness

Linux 6.17.0-22-generic x86-64, Dell XPS i7-9750H (6 physical / 12 logical CPUs), LDC 1.41.0 based on DMD 2.111 / LLVM 19.1.7; release builds, no trace mutex. All three executables use **batch8**, identical task lifetime, `containers-d` deque, inbox, notification policy and typed/GC-visible mixed workload. The only scheduler variants are: `old` (N−1 victim candidate positions), `full` (N positions), and `rotating` (N positions plus fair foreign-only first victim across failed searches).

Default-factor tree: five rounds, `gc/always`, workers `1,4,8`, producers `1,4`, minimal/compute, **100,000 tasks per mixed case**, 100ms burst gate, 300ms quiet idle plus 64 wake samples. Control tree: five rounds, four workers, `gc/recycle × always/waiter`, producers `1,4`, same other conditions.

**Verified totals:** 150 untraced burst cases; 1,200 individual Sibling starts; 420 mixed cases (**42 million mixed tasks**); 75 idle CPU/wake cases; 3,420 per-round paired metric contrasts; 684 grouped summary rows. All expected factor keys unique, 5 rounds in each factor group, gate classifications reconciled to individual task timestamps, accepted/claimed counts 11/12 as expected, each mixed test reports exactly 100,000 completed tasks, 64/64 idle typed results. No missing data in case-level CSVs (structural NAs in grouped pair dimensions are expected).

**Major external confounder:** Linux governor is `powersave`. The `lscpu` snapshots reported CPU frequency scaling at **93%** in default versus **56%** in controls. These are only snapshots, *not* accurate sustained clocks per benchmark. No taskset/pinning, deterministic warmup, fixed frequency, thermal or process-noise controls are documented. Median **paired** comparisons limit some noise but cannot prove causes of small throughput differences.

## Uninstrumented burst start results (both trees pooled, 25 cases each)

| Blockers out of 4 | Variant | Pre-gate runnable siblings | Starts after final blocker / before gate | Pooled start p50 | Pooled start p95 | Pooled start p99 |
|---|---|---:|---:|---:|---:|---:|
| 3 | old | 112/200 | 34/200 | 107.1µs | **100.691ms** | 100.730ms |
| 3 | full | **200/200** | 99/200 | 67.1µs | **138.7µs** | 401.4µs |
| 3 | rotating | **200/200** | **122/200** | 70.9µs | **137.2µs** | **161.5µs** |
| 4 | old | 125/200 | 0 | 89.6µs | 100.696ms | 100.719ms |
| 4 | full | 102/200 | 0 | 197.6µs | 100.690ms | 100.706ms |
| 4 | rotating | 127/200 | 0 | 75.1µs | 100.679ms | 100.688ms |

With three blockers, **full and rotating have 8/8 pre-gate siblings in each of 25 cases**, unlike old. This reproduces the earlier XPS isolated full-sweep effect with longer independent measurement campaigns. The rotating variant retains that benefit without the four-blocker *pre-saturation ordering* decline of full. However, with **four** blockers, *all* variants have **zero** starts after the final blocker begins and before the external gate. In one old/4-blocker case the final blocker itself started after gate release; avoid equating its early sibling starts with progress under a fully blocked pool.

All times are callable **start offsets from burst begin**, not per-task submit-to-start latency or general SLA. Nominal gate is 100ms. A per-run p99 from eight siblings is only that case's maximum. Pooled corpus percentages are still scenario-specific; they do not estimate the future application's p99.

## Long mixed throughput, 100,000 tasks per child

Medians of **same-round ratios**, release-internal end-to-end typed/GC-visible mixed task throughput, excluding build time. Values <1 mean a regression. Each row below has 5 paired rounds.

### Default tree: gc/always

| Workers / producers / workload | full/old | rotating/old | rotating/full |
|---|---:|---:|---:|
| 1 / 1 / compute | 0.995× | 1.001× | 1.006× |
| 4 / 1 / compute | **0.895×** | 0.946× | 1.189× |
| 4 / 4 / compute | **1.024×** | **0.975×** | **0.970×** |
| 8 / 4 / compute | 0.997× | 0.988× | 1.002× |
| 4 / 4 / minimal | 1.016× | 1.044× | 1.028× |

Single-producer and one-worker controls vary widely despite negligible semantic differences in actual foreign-victim stealing. One-worker/minimal `rotating/old` median is 0.871×; another single pair is only 0.569×. Therefore differences of a few percent cannot be asserted as algorithmic or reliably free of overhead.

### Control tree: all storage/notification modes, workers=4

Each figure summarizes **20 paired cases** (5 rounds × 4 policy combinations).

| Producers / workload | full/old | rotating/old | rotating/full |
|---|---:|---:|---:|
| 1 / minimal | 0.943× | 0.968× | 1.028× |
| 1 / compute | **0.950×** | **0.918×** | 0.956× |
| 4 / minimal | 0.995× | 0.966× | 1.002× |
| 4 / compute | 1.006× | **0.975×** | 0.989× |

Overall in controls, rotating/old median ratio **0.970×**, positive in only **31/80** pairs. This is not a demonstrated benefit from rotation; a workload-dependent regression remains plausible. In the 4-worker `gc/always` compute case, combining both independent trees (10 pairs) gives rotating/old median **0.982×** (4/10 faster), full/old **1.021×** (8/10 faster), rotating/full **0.972×** (4/10 faster).

**Additional scaling concern:** Under default controls, with four producers and compute, the old scheduler's median throughput is approximately **400k tasks/s at 1 worker**, **246k at 4**, and **149k at 8**. This workload shows strong negative scaling regardless of sweep variant; it is a separate task granularity/contention/scheduling qualification question, not evidence of benefit from the scan change alone. The 1024-round `compute` task body remains a small synthetic kernel. Internal elapsed times in these runs range from ~0.1s to >1s, better than prior 6,000-task probes but still sensitive to system drift.

## Idle CPU and typed-result wake response

Measured after worker startup during an actual 300ms empty-work interval; process-level CPU time, not per-worker energy/power. Under `gc/always`, **four workers** over the two trees (10 runs per variant):

| Variant | median CPU in 300ms | median wake p95 | median wake p99 |
|---|---:|---:|---:|
| old | 327.5µs | 120.8µs | 213.1µs |
| full | 306.0µs | **114.1µs** | **144.8µs** |
| rotating | **269.0µs** | 129.7µs | **220.2µs** |

Idle-process CPU is <~0.25% of one core in any recorded case. No evidence of sustained spinning from rotating, but tiny absolute differences are dominated by measurement noise. In the matched ten `gc/always` rounds, rotating wake `p99` exceeds full in **9/10**, with a median paired difference ~**+65.8µs**. **Caution:** with 64 samples, nearest-rank p99 is literally **the single slowest wake** in that run. This is an adverse *signal requiring replication*, not a statistically qualified tail-SLO regression.

## Engineering conclusion and next gate

1. **ACCEPT mechanism evidence:** complete foreign-victim coverage, with or without first-victim rotation, solves the observed three-blocker batch8 head-of-line tail in all 25 uninstrumented native cases, without making a false claim for four fully blocked workers.
2. **REJECT promotion of rotation at present:** no stable throughput advantage, plausible compute cost at 4 workers / producers, and no reliable wake-tail win over simpler full coverage. The rotating-first-victim property is established in a deterministic candidate-index model, not in a concurrent fairness proof.
3. **KEEP full coverage as a *candidate narrow scheduler fix***. Before production, quantify workload-specific costs (including 1-worker control and >4 workers), fairness under sustained concurrent tasks, compute codegen, CPU governor/affinity and longer consumer workload cases. Production needs a separate small PR with selected regression tests, not wholesale merge of a large research branch.
4. **KEEP defaults and branches:** batch8/freshGc/always, Draft PR #35 open, Issue #20 open, `develop` unchanged. No changes in `containers-d` or other workspace repositories.

Exact scripts and original protocol: `tools/research/r05_rotating_victim_matrix.py`,
`research/r0_5_task_storage/r05-rotating-victim-qualification.md`.
