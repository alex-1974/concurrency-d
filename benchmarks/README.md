# Benchmarks

Performance qualification will include, where applicable:

- task throughput;
- task scheduling latency;
- local push/pop cost;
- steal cost;
- contested steal cost;
- scaling across worker counts;
- wake-up P50/P95/P99 latency;
- idle CPU usage;
- allocation count and cost;
- cache misses;
- retired instructions;
- context switches.

Reference comparisons must perform materially equivalent work.

Current repository commands (benchmarks are excluded from the library archive):

```sh
dub run --root=benchmarks/parking --compiler=ldc2 --build=release -- 2 64
dub run --root=benchmarks/executor --compiler=ldc2 --build=release -- public 4 4 1024
dub run --root=benchmarks/storage --compiler=ldc2 --build=release -- 2048 2 3 5 2
dub run --root=benchmarks/owned-storage --compiler=ldc2 --build=release -- 2048 2 5
dub run --root=benchmarks/scopes --compiler=ldc2 --build=release -- 256 4 128 9 3
dub run --root=benchmarks/fork-join --compiler=ldc2 --build=release -- 256 4 128 9 3
```

The parking diagnostic measures isolated publish-to-start latency after a 2 ms
idle interval and process CPU use during a 300 ms no-work window. It verifies
accepted/completed accounting but has no fixed latency threshold on shared CI.
Sustained matched evidence for the conditional publish policy and the resulting
decision are summarized in
[ADR-0003](../docs/adr/0003-coalesce-idle-publish-notifications.md).

The scopes diagnostic alternates paired `TaskScope` and explicit `submit +
get` runs over the same deterministic tasks and verifies every pair's
checksum. Each arm uses a fresh executor; worker startup and handle-array
allocation are outside the clock, while submission, result reads, and
`closeAndJoin` are timed. Scope bookkeeping allocation and its post-dispatch
join are part of the measured scope cost. This is a local diagnostic, not a
performance gate or a comparison to a different scheduler such as Rayon.

The fork-join diagnostic compares sequential pairs of identical callables using
the two-way `Executor.join`, a two-child `TaskScope`, and explicit `submit +
get`. All three loops run inside one driver task, so they use the same worker
budget; at least two workers are required because ordinary `TaskHandle.get()`
does not help. It rotates all three execution orders and verifies checksums.
Executor startup is outside the clock; driver submission, pair execution and
shutdown are timed. The explicit-submit arm observes result readiness per pair
and obtains the final post-dispatch fence at shutdown, while both structured
arms fence each pair. This semantic distinction is reported rather than hidden,
and timings remain diagnostic rather than a release threshold.

The storage diagnostic compares identical `TaskRef` records and work using a
reused caller-stack array, a fresh GC array each wave, and one reused GC array.
Every wave waits on the post-dispatch return marker before record reuse. It does
not measure the public generic owned-task nodes, and its timing is not a release
threshold or a general storage decision.

The owned-storage diagnostic complements that raw-record comparison with the
public `Executor` path. It reports phase timings, producer-thread allocation
and observational GC used-byte before/after values for tiny value captures, 512-byte inline
contexts and transitive GC-reference graphs. A separate blocked-worker arm
drops every measured handle before collection, so the executor is responsible
for retaining all queued nodes and graphs. Collector byte counts are not pass
thresholds. See [ADR-0005](../docs/adr/0005-keep-gc-owned-task-records.md) for
the resulting storage disposition and its limits.
