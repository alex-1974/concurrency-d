# P42.8 — Conditional notification correctness gate receipt

Date: 2026-10-17. Scope: research-only source-pinned baseline versus conditional inbox publication; no production change.

## Verified GitHub Actions evidence

- Head commit: `e9c40abf8300c7591eccc057d579b4ea2d341fc6`.
- Run: https://github.com/alex-1974/concurrency-d/actions/runs/39048655599 — **completed, success**.
- DMD 2.111.0 DIP1000 job: **success**.
- LDC 1.41.0 DIP1000 job: **success**.
- Both compilers execute the P42 conditional research gate, including the baseline and conditional multi-producer consumers and the baseline/conditional concurrent-close consumers.
- Previously failing run `39047415735` failed on the original multi-producer consumer's per-record once-only assertion on both compilers. The producer-thread invocation frame was subsequently isolated; the passing gate does not conclusively prove the original failure mechanism.

## Semantics checked

- Four producers and four workers, 256 tasks per round, eight rounds, bounded inbox, full-submission retry, producer join before close; all records execute exactly once in successful rounds.
- Four producers and four workers, 16 rounds, close racing admission. Accepted records execute exactly once and total accepted/completed counts match. Closed rejections do not create execution obligations.
- Single-worker publish-after-observed-wait smoke cases remain in the gate.
- Baseline and conditional use the same consumer source with a compile-time module selection, not separate rewritten workloads.

## Qualification boundary

The green run is finite native correctness evidence, **not a proof** of starvation freedom under arbitrary producer schedules, OS condition semantics, arbitrary batch/steal interleavings or optimal notification placement. The candidate modifies the research overlay only. Close and final-completion broadcast, and local-work announcement remain unchanged. No throughput, latency, CPU cost or native XPS performance comparison has been measured for P42.8.

**Next stage: P42.9 native benchmark preparation.** Require a fair baseline/conditional pairing from the same production source pin, uninstrumented optimized LDC, identical work, task lifetimes, task counts, worker/producer configuration, warmups, rotating order, full artifact/source SHA-256 and multiple native XPS sessions. Do not draw a speedup conclusion from CI or notify-count estimates.
