# P42 proposal — notification coalescing, research-only

Status: **research-only implementation and ongoing qualification** (2026-10-17).
The initial protocol below is retained as historical design evidence; the
conditional source-pinned overlay was subsequently built and tested through
P42.15. P42.16 now targets symmetric four-worker waiter observation and
per-task worker attribution (see
[`p42_15_multi_idle_protocol.md`](p42_15_multi_idle_protocol.md)).
This is neither a production change nor a release/performance acceptance.

## Motivation and baseline

P37's producer timing isolates mutex wait, ring publication and notify call intervals, not actual OS wake costs. P39 observed one publish `notify()` call per accepted task, P40 observed many worker return-to-wait outcomes; they cannot be causally paired. P41 establishes limited generation/close correctness baselines, not safe notification suppression. Consult `../../p37_p40_wakeup_synthesis.md` and the P41 qualification ledger; retained native archives are the source of truth.

## Candidate (H2), explicitly unproven

Evaluate a **research-only, source-pinned** conditional publish notification, using the same inbox mutex and generation increment on *every accepted publication*. An example concept: track the exact number of workers that have entered the inbox's protected condition-wait predicate and request a notification only when there is a confirmed waiter and newly available work. **Do not implement that rule before proving it:** a worker may be between external search and park, local-work announcements can be required to wake idle thieves, and the last active worker can transition to waiting after a suppressed publication. A naive `waiterCount>0` test could deadlock if generation transitions or work handoff are mishandled.

Consider batching only after specifying a wake-ticket invariant and a finite progress guarantee for idle-but-runnable tasks. Preserve existing generation checks and queue semantics. Do not mutate the production module, public API, root registry, ownership/lifetime policy, task record reclamation or close/final-completion `notifyAll`.

## Qualification plan

1. **State-machine design:** enumerate one/two workers, one/two producers, bounded ingress, local-deque handoff, generation capture before search, admission, wait enrollment, publish, completion and concurrent close. Supply explicit proof obligations and counterexamples for suppressed notifications.
2. **Pinned implementation overlay:** introduce one independently reviewable toggle for the hypothesis. Keep original and research variant from one exact source pin. Do not alter work stealing, task batching, scheduling search order, queue capacity or work payload.
3. **Deterministic race tests:** idle worker before publish; generation captured before publish; wait already enrolled; multiple sleeping workers; work moved to local deque and thieves waiting; close before/after park; close with outstanding work; final completion releases shutdown waits. Every accepted task must execute exactly once; no missed wakeup or unbounded join.
4. **Compiler and safety:** DMD 2.111.0 / LDC 1.41.0 debug + current workspace gates. Source audit must reject drift; timeouts diagnose suspected deadlock but do not prove liveness.
5. **Performance only after correctness:** run an uninstrumented original vs variant on identical tasks/ownership/producer/worker/ingress/warmup, randomized or rotated session orders, multiple native XPS sessions, LDC optimized. Record full artifact SHA-256, source hashes, timings, retries and thermal/frequency context. Show latency tail as well as throughput, not a single headline median.

**Stop criteria:** any stuck close/join, missed task, incorrect root lifetime, starvation in tested schedules, changed observable admission/ownership semantics, source drift or inconsistent CI. Do not interpret publish notify count reduction as a throughput victory without native evidence.

The **first deliverable** is the design and adversarial schedule table; no policy switch and no native performance run is authorized by this note. PR #38 Draft; ADR-0001 Proposed.

## P42.1 bounded policy exploration

`tools/research/m1_p42_two_worker_model.py` is a **finite-state abstraction**, not a proposal to suppress production notifications. It explores two workers, two one-shot producers, inbox capacity two, one-task claims, worker park/execute/exit, and shutdown broadcasts. It compares the current always-notify publication policy with an idealized notify-if-waiter policy and a deliberately unsafe no-notify control. The control must yield a concrete quiescent lost-work counterexample, which is reported as an event trace. Source anchors are checked against the unchanged production inbox.

**Limits:** Worker generation capture and search-to-park are abstracted into a single atomic transition; worker waiting registration is idealized. There is no work stealing, local deque, root lifecycle, OS condition wake behavior, fairness bound or admitted-task cancellation. Therefore a green model for `waiter` **does not prove** that a real waiter-count-based strategy is safe. Its next research task is to model generation-ticket capture and waiter enrollment as separate interleavings and seek counterexamples *before* any overlay implementation. P42 is not a performance result.

## P42.2 separated ticket/search/park model

`tools/research/m1_p42_ticket_enrollment_model.py` extends the bounded two-worker/two-producer abstraction with **distinct** generation-ticket capture, inbox search, mutex-guarded park-predicate decision, actual wait enrollment, task claim/completion, and close/final-completion broadcasts. It explores baseline always-notify, idealized notify-if-already-waiting, and silent control policies. The negative control is required to exhibit a queued-work/all-waiting trace; baseline and idealized waiter policy are required not to exhibit one in this limited state space.

This tests one very specific lost-work pattern, **not** starvation freedom, notification count reduction or production correctness. In particular, the model does not encode owner deques, stealing, batch handoff, actual mutex queueing, OS notify semantics, root lifetimes or arbitrary producer sequences. A green idealized waiter-policy model is a hypothesis-screening result only. No coalescing overlay or benchmark is authorized without further adversarial qualification.

## P42.3 local work and idle thieves

The P42.3 bounded model explores a two-task inbox batch. A worker executes one task and places the other on its local deque, while a second worker waits. The baseline wakes the second worker upon local-work announcement. A control variant without the local-work notification demonstrates delayed stealing, not a global deadlock: the owner can eventually execute both tasks. This does not establish any safe notification optimization, nor model full thread scheduling. CI is required before claiming the model has passed.

## P42.6 initial conditional publish overlay (experimental)

`tools/research/m1_p42_make_conditional_pool.py` generates `m1_p42_pool.d` from the unchanged production `submission_pool.d`. The *only* synchronization-policy change is in `TaskInbox.trySubmit`: a publication still inserts its task, increments accepted and generation under the inbox mutex; `notify()` is issued only if `_waiters != 0`. The research-only waiter counter is incremented immediately before `Condition.wait()` and decremented after its return, under that same mutex. Local deque `announceLocalWork()`, close `notifyAll()`, final completion broadcast, work search and FIFO ordering are unchanged.

`tools/research/m1_p42_conditional_gate.sh` executes a first source-pinned native D race smoke test (12 one-worker cases with a task published after an observed wait entry), with a bounded external timeout. This is a **partial correctness gate**, not proof of general progress with multiple waiters or competing producers. The broader P42.5 adversarial model is not a runtime test. A subsequent gate must cover idle-to-active races, at least two workers/two producers, batch handoff, close, accepted-task once-only completion and lifetime constraints before running optimized performance measurements.

Do not interpret a lower publish notification count as throughput improvement without matched, uninstrumented XPS evidence. The hypothesis might still be invalid or slower. No production code is changed.

## P42.7 multi-producer correctness gate

The conditional research overlay now runs a bounded native consumer with **four producer threads, four worker threads, 256 distinct tasks per round, eight rounds and inbox capacity eight**. Producers retry full submissions; all producer threads join before close. Each task record remains alive through pool close/join and must execute exactly once; admitted and completed totals must both be 256. This supplements, but does not replace, the observed-wait single-worker test. The process is externally time-limited. **Concurrent producer-vs-close admission is not covered** because close occurs after producer joins; neither unrestricted starvation freedom nor performance is established. The new compiler CI run must pass before qualification.

## Current follow-up — 2026-10-22

P42.19 reproduced the native performance benefit at its declared research
screening boundary; see [the replication review](p42_19_native_xps_review_2026-10-18.md).
[P42.20 initial correctness review](p42_20_correctness_review_2026-10-22.md)
now separates publication progress, last record access and native join,
with a new minimal-overlay return-boundary consumer. Production qualification
remains open; the earlier dated sections above are historical evidence.

The P42.20 follow-up now includes controlled publish/park/close/local-handoff
races with two detected invalid-policy controls, the actual M0 owned executor
under the minimal conditional pool (GC, typed/void/error, reaping and close),
and a separate CPU consumer with controller-thread completion application.
Local DMD 2.111.0 and LDC 1.42.0 debug/-O3 correctness pass; pinned CI remains
pending. See the P42.20 review for exact scope and exclusions.
