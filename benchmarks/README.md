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

The short-task diagnostic compares a serial loop and the single-participant
`parallelFor` path with parallel range claims, independent `submit` calls,
atomic `submitBatch` calls and synchronous `submitBatchAndWait` calls. Submit
arms report producer/admission and handle-wait time separately, plus total
dispatch-to-completion time; with multiple producers the submission phase
includes producer-thread startup and join. For `submitBatchAndWait`, submit
time includes completion because the API returns only after the group drains.
Tasks may execute while admission is still in progress, so phase timings are
not additive. The executor, handle storage and result buffer are reused across
samples, and every arm checks the same checksum. This benchmark locates
scheduler costs; it has no pass threshold.

```sh
dub build --root=benchmarks/short-tasks --build=release --compiler=ldc2
./benchmarks/short-tasks/concurrency-short-tasks-benchmark 30 5 1024 4 > short-tasks.csv
```

The required arguments are measured samples, warmups, item count and worker
count. An optional fifth argument sets producer count; alternatively, ingress
capacity and retained-record budget can be set before producer count. For
example, this uses four producers with the executor defaults:

```sh
./benchmarks/short-tasks/concurrency-short-tasks-benchmark 20 3 16384 4 4 > short-tasks-4p.csv
```

This command raises both capacities to 16,384 for an unconstrained diagnostic:

```sh
./benchmarks/short-tasks/concurrency-short-tasks-benchmark 30 5 16384 4 16384 16384 > short-tasks-unbounded.csv
```

Run separate item counts because scheduling cost changes relative to callback
work. In a local XPS 15 / LDC 1.42 run, 1,024 tiny stores took a median
1.3 μs serially or inline, versus 13–34 μs for parallel range claims. At
16,384 stores, grain 256 took 24.4 μs versus 26.7 μs serially. Submitting one
task per item took about 1.14 ms and 26.5 ms, respectively. Atomic batches
reduced those totals to 586 μs and 11.2 ms at batch size 1, and to 13.4 μs and
73.3 μs at batch size 256. The submit phase shrank while the wait phase grew
because workers received tasks sooner; compare total time for end-to-end
results. These are host-specific diagnostic measurements; repeat them on
native ARM64 and across process sessions before changing scheduler policy.

At four producers with the practical queue 256 / retention 512 limits, atomic
batches of 16 logical tasks reduced median total time from 3.23 ms to 0.97 ms;
batches of 64 reduced it from 0.87 ms to 0.35 ms. Thread startup is included
for both the single-submit and batch arms in this multi-producer comparison.

An isolation sweep at 16,384 items compared default capacities (ingress 256,
retention 512) with each limit raised to 16,384. For one task per item, median
submission remained about 19–22 ms in every configuration. Raising either
limit did not yield a repeatable improvement, so retention scans and ingress
backpressure alone do not explain the per-task cost. The `submitBatch` arms
compare atomic single-record and multi-record admissions under identical task
work. The API rejects batches that cannot fit configured capacities and waits
only when occupancy is temporary.

The existing public-executor producer diagnostic also shows serialization:
for 8,192 one-iteration tasks, five local runs had median total times of 11.6
ms with one producer and 25.0 ms with four. That harness includes executor and
producer-thread startup, so it is directional rather than an isolated lock
measurement. A follow-up dedicated comparison used three independent LDC 1.42
processes, each with 20 measured samples after four warmups, 16,384 one-store
items and four workers. At one producer and ingress/retention capacities of
16,384, the pooled 60 observations gave median total times of 1.01 ms vs 488
μs at grain 16, 234 μs vs 153 μs at grain 64, and 70 μs vs 56 μs at grain 256
for repeated `submit` vs `submitBatch`. At four producers with queue and
retention limits 256 / 512, medians were 2.45 ms vs 837 μs at grain 16, 729
μs vs 287 μs at grain 64, and 290 μs vs 178 μs at grain 256. In the same
workload, synchronous `submitBatchAndWait` medians were 308 μs, 96 μs and
38 μs at one producer for grains 16, 64 and 256; at four producers they were
628 μs, 251 μs and 182 μs. The batch-wait arm is useful when the caller needs
group completion before continuing; its `submit_ns` includes task completion.
It reduced measured producer allocation per logical item versus async
`submitBatch` by about 37% at one producer and 30% at four producers for grain
16. Compared with repeated `submit`, allocation bytes were lower for one
producer at grains 16–256 and for four producers at grain 64; its per-group
arrays can outweigh the avoided handle allocations at other settings.
Producer-thread
startup and join are included symmetrically. Batch-of-one is omitted for four
producers because each producer's complete group cannot fit the configured
capacities. These host-specific diagnostics show repeatable gains for this
workload, not portable promises; measure representative task durations on the
target host before choosing a batch size.

The asynchronous submission path originally allocated three GC objects per
accepted task: a result cell, an owned task node and a typed handle. The result
cell is now the base of the owned node, preserving the same typed handle and
task lifetime while removing one object allocation per task. The task record
and handle remain individual allocations for asynchronous APIs. The
`submitBatchAndWait` path instead shares one completion cell across the batch,
creates no per-task handles, and stores multi-item task records in one
executor-rooted GC array. A one-item batch keeps its record inline in the owner
object to avoid a second allocation. Each retained-task root keeps that owner
alive through the dispatch-return marker, preserving record address stability.
In an alternating four-process LDC 1.42 A/B on the XPS (16,384 one-store tasks,
four workers, 60 observations per arm), batch-wait medians improved about
18%, 8% and 10% at grains 16, 64 and 256 with four producers; one-producer
results were about 6% faster at grain 16, 3% at grain 64 and effectively tied
at grain 256. Producer allocation bytes varied by arm, so these timings do not
support a general allocation-byte reduction claim. They are host-specific
diagnostics, not portable promises. The benchmark's `producer_allocated_bytes`
column reads D's current-thread GC allocation counter in each producer and
sums the values. For asynchronous `submit` and `submitBatch`, it covers
admission and handle creation, excluding handle waits and producer-thread
startup. For `submitBatchAndWait`, it spans the full call, including task
completion; producer-thread startup remains excluded.

The synchronous batch-storage A/B has a separate native ARM64 workflow. It
builds the same focused benchmark against the parent of the contiguous-storage
change and the checked-out candidate, then alternates their process order over
four independent sessions. It measures 16,384 one-store items with one and
four producers, four executor workers, and batch grains 16, 64 and 256. The
four-producer case uses ingress/retention limits 256/512, so each producer's
batch fits while concurrent groups can exercise real backpressure. It records
raw per-process CSV, compiler and host metadata, paired sample ratios, checksums,
and p50/p95 summaries. The workflow runs on relevant pull requests and can be
started manually. It has no timing threshold: interpret the ARM64 capture
alongside the local XPS measurements and keep all raw rows with any conclusion.
In a five-sample, two-warmup one-producer capture with 16,384 items, repeated
single-task submission allocated a median 176.5 bytes/item before and 160.5
after the change. Batch-of-one allocated 241.5 vs 225.5 bytes/item, including
the batch API's temporary arrays. The exact 16-byte/item reduction confirms
the removed cell allocation. Because allocation-counter reads add a little
measurement work, use separate captures without allocation accounting when
comparing very small latency differences.

A follow-up experiment skipped creation of the unused cancellation state in
internal `parallelFor` scopes. Three alternating baseline/candidate sessions
with 50 measured samples each showed no consistent reduction: at 1,024 items,
parallel range arms were 2–5% slower in the candidate; at 16,384 items, the
grain-64 arm was 3% faster while grain 256 was unchanged. The experiment was
discarded. This comparison points away from that allocation and keeps task
submission/record creation as the stronger optimization target.

The focused adaptive-range diagnostic compares only fixed and adaptive
`parallelFor` over short (16 iterations), medium (256), long (4096), scattered
hotspots, and expensive items clustered at the beginning or end. The hotspot
profiles keep the same cost distribution and move the expensive one-eighth of
items to test sensitivity to their position. It covers 1,024- and 16,384-item
domains, eight reused-executor waves, and 1, 2 and 4 workers across six
minimum/fixed grain sizes. Each pair checks the same checksum. This isolates
how well a small adaptive minimum handles unknown and clustered costs; it does
not establish a universal best grain. In one XPS/LDC 1.42 capture, the 16,384
short-uniform, four-worker, grain-1 adaptive run took 818 μs versus 4.76 ms
for fixed grain 1 across eight waves. Fixed grain 1 claims every index through
one shared atomic cursor, while adaptive grain 1 distributes cyclic blocks
across worker-local claim cursors. This result motivates choosing adaptive
scheduling for that measured workload; it is not a general speedup guarantee.

```sh
dub build --root=benchmarks/adaptive-ranges --build=release --compiler=ldc2
./benchmarks/adaptive-ranges/concurrency-adaptive-ranges-benchmark 20 5 > adaptive-ranges.csv
python3 tools/validation/summarize_m2_benchmark.py adaptive-ranges.csv
```

The `Split-on-steal native ARM64 qualification` workflow compares the checked
out scheduler against the pinned v0.3.0 source using the same checksum-checked
benchmark. It focuses on four participants, fine adaptive work (`minGrainSize`
1), 1,024 and 16,384 items, uniform and clustered-cost callbacks, and eight
waves per timed invocation. Each process reuses one executor, one Phobos pool,
and one output buffer per workload across warmups and measured samples, so the
timed path excludes pool construction and buffer allocation. Four sessions
alternate baseline/candidate process order; the artifact contains raw CSV,
host/compiler metadata, and per-workload p50/p95 ratios. The 10% p95 flag is a
review screen, not a CI pass/fail threshold.
The comparison sweeps grain and batch sizes 1, 4, 16, 64, 256, 512 and 1,024,
and includes serial-loop, `parallelFor`-inline and `WorkSize` controls to expose
the break-even point for parallel scheduling.
Locally, build and smoke-test the harness with:

```sh
dub build --root=benchmarks/split-on-steal --compiler=ldc2 --build=release
./benchmarks/split-on-steal/concurrency-split-on-steal-benchmark 12 3 > split-on-steal.csv
```

The harness is only a measurement tool. It does not by itself qualify the
scheduler for release; interpret the ARM64 captures alongside x86_64 paired
measurements and the correctness gates.

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
