# M1 P31 — Fixed-producer scaling and atomic-task-contention research

Date: 2026-10-15. Status: research-only benchmark, not an API decision and not a native XPS performance result.

Tracking: [Issue #17](https://github.com/alex-1974/concurrency-d/issues/17), [ADR-0001 PROPOSED](../../../../docs/adr/ADR-0001-task-lifetime-families.md), [Draft PR #38](https://github.com/alex-1974/concurrency-d/pull/38).

## Why P31 is required

[P30's two XPS captures](../p30_ownership_benchmark/README.md) measured profiles with one, two, and four producers; the four-producer profile also changed worker count, admitted work count, and queue capacity. The observed profile throughput differences are therefore not a pure producer-scaling result. In addition, P30's TaskRef job increments two atomics in one shared result object, potentially introducing unrelated cache-coherence contention.

P31 fixes all scheduler/task-count dimensions across producer profiles and deliberately varies task-side atomic work. It preserves the **same production M0 SubmissionWorkerPool**, P23 source-pinned owner, and actual P29 generational manager; it does not add a competing work-stealing scheduler.

## Fixed-work and mode matrix

The XPS capture fixes 8,192 accepted TaskRefs, four M0 workers, ingress capacity 128, and retention budget 1,024 for every profile. It changes only producers (1, 2, 4) within a given task-work variant. Each producer supplies exactly taskCount / producers successful admissions.

Every producer/work profile compares the original M0 direct executor, P23 deferred-start direct executor, and real P29 manager. Three task variants are tested:

| CSV work | Task-side behavior | Independent oracle |
|---|---|---|
| shared_atomic | Two atomic additions to common count/sum | count and checksum must equal 8,192 and 491,520 |
| sharded_atomic | Same two atomic additions to per-submitting-producer counter object | each producer shard must reach its exact count/sum; aggregate must match |
| minimal | Constant integer return with no custom atomic counter | original M0 accepted/completed and native join must equal 8,192 |

The sharded case uses separately allocated, padded class objects to reduce shared-counter contention, but does **not** certify cache-line separation or eliminate all false sharing. The scheduler may execute any producer's tasks on any worker. The minimal case does not independently observe each task's side effects; its native accepted/completed counts remain the oracle.

**Comparison rule:** The three ownership modes are semantically matched only **within** a given task-work kind. Comparison **across** different work kinds is a mechanism diagnostic, not an equal-work performance claim.

The original M0 mode has a weaker independent owner/native-failure contract than the P29 manager; fast timings cannot justify removing process GC roots, native join checks, or generation validation.

## Invariants and methodology

Every mode must accept and complete exactly the fixed count, keep all accepted tasks until real native worker join, and preserve the exact counted-task checksum. Timings are separated into create/start, producer submission (including producer-thread start and join and overlapping worker execution), join/reclaim, and total phases. Attempts and producer-thread GC allocation deltas are also recorded.

Both owner-arm order and producer/work profile order rotate by round to reduce fixed position effects. The XPS runner uses three warm-up and nine measured rounds, not speed thresholds. Sampling occurs on real native work; CI timing is only a correctness diagnostic.

The [CSV analyzer](../../../../tools/research/m1_p31_analyze.py) rejects missing/duplicated arm triplets, changing fixed dimensions, mismatched accepted/completed work, incorrect checksum or per-work count, and inconsistent timestamps. It reports per-round-paired throughput ratios (two or four producers relative to the single producer) under the **same task/worker/ingress/retention dimensions**. Its independent self-test deliberately mutates timing and task records to demonstrate rejection.

Reproduction and evidence capture from a clean research checkout:

    bash tools/research/m1_p31_fixed_scaling.sh dmd
    bash tools/research/m1_p31_fixed_scaling.sh ldc2
    bash tools/research/m1_p31_xps.sh

The XPS script records raw CSV, full textual DUB output, host/compiler/CPU governor metadata, analysis and JSON summary outside the repository. It creates a tar.gz and SHA-256 receipt suitable for independent review. No P31 XPS archive has been submitted or analyzed yet.

## Scope and hard limits

The shipping source blobs remain pinned: owned_task.d at e74d6a73f956c562eab176e27687a47249f5815d; submission_pool.d at b7d8fafcb3179f00cba7e89e28c6d6b9b676353a. The P23 research clone is generated temporarily and removed by the runners.

P31 does **not** directly time the M0 admission mutex acquisition, GC safepoints, individual deque steals, CPU utilization, or cache-coherence traffic. Those require a later targeted instrumented and untouched-M0 paired experiment. In particular, the minimal-work task has different callable/record storage from the two atomic variants. A difference between variants can motivate, but not alone prove, an atomic or GC bottleneck.

Any P29 per-submission lock change needs the same generation/lease/worker-join safety proof as P29 plus optimized native-XPS evidence. Do not promote P31 research to source/, develop or main. Preserve PR #35 and existing M0 evidence. Issue #17 OPEN, ADR-0001 PROPOSED, PR #38 Draft.
