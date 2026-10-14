# P18 — complete native Dell-XPS single-worker `/proc` observation audit (2026-10-14)

**Disposition: KEEP narrow P18 research / DEFER unconditional production.** The optional read-only per-thread `/proc` polling experiment completed correctly, but **does not qualify CPU Runqueue-wait or a causal scheduler explanation**. These traces and their process `waves_ns` are observer-perturbed, **not** the original uninstrumented speed benchmark.

## Archive, exact source and correctness

- Original user-provided `p18-sched-proc-20261014-203525.tar.gz`, SHA-256 **`efdd7b82191604d4f28436ec97437fc3b7963aabe282dc7e07e08aee85905144`**. Original archive stays outside public Git: it contains process/TID/host metadata. Only aggregated results are published.
- Source-pinned research commit **`4a0fd540c38a53ab5d81a31f0d2afa84dd8742b7`**; unchanged original production M0 pool Git blob **`b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`**; LDC 1.41.0 / LLVM 19.1.7 whole release and DUB 1.40.0, Dell XPS 15 i7-9750H, Linux 6.17.0-22-generic. Process CPU affinity 0–3; producer/worker not individually pinned. Distinct compiled binary SHA-256: M0 `e3ede1cf0d635acbd575ddfaf52c2971aadff2c7e7a8374270bda349a7cea2bf`, P18 `0a93702e795f7f0cc42ee1159078d17e12dbe9189132afa4cf8c757767ad28dd`.
- Native close/complete/park/producer-race preflights **PASS 324 scenarios per arm**. **32/32** completed and JSON-serialized whole processes: four sessions, each profile `sched8` / `sched2048`, alternating source-locked original-M0/P18/P18/M0 or reverse with two per-arm runs. Exactly 1 worker, **512 iterations, 2048 TaskRefs/wave × 3 waves**, two warmups + **24 measured rounds** in each process.
- Independent original raw stdout-to-normalized-CSV comparison **PASS all 32**, 832 process-case rows total. Seed, order/phase, fixed task identities/checksum (`13257374174144`), nonnegative counters and exact timing-stage conservation **PASS**. **384/384 matched measured** and **32/32 matched warm-up** TaskRef comparisons pass. Ingress 2048 has **zero full-inbox retries** in every row. All 32 observer JSON reports are present, have successful child exit, observe main and non-main threads and match sample counts/unique (TID,starttime) epochs.

## Limitations of the actually collected scheduler observables

- All **32/32** capability reports explicitly show **`kernel.sched_schedstats=0`**, `runnable_wait_time_available=false`. Thus the Runqueue-wait field is **UNAVAILABLE, NOT ZERO**; the experiment **cannot test whether P18 causes the producer to remain runnable but delayed**. The earlier privileged Linux `perf sched_switch` preflight separately failed on tracefs permissions. No kernel security settings were changed.
- **19,255** per-thread polling samples across 32 processes; **533–634** observations per process, nominal 1 ms. **1,153** observed non-main thread epochs (TID/starttime), **315 seen only once** (no time delta possible), and **504 dropped/disappearing task reads**. The number of observed thread epochs is **not** the number of concurrently running workers: short-lived successive pools/tasks create new epochs and their identity as D pool workers was **not verified**.
- Main-thread CPU time, context switches and kernel-reported migrations are **only first-to-last observed-window deltas**. Non-main thread CPU sums combine independently incomplete windows of unverified threads, so do not call them total worker CPU time. Timestamp/non-atomic `/proc` polling perturbs scheduling and can miss thread start/exit and migrations between samples. **21** sample rows have last-CPU numbers outside CPUs 0–3; these are not sufficient evidence of execution outside the established affinity (possible startup/handoff or non-atomic sample windows).
- Only one sparse package-temperature observation before and after each process: **49–73°C** recorded, below the documented 95°C research observation alert. No complete thermal-throttle, constant per-thread clock, watt/joule or energy qualification.

## Matched observed process-level differences (diagnostic ONLY)

`P18 − M0`, **median of 8 directly matched process differences per profile** (four host sessions × two halves). This is not a new throughput/speed comparison or instruction-time attribution.

| Observed sampled metric | Ingress 8 | Ingress 2048 |
|---|---:|---:|
| Main producer observed CPU-runtime delta | **−23.49 ms** | **+4.38 ms** |
| Main producer observed interval span delta | −21.60 ms | +4.44 ms |
| Main voluntary context switches delta | −4 | −1 |
| Main involuntary context switches delta | −2.5 | +0.5 |
| Main migration counter delta | +0.5 | −1 |
| Observed last-CPU switches delta | +0.5 | −1 |
| Sum of observed non-main CPU-runtime deltas | +2.25 ms | +4.34 ms |

**High session sensitivity and sign changes** preclude causal claims: the eight direct process-pair producer CPU-runtime differences span **−83.26…+32.41 ms at ingress 8**, and **−20.26…+29.76 ms at ingress 2048**. Median per-session paired differences at ingress 8 are **−0.73, −15.56, −10.83, −77.63 ms**; at ingress 2048 **−0.46, +11.53, +4.75, +4.71 ms**. Paired context-switch/migration differences also change direction. The polling-perturbed process timings can reverse the direction of the earlier uninstrumented throughput result; they must never be substituted for it.

The **actual speed qualification** remains the *separate uninstrumented 480-pair ABBA XPS* archive SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`, 512-work P18/M0 paired wave-time medians **1.0627 / 1.0392 / 1.0539 / 0.9875** at ingress 8/64/256/2048. The different phase-stamped corpus identified an admission-phase delay but did not establish CPU Runqueue-wait or cache/lock/yield causality.

## Conclusion

**PASS experimental completeness and native correctness; QUALIFIED incomplete CPU-/context-switch observations; NOT QUALIFIED Runqueue-delay mechanism or energy/scheduler speed.** Do not repeat this same polling protocol automatically: the missing `sched_schedstats` and unstable/partial thread coverage mean further unchanged repetitions have limited expected value. Any privileged system-wide tracing route needs separate explicit user authorization rather than modifying kernel settings implicitly. A new candidate still requires fresh exact-source uninstrumented LDC A/B/B/A plus native lifetime and race qualification.

**KEEP P18 narrow research / DEFER general production.** ADR-0001 PROPOSED; Issue #17 OPEN, Draft PR #38, `source/`, `develop`, grandfathered R0.5 PR #35 and historical archive provenance unchanged.
