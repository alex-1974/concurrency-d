# P39 — notification-site attribution (research plan)

P38 XPS on 2026-10-17 verified worker condition-wait entry/return conservation, but it could not assign return events to producer publication, local-deque work, shutdown, or final completion.

## Scope and safeguards

Generate a research-only module from the pinned P38 pool and do not modify `source/`. Count notifications at four mutually exclusive sites: `trySubmit`, `announceLocalWork`, `close`, and the final-completion branch of `completeOne`. Count *calls*, not successful kernel wakeups. Preserve mutex, generation increment, condition predicate, task order, ownership and root lifetime exactly. Counters must be read only after every worker joins; production performance is never inferred from instrumented timings.

Maintain P38 `waitEntries == waitReturns <= parkCalls` separately. A `notify()` call is not one sleeping worker; `notifyAll()` is one call which may make multiple waiters runnable. Wakes from spurious returns are permitted. Keep the four notification-site counts separate, rather than subtracting one to estimate useful wakeups.

## Qualification order

1. Source audit and generated-overlay anchor preflight, including one-to-one insertion at the four notification sites, with no syntactic modification of the predicates.
2. DMD 2.111 and LDC 1.41 correctness and negative tests in CI. Validate total publish-notify equals accepted tasks for owned modes; closure and final-completion counts depend on the actual state and should be independently asserted.
3. Extend the P31 consumer's CSV only once compiler correctness is green. Compare null versus timed and original matched work, preserve 27-profile matrix and 3 rotated sessions.
4. Only then collect native XPS and report separate site calls, wait-entry/return counts, and per-session variability.

No P39 performance conclusions or native evidence exist yet. PR #38 Draft; ADR-0001 Proposed.

## Native measurement handoff

After successful DMD/LDC qualification at `be523a2d9272b99316bfaafecee8b1ef1ccff458`, the rotated 3-session P39 collection script `tools/research/m1_p39_xps.sh` and optimized null/timed configurations were added. The original P31 arm remains unchanged. Run on the XPS only after the latest research-branch CI is green; the generated modules are removed on exit, and the script refuses existing generated files and existing output paths. Save and upload the resulting archive and external SHA-256 receipt. P39 has **no native measurements yet**.
