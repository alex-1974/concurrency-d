# P18 — Opt-in nonprivileged Linux /proc thread scheduler observation

**Status: PROTOCOL, NOT A TRACEPOINT REPLACEMENT. No native XPS /proc observations yet.** Research-only. Production M0/P18 scheduler, TaskRef, lifetime/API, kernel security and previous artifacts unchanged.

## Rationale and link to failed perf capability

The [Dell-XPS perf preflight](xps-2026-10-14-perf-preflight-denied.md) rejected `sched:sched_switch` at tracefs on Linux 6.17.0-22, with `perf_event_paranoid=1`. No workload ran. The original `perf record -a -C` requires tracefs and CPU-wide perf permissions. Neither automatically changing kernel permissions nor quietly substituting event sources is appropriate.

This **separately opted-in** experiment observes the launched benchmark's own threads using `/proc/<pid>/task/<tid>/stat`, `status`, `schedstat`, `sched` and `comm`, with no other-user or system-wide data collection. It is a **polling approximation**, not a reconstruction of `sched_switch` or wakeup events.

## Measured quantities and precisely limited meaning

The [sampling code](../../../../tools/research/m1_p18_sched_proc_sampler.py) launches the source-pinned benchmark and periodically records:

| Read-only field | Supported interpretation | Limit |
|---|---|---|
| `schedstat` first field | per-thread accumulated CPU-running nanoseconds | only last−first within observed interval; start/end missed |
| `schedstat` second field | per-thread Runqueue-wait nanoseconds **only if kernel.sched_schedstats=1** | otherwise **UNAVAILABLE**, not zero |
| `schedstat` third field | accumulated timeslice count | only observed delta |
| `status` voluntary/nonvoluntary context switches | kernel-reported per-thread switch counters | only observed delta; not an exact event timeline |
| `stat` CPU processor field 39 | CPU on which thread was most recently scheduled at sample time | CPU changes **between** samples may be missed |
| `sched` `nr_migrations` if exported | per-thread migration counter | missing field explicitly **UNAVAILABLE** |
| `stat` starttime field 22 | lifetime identity in addition to TID | different thread epochs not merged on reused TIDs |

Main thread is identified from the launched benchmark PID; any other observed native TIDs are marked `other_thread_unverified`, **not automatically qualified as the exact D worker**. A sample interval of nominal 1 ms may miss workers that start and exit between polls. The process itself and its task scheduling are perturbed by the polling observer. Counters for newly seen threads can already have accumulated before their first sample. No per-task/wave latency, preemption chronology, exact wakeup time, IRQ interference, energy or causal lock contention can be recovered from these fields.

The [self-test and capability probe](../../../../tools/research/m1_p18_sched_proc_sampler.py) require readable Linux `/proc` paths and validate `stat` field offsets; a `kernel.sched_schedstats` value other than `1` is recorded as **no Runqueue-wait metric**. Optional `P18_PROC_REQUIRE_WAIT=1` makes the full run fail closed if the wait metric is unavailable; the script does **not** change sysctls.

## Native run (explicit selection only)

From a **new detached worktree pinned to the current reviewed research commit**:

```bash
# Read-only capability check: neither DUB nor TaskRefs run.
P18_PROC_PREFLIGHT_ONLY=1 \
    bash tools/research/m1_p18_sched_proc_xps.sh ldc2 /tmp/unused-proc-preflight

# If /proc metrics are acceptable, independently choose to run:
P18_PROC_SESSIONS=4 P18_PROC_CPUSET=0,1,2,3 \
P18_PROC_ROUNDS=24 P18_PROC_INTERVAL_MS=1 \
    bash tools/research/m1_p18_sched_proc_xps.sh ldc2 \
    /tmp/p18-sched-proc-YYYYMMDD
```

The [native collector](../../../../tools/research/m1_p18_sched_proc_xps.sh) builds source-locked unchanged M0 and the existing bounded-idle-retry P18 into **two prebuilt release binaries**, reruns both native race/close fixtures, alternates ABBA/BAAB per four sessions for `sched8` and `sched2048`. The same exact [TaskRef/checksum oracle](../../../../tools/research/m1_p18_sched_check.py) verifies two warmup and 24 measured rounds per process, plus zero Full-Retries at capacity 2048. Complete planned study: **32 processes, 384 matched measured TaskRef comparisons** and 32 warmup pairs (24×4×2×2 =384). Each observation process has a separate read-only per-thread sample CSV and JSON report.

**No automatic fallback:** the original privileged `perf` collector remains untouched. The user must **explicitly choose** this new `/proc` backend; the capability failure remains independently recorded.

## Qualification and decision boundaries

Before interpreting host data, require: reported main thread observed, at least one non-main thread epoch observed, no missing scenario rows, exact M0/P18 checksums/seed/order, plausible sample coverage and observed Thread/TID roles. **We cannot prove that every short-lived worker appeared** or that a worker has a complete CPU/schedstat delta. At `sched_schedstats=0` omit runnable wait comparisons entirely. Under no circumstances present sampled-CPU changes as the true total migrations.

Analyze only observed **lower bounds per matching profile/arm/session**. Do not treat sampling-perturbed process wall times as P18/M0 throughput evidence. The correct existing uninstrumented ABBA speed baseline is archive SHA-256 `a907752110398293825b5938de86f064dca6d81594a7cc182031f0d41840ee63`.

If the diagnostic confirms none of the needed scheduling observables, its result is **INCONCLUSIVE**. Do not infer that a positive/zero per-thread delta proves or disproves the 512-iteration regression. Future direct scheduling chronology would need a separately and explicitly approved host-level tracing path rather than making system security changes implicitly.

**Disposition unchanged: KEEP P18 narrow research / DEFER universal production**, ADR-0001 PROPOSED, #17 OPEN, PR #38 DRAFT, `source/`, `develop`, grandfathered R0.5 PR #35 untouched.
