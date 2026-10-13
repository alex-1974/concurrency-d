# R0.5 — Post-admission triage and next qualification gates (2026-10-13)

**Disposition:** **STOP** further generic admission-lock/notification micro-optimization under the current owned-task contract without a *new, precisely specified, semantically equivalent mechanism*. **KEEP** the existing research defaults (`freshGc`, `NotificationPolicy.always`, full foreign-victim sweep) and the production M0 defaults. **DO NOT** merge Draft PR #35 wholesale. **KEEP** Issue #20 open: the wider *task-storage/lifetime-family* question is not closed.

This is a **source-and-evidence synthesis**, not a new benchmark, D test, CI pass, optimization, or claim that every imaginable admission protocol is impossible.

## Identity and contract review

- Audited `alex-1974/concurrency-d` research branch `perf/r05-owned-task-pipeline` at **`e786eeddd8dc133e872c68ed8a7b8498dbe907c3`**. PR [#35](https://github.com/alex-1974/concurrency-d/pull/35) remains **open/draft**; [#20](https://github.com/alex-1974/concurrency-d/issues/20), [#17](https://github.com/alex-1974/concurrency-d/issues/17), and [#11](https://github.com/alex-1974/concurrency-d/issues/11) remain open.
- Production `develop` is **`7af4409a2e09a303dfbc6c54033d28c92eb67581`**, verified against the remote branch, with the narrow full-victim bug fix (PR [#37](https://github.com/alex-1974/concurrency-d/pull/37)). Its M0 owned-task and submission-pool sources were independently inspected. The research executor additionally has typed recycling and diagnostic mechanisms; the full M0 and R0.5 executors are **not implementation- or performance-identical**.
- Repository-root `AGENTS.md` and the provided canonical workspace engineering documents were reviewed. `.workspace/` is absent **from GitHub by design**: the repository `.gitignore` contains `.workspace/`, and the workspace `README.md` and `REPOSITORY_STANDARD.md` require those local context hardlinks to be Git-ignored. Presence and inode identity of hardlinks on the owner's Dell XPS were **not independently inspected**; no missing Git tree files were invented or checked in.
- The grandfather/transition clauses of the workspace Git/GitHub workflow protect existing research history. No reset, rebase, branch retargeting, production change or external-repository change is authorized by this decision.

## Checked code-level invariants

The **research** `OwnedTaskExecutor.trySubmitImpl` in `source/concurrency/internal/owned_task.d` currently serializes lifecycle and retention checks, `TaskInbox.hasCapacity()`, ResultCell/TaskHandle/OwnedNode construction, strong `_retained` GC rooting, and `TaskInbox.trySubmit()` under the outer admission mutex. The inner inbox mutex protects committed enqueue, `accepted`, generation and `Condition.notify()`. Workers can remove inbox entries but cannot publish a second owned task while the outer lock is held, so a positive capacity check is not invalidated by a competing owned producer.

Important boundaries that an alleged drop-in optimization **must** preserve:

1. A known-full/closed rejection is detected before per-task ResultCell/Handle/Node construction; the existing dedicated full-inbox producer-thread allocation regression has a narrower scope than an assertion of universal no-allocation.
2. A borrowed `TaskRef` is never made visible before its strong lifetime root exists. Worker completion/result-readiness alone does not permit reclaim: the post-dispatch `returned` release/acquire edge is required.
3. `RUNNING -> DRAINING` and the successful admission decision serialize under the admission mutex; concurrent closers wait for the one join to finish.
4. `acceptedCount()` currently measures **committed inbox publications**, not speculative permits; it is a research/M0 diagnostic, not a newly frozen public API.
5. The generation/condition predicate, shutdown broadcasts, and complete N-slot foreign-victim search must still prevent missed runnable work and lost wakeups. No unproved FIFO ordering between overlapping producers is asserted.
6. Arbitrary cross-thread callable captures are currently `@system`; a storage micro-optimization cannot silently make them `@safe` or claim scope-borrow safety.

The authoritative [admission/close decision](r05-admission-close-linearization-and-inbox-cost-decision-2026-10-13.md) records why simple lock hoisting, late reservation commit, revocation-after-build, and delayed close cut **do not provide an accepted drop-in**. Its 24-configuration Python BFS is abstract capacity/transition evidence, **not native D, GC, linearizability or performance qualification**.

## Evidence disposition — do not reopen unchanged variants

| Mechanism | Relevant evidence | Decision |
|---|---|---|
| Fresh GC owned-task nodes | Long native owned-task baseline and existing M0 default | **KEEP** for currently measured independent owned-task family; not a universal decision for future scoped tasks |
| Current heterogeneously scanned `recycleTyped` | [post-PR37 XPS](results/xps-post-pr37-full-storage-review-2026-10-12.md): 30 paired 100k-task controls, pooled descriptive `recycle/GC=0.96974×`, only 7/30 recycler wins; memory benefit, not a throughput benefit | **REJECT** general throughput promotion; **DEFER** explicitly memory-constrained optional use |
| Indexed/typed cache in lieu of linear spare scan | [lookup diagnosis](results/xps-recycle-lookup-review-2026-10-12.md): ~1.4–2.0 casts/search in the tested mixed layouts, small *instrumented* hold share; no causal native win | **DEFER**, not next general optimization |
| `waiterAware` notify suppression | [XPS notification A/B](results/xps-notification-ab-review-2026-10-11.md): only 28/60 uninstrumented paired wins, mixed latency/idle findings | **KEEP `always`** |
| Producer-indexed counter striping | [XPS counter contention](results/xps-counter-contention-review-2026-10-12.md): median striped/shared ~0.9993× | **NO general win** |
| Victim-order rotation | [XPS rotation A/B](results/xps-rotating-victim-review-2026-10-11.md): no stable gain; complete coverage is mandatory | **DO NOT repeat** |
| Ingress batch1 in place of batch8 | [XPS batch A/B](results/xps-batch-size-ab-review-2026-10-11.md): improves **three-blocker** sibling-start tail, but `freshGc/always`, four producers gave ~0.991× batch1/batch8; four blockers still saturate all workers | **DEFER** universal change; a task-placement trade-off, not an admission fix |
| Two-stage admission reservation | [newer close/linearization model](r05-admission-close-linearization-and-inbox-cost-decision-2026-10-13.md) supersedes the *positive inference*, not the historical older model | **NO-GO as silent drop-in** |
| Claim of a dominant notify/lock CPU cost | [XPS joint cost](results/xps-joint-admission-worker-cost-review-2026-10-13.md) shows major on/off observer effect (`joint_on/joint_off` ~0.7548×, 29/30 slower); [inbox stages](results/xps-inbox-submit-review-2026-10-12.md) are timed elapsed intervals, not causal CPU fractions | **NOT ESTABLISHED** |

These campaigns use different code revisions, binaries and workloads. Their ratios are descriptive and **must not be pooled into a single causal performance estimate**.

## New-mechanism assessment

No currently supported **distinct, contract-equivalent and credible** general admission replacement was identified from the audited implementation and evidence.

- Moving the ordinary ResultCell/Handle/Node creation out of the outer lock either builds work before a valid full/close decision, moves failure past publication, or requires new reservation/close/accounting semantics already blocked in the latest decision.
- Combining/avoiding an inner inbox mutex operation while keeping the same outer mutex is not a free operation removal: the worker-side capacity/claim, generation, park and complete traffic also uses the inner mutex. Holding it across user callable construction would expand worker exclusion. No favorable uninstrumented evidence supports a lock-layout rewrite.
- More notification heuristics, victim-order variations, batch changes, lock-free enqueue, spinning, or indexed recycle are not legitimately *new* admission hypotheses without a separate mechanism argument and consumer-observable gate.

This is a **NO-GO on further generic R0.5 admission tuning now**, not a proof that no future correct optimized scheduler can exist.

## What remains genuinely open under #20

**The storage decision must be made per lifecycle family**, rather than treating incompatible ownership models as faster and slower versions of the same API:

1. **Independent owned tasks** (current research/M0): strongly retain cross-thread callables until worker return, keep result/error per handle, permit dropped handles without dropping accepted work, bounded admission, orderly close. Retain `freshGc` as the present measured reference. A new recycler/arena can be reconsidered only with credible per-task cost and complete memory/lifetime gates.
2. **Scope-bounded tasks** (Issue [#17](https://github.com/alex-1974/concurrency-d/issues/17), M1 [#6](https://github.com/alex-1974/concurrency-d/issues/6)): borrowing/stack residency is *a different lifetime contract*. First define a `TaskScope` in which joined work cannot outlive borrowed inputs, error/cancel semantics are explicit, and rejected publication retains no dangerous references. Require positive and negative **DMD 2.111 / LDC 1.41** source/lifetime probes before predicting allocation savings. Do not advertise arbitrary `@safe` cross-thread closure transport.
3. **Prepared/arena/batch submission**: these change the API, ownership or admission transaction and require an actual independently motivated consumer use case (potentially dcanvas or a real compute pipeline). Without that, **DEFER** implementation. An optional memory-oriented policy must be measured for both memory savings and throughput cost.

### Next bounded engineering gate

**Priority A (research/design, no scheduler patch):** work through #17 first: write down scoped versus owned lifetime invariants; check `scope`/DIP1000 and negative compile probes for escaped stack data, GC-visible captures, exceptions, cancellation, close-with-producers, dropped handles, return-after-dispatch, and noncopyable/destructor-bearing F/R. Separate what compilers prove from what runtime tests observe. Use this to decide whether the proposed scoped storage can be fairly compared to any *equivalent* owned case; record semantic non-equivalence where appropriate.

**Priority B (only after Priority A yields a valid family):** isolate one justified implementation candidate and compare the *complete* task pathway (prepare/construct, publish, execute, complete, reclaim/destruct, close), memory and low-arrival/tail behavior. Use release **LDC 1.41.0 on the Dell XPS** with fresh-process alternating paired uninstrumented controls, workload checksums, original-source SHA, frequency/host-state caveats; DMD/LDC x86-64 and ARM64 semantic gates. Diagnostic instrumentation must not be the acceptance benchmark. Include an independent consumer before calling an API production-ready.

**Production promotion:** The full-victim coverage correction from PR #37 is **already** accepted into `develop`. This review identifies **no further R0.5 scheduler/storage commit presently ready for selective production promotion**. Keep Draft #35 as an evidence-bearing research vehicle and leave #20 open pending task-family qualification. Avoid wholesale branch merging or renaming under grandfather rules.

## Scope of this record

Read-only inspection of GitHub source/docs and the supplied workspace contract, plus this research documentation file. **No new D tests or native benchmark run**, no semantic code edit, no claimed CI PASS at this documentation commit, no XPS archive rewrite, no production branch change.
