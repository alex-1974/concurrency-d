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
dub run --root=benchmarks/end-to-end --compiler=dmd -- 4 5 2 1024
dub run --root=benchmarks/end-to-end --compiler=ldc2 --build=release -- 4 20 5 1024
dub run --root=benchmarks/streaming --compiler=ldc2 --build=release -- 4 4 32 4096 256 1 20 5
```

The end-to-end diagnostic runs checksum-identical fine, medium, coarse and
deterministically irregular chunk workloads through sequential D, Phobos
`TaskPool.parallel`, per-batch `Executor.submit`, `Executor.parallelFor` and
`Executor.parallelForAdaptive`.
It also includes benchmark-only manual dynamic worker loops (`dynamicFor` and
`dynamicForReused`) that share the caller-plus-workers budget, and paired
`phobosReused`, `parallelForReused` and `parallelForAdaptiveReused` arms that
keep their pool alive across eight work waves. The manual reused arm waits for post-dispatch return and
reclaims completed records before the next wave, matching the scope join fence.
The reused arms report total chunks across all waves, so
their per-chunk time and throughput account for the repeated work. Pool or
executor construction and final shutdown are timed once per eight waves.
The worker argument is the maximum worker count; it runs 1, 2, 4, ... and the
maximum (once) to expose scaling. For each worker count it sweeps logical chunk
batch sizes 1, 4, 8, 16, 32, 64, 128, 256 and 512. The submit arm creates one
task per fixed batch; `parallelFor`
participates on the caller and starts up to one fewer worker task than the
executor worker count; all participants atomically claim ranges of the selected
grain size. `parallelForAdaptive` uses guided claims whose size starts larger
while much work remains and shrinks toward the selected minimum grain. The
manual `dynamicFor` arm applies fixed caller participation and range claims
with explicit worker submissions. Phobos uses the grain as
`workUnitSize`. This compares fixed batching and dynamic range assignment under
the same logical work. It rotates arm order and emits raw CSV rows for submitted
task count, elapsed time, ns/chunk and throughput. Pool/executor startup,
result collection and shutdown are inside each timed arm. The Phobos pool has
`workers - 1` background threads because its caller participates while waiting;
this matches the executor's `workers` threads. The harness is deliberately a
diagnostic with no pass ratio: short smoke runs are sensitive to scheduling,
GC and CPU frequency. Use a larger base-iteration value when chunk work is
short, retain raw output, and record compiler version, exact command, CPU,
kernel and power/thermal conditions with any published result. It currently
compares against the actual Phobos implementation available in the D toolchain.
The independently buildable and checksum-matched
[Taskflow/oneTBB/Rayon reference](cross-language/README.md) uses the same
workload definitions and explicit worker budgets. It remains diagnostic; a
release conclusion must cite repeated raw captures, distinguish the libraries'
different grain policies, and include native ARM64 evidence. Pull requests to
`develop` or `main` that touch these benchmarks automatically capture optimized
native ARM64/LDC runs; the same workflow can be started manually with custom
parameters. It stores independent sessions and host/compiler metadata as an
artifact in `.github/workflows/m2-performance-capture.yml`.

The focused adaptive-range diagnostic compares only fixed and adaptive
`parallelFor` over short (16 iterations), medium (256), long (4096), scattered
hotspots, and expensive items clustered at the beginning or end. The hotspot
profiles keep the same cost distribution and move the expensive one-eighth of
items to test sensitivity to their position. It holds the 1,024-item domain
and eight reused-executor waves constant, and sweeps 1, 2 and 4 workers and six
minimum/fixed grain sizes. Each pair checks the same checksum. This isolates
how well a small adaptive minimum handles unknown and clustered costs; it does
not establish a universal best grain.

```sh
dub build --root=benchmarks/adaptive-ranges --build=release --compiler=ldc2
./benchmarks/adaptive-ranges/concurrency-adaptive-ranges-benchmark 20 5 > adaptive-ranges.csv
python3 tools/validation/summarize_m2_benchmark.py adaptive-ranges.csv
```

For repeated sessions, add a `session` column to each run before concatenating
the CSVs. Compare adaptive and fixed arms at the same grain to see the value of
adaptation, and compare each arm's best grain to understand the result after
manual tuning.

For clean raw CSV capture, build first and invoke the executable directly so
Dub's build messages do not appear in the data file:

```sh
dub build --root=benchmarks/end-to-end --build=release --compiler=ldc2
./benchmarks/end-to-end/concurrency-end-to-end-benchmark 4 20 5 1024 > end-to-end.csv
python3 tools/validation/summarize_m2_benchmark.py end-to-end.csv
```

When combining repeated process runs, add a `session` column to each raw CSV
row before concatenation; the summarizer uses it when pairing sample indices.

The streaming comparison exercises a finite, sustained multi-producer stream.
Each producer keeps a fixed window of outstanding tasks and consumes the oldest
result before admitting more, so total in-flight work is bounded identically in
both arms. `Executor` receives the same bound for ingress and uses its default
4096-record retention budget; the Phobos producer windows bound its otherwise
unbounded `TaskPool` queue. Both arms use the same workers, producers, task
IDs, CPU kernel, result checksums and drain-on-stop behavior. Pool construction
is included in total time, while the producer and shutdown phases are reported
separately. Task admission time,
producer time waiting for results, task residence latency (submission to
consumption), empty shutdown, and a separate full-capacity shutdown-drain test
are reported. The benchmark does not claim that Phobos itself provides bounded
admission; the producer window is the matching adapter. No timing threshold is
used in CI.

Phobos' `Task.yieldForce` can execute a task on the calling producer if the
pool has not started it yet. The streaming adapter signals when each specific
task enters its pool worker and calls `yieldForce` only after that task's signal,
so producer threads do not add compute capacity to that arm. The start signal adds a small
adapter cost to Phobos task execution; it is retained to keep the worker budget
matched and should be considered when interpreting these diagnostic timings.

```sh
dub build --root=benchmarks/streaming --build=release --compiler=ldc2
./benchmarks/streaming/concurrency-streaming-benchmark 4 4 32 4096 256 1 20 5 > streaming.csv
python3 tools/validation/summarize_streaming_benchmark.py streaming.csv
```

The arguments are workers, producers, total in-flight capacity, logical tasks,
iterations per logical task, logical items per submitted task, measured samples
and warmups; an optional final `small`, `large` or `compare` argument selects the public
`WorkSize` passed for executor submissions (Phobos ignores that executor-
specific hint). Capacity and logical task count must divide evenly across
producers and batches. Increase batch size to test whether user-level batching
amortizes the scheduler overhead for small tasks; both arms still execute the
same logical items and return the same checksum. Repeat the process under recorded CPU, kernel,
compiler and thermal conditions; add a `session` column to paired CSV captures
before combining them.

Compare the two work sizes while holding every other argument fixed:

```sh
./benchmarks/streaming/concurrency-streaming-benchmark 4 4 16 1024 4096 1 20 5 compare > streaming-hints.csv
python3 tools/validation/summarize_streaming_benchmark.py streaming-hints.csv
```

`compare` runs both hints in the same process and rotates their order across
samples; the summary reports a separate paired ratio for each hint.

The hint changes only inbox claim batching. It is useful to test when long
tasks are already independently submitted; it cannot divide one large opaque
callable. For tiny items, compare batching first because reducing the number of
submitted tasks removes more scheduler work than a work size can.

In one local LDC 1.42 / Dell XPS 15 diagnostic (4 workers, 4 producers, 64
in-flight entries, 1,024 tasks of 8,192 iterations, 20 measured pairs), median
Executor producer time was 2.88 ms with `small` and 2.36 ms with `large`.
With 256 iterations and capacity 16, the corresponding medians were 22.12 ms
and 22.47 ms. These short host-specific runs show why the hint is opt-in; they
are diagnostic evidence, not a general speedup claim or CI threshold.

To see the effect of batching, keep the logical workload fixed and vary only
the sixth argument (items per submitted task):

```sh
for batch in 1 4 16 64 128 256; do
  ./benchmarks/streaming/concurrency-streaming-benchmark 4 4 32 4096 256 "$batch" 20 5 > "streaming-b${batch}.csv"
  python3 tools/validation/summarize_streaming_benchmark.py "streaming-b${batch}.csv"
done
```

Then hold the batch size fixed and vary workers, producers or capacity in
separate sweeps. Capacity must divide evenly across producers, and the logical
task count must divide evenly across producers and batches. This benchmark
accepts a capacity argument but uses the executor's default `maxRetained`;
measure a different retention budget with a representative application if that
limit is the suspected bottleneck. Use the summaries to inspect producer
blocking, throughput and residence latency together: the largest throughput
number alone may not meet the application's latency target.

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
