# P42.7 CI failure triage — 2026-10-17

Run 39047415735 fails on both DMD 2.111.0 and LDC 1.41.0 in the new P42 multi-producer consumer, after P42 single-worker wait-publish passes. The new consumer creates producer thread closures inside a foreach and captures loop-derived start/finish variables. D closure capture lifetime/iteration-frame aliasing is a credible **test-harness hypothesis**, not an established root cause.

Qualification remains blocked: independently compare identical consumer workloads against unchanged original pool and conditional overlay; ensure separate producer invocation frames; report first failing task index and observed hits; preserve the raw failing run; rerun DMD/LDC before proceeding to performance. Do not change production code or call the coalescing policy correct while this is unresolved.
