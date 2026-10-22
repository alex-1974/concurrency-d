# P18 — Focused 512-iteration ABBA study (2026-10-14)

**Status: research protocol / NO native results from this new protocol yet.** The task-lifetime ADR remains PROPOSED. Neither M0 nor the bounded P18 scheduler implementation is modified.

## Reason for this follow-up

The previous complete Dell-XPS long-work study found a median grace/M0 wave-time ratio of **1.0449** at 512 iterations, while 1024 and 2048 iterations were near parity. Session-to-session reversals were material. Across the 512-work group P18 generally reduced producer retry and park counts even when it lost on wave time; those counts alone do not establish causality.

This experiment uses **512 iterations as the target** and **128 and 1024 iterations as diagnostic control workloads** in the identical compiler, scheduler, ingress, worker-count and task-record setup. The outer task sizes are controls for *common process-state effects*, **not** identical-work normalization; no normalization is allowed to erase actual 512-work regressions.

## Controlled sources and measurements

- Exact unchanged production M0 source Git blob: b7d8fafcb3179f00cba7e89e28c6d6b9b676353a.
- Exact P13 TaskRef/kernel/driver blob locks and the existing P18 generated-source checks are required before benchmarking. P18 adds one bounded worker-local yield/full re-search. There are no scheduler code edits.
- Two immutable LDC whole-release binaries are built **once before timed processes**, checksummed and compared for accidental identity.
- Both arms run the existing real native close/completion/producer races before timing. A failure stops the test.
- Workload: 3 worker counts (1,2,4) × 3 ingress capacities (8,64,256) × 3 iteration counts (128,512,1024) = **27 cases**. Each case has 2,048 tasks × 3 waves, 2 warm-ups and 5 measured rounds.
- Within each session, four independent whole processes run in **A/B/B/A** order (original/P18/P18/original), reversing to **B/A/A/B** the following session. Four default sessions yield 16 process runs, 8 paired A/B comparisons and **1,080 measured paired case observations**.
- All four processes in each session use the same seed and per-round case permutation. The existing P18 exact-work comparator checks row-by-row phase/round/order/seed/worker/iteration/ingress/checksum and timing conservation.
- A hard record count checks exactly 27 × 7 = 189 scenario rows + header, including 54 warm-ups and 135 measured rows, **per process**. Unexpected rows or an incomplete run fail closed.
- Symmetric read-only thermal/sysfs samples are retained, and the process mask is pinned to 0,1,2,3 on the Dell XPS. Individual worker threads are not separately pinned. No fixed-frequency or isothermal condition is claimed.
- Performance decisions use only **uninstrumented** whole-release waves_ns and paired comparisons; producer retry and park counts are secondary scheduler-state diagnostics. No execution-time ranking of future event-instrumented copies is permitted.

## XPS invocation

From a new, detached worktree of the current research commit:

    P18_512_SESSIONS=4 P18_512_CPUSET=0,1,2,3 \
      bash tools/research/m1_p18_512_abba_xps.sh ldc2 \
      /tmp/p18-focus512-YYYYMMDD

The runner writes immutable process logs, CSV, compiler/version/binary digests, temperature/frequency traces, per-pair strict comparison reports and a checksummed TAR.GZ archive. Existing output directories and archives are not overwritten. On interruption preserve the partial directory separately; review machine/path identifiers before sharing externally.

## Interpretation and next decision

Compare medians and distributions by **512 target vs 128/1024 controls**, worker count, ingress, session, and first/second ABBA half. If a 512-specific regression survives both halves and is not explained by common-mode drift, move to separately source-pinned, **event-only** counts of local/inbox/steal/park and grace re-search paths; instrumented timings may not establish the throughput verdict.

No native data from this ABBA protocol exist yet. Existing P18 short-burst improvements and longer-task regressions remain research evidence only: **KEEP as research / DEFER general production promotion**. No P19, production scheduler, public TaskScope, develop or separate R0.5 changes.
