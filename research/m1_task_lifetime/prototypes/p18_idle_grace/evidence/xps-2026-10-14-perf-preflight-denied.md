# P18 — Dell-XPS Linux perf scheduler capability blocked (2026-10-14)

**Status: negative infrastructure/capability evidence, NOT a P18 scheduler regression, and NOT a performance measurement.**

## Original user-supplied partial artifact

- File: `p18-sched-perf-20261014-161913-partial.tar.gz`.
- Original archive SHA-256: **`8231c655c8e415520998774776efe940a30e5506e467d084f8bb4fe2466fa356`**.
- Contents: one `perf-capability.txt`, `perf-preflight.stderr`, `perf-preflight.stdout`, plus empty `raw/`, `csv/`, `perf/` directories. **No native benchmark compilation or task workload was started.** No perf trace or timing evidence exists in this archive. The archive remains with the user; original host paths are not copied to public Git.
- Reported host context: Linux kernel **6.17.0-22-generic**, `perf version 7.0.14`, `perf_event_paranoid=1`, process-affinity CPU mask `0,1,2,3`.

The exact unsuccessful preflight event selector was `sched:sched_switch`. Relevant error:

```text
event syntax error: 'sched:sched_switch'
                     \___ can't access trace events

No permissions to read /sys/kernel/tracing//events/sched/sched_switch
```

This occurred inside the existing collector's explicit capability probe. The process intentionally aborted **before** builds or scheduling experiments. All existing M0/P18 source and independent uninstrumented ABBA, event-only and phase-timing XPS artifacts remain valid and unchanged.

## Why not change kernel security automatically?

There are **two distinct requirements**. The kernel's `perf_event_paranoid` policy restricts system-wide observation at value `1`. Separately, `perf` needs read access to tracepoint definitions under `/sys/kernel/tracing`. Our original `perf record -a -C` captures system-wide scheduling events on selected CPUs; even if the tracefs path became readable, the system-wide scope may remain forbidden to an unprivileged caller.

References:
- Linux kernel [Perf events and tool security](https://www.kernel.org/doc/html/latest/admin-guide/perf-security.html).
- Linux `perf list` [ACCESS RESTRICTIONS](https://man7.org/linux/man-pages/man1/perf-list.1.html).
- Linux kernel [scheduler stats](https://docs.kernel.org/scheduler/sched-stats.html).

**No `sudo`, remount of tracefs, sysctl or permanent permissions changes were attempted or are recommended by this research automation.** No silent fallback from perf to incomplete data is permitted.

## Separate explicitly opt-in, unprivileged observational alternative

The [read-only `/proc` sampling protocol](single-worker-procfs-sched-protocol.md) and dedicated [collector](../../../../tools/research/m1_p18_sched_proc_xps.sh) are an **independent experiment**, not a repair to or substitute for the denied kernel `perf` tracepoint stream.

They sample only `/proc/<launched benchmark PID>/task/<TID>/...`, without tracing unrelated processes. Available observations include per-thread `schedstat` CPU runtime, voluntary/involuntary context-switch totals, last observed CPU and (if exported) thread migration counters. **Runnable-queue waiting time is valid only when `kernel.sched_schedstats=1`.** A process can expose no waiting data at the existing default; report it as unavailable, never as zero. The sample window only yields lower bounds: it misses short-lived worker threads, events between samples and thread start/stop.

**No native /proc XPS evidence has been collected as part of this archived failure.** CI checks Python parser and experimental TaskRef provenance; the actual host observations require a fresh user-authorized XPS execution. Whether this weaker observable data suffices for any causal hypothesis is still unresolved.

**Disposition unchanged: KEEP P18 narrow research / DEFER production.** ADR-0001 remains PROPOSED; Issue #17 OPEN, PR #38 DRAFT. No production `source/`, `develop`, or grandfathered PR #35 changes.
