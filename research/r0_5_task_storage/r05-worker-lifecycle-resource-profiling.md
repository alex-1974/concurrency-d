# R0.5 — Worker/producer resource attribution at thread lifecycle boundaries

**Research-only / CI qualified:** version-gated worker-resource samples at
worker thread **entry and exit**, no Task-dispatch/queue/inbox/admission
stopwatch. All worker snapshots become readable only after the worker
join. No native Dell XPS result from this new probe has been supplied
yet; hosted correctness smoke is not a performance gate.

Grandfathered [Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
and [Issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
Background: [native XPS shared-versus-striped report](results/xps-counter-contention-review-2026-10-12.md),
which found that splitting the benchmark's execution counter by
**originating producer** did not remove strong negative scaling of
1/4/8 producer throughput.

## Goal and scope

The research scheduler's unchanged full-victim mixed-type workload
shows substantial **whole-process** voluntary context switching and
CPU time increases at higher producer count. Producer-thread resource
snapshots already exist in
`benchmarks/task_pipeline/thread_resource.d`; however the
`wait4()` total minus producers is **not** a clean worker-only
measurement because process main/GC/runtime threads also contribute.

Add **worker-local, Linux RUSAGE_THREAD** counters at thread boundaries,
then distinguish:

- Producer thread CPU and voluntary/involuntary context switches (existing);
- Four worker threads' independent CPU and context-switch counts
  (new versioned research snapshots);
- Whole-child Linux `wait4` CPU and context switches (existing);
- Other-process residual = whole child - producer - worker,
  **not equivalent** to precise main thread or precise GC CPU;
- Task progress and throughput in a **separately compiled
  uninstrumented control**, with identical workload, task ownership,
  backpressure and wake-generation semantics.

## Implementation boundaries and safety

Source:
- `source/concurrency/internal/worker_thread_resource.d`
  contains a **versioned Linux-only** helper using
  `getrusage(1, &rusage)` for the GNU `RUSAGE_THREAD`
  extension. It defines `WorkerThreadResource` as a
  research-only package-visible struct with user/system CPU µs,
  voluntary/involuntary switches, minor/major faults, and
  `sampled` marker. The existing benchmark module independently
  samples producers via the same Linux facility.
- Under `R05WorkerThreadResources` only,
  `SubmissionWorkerPool.makeWorker()` takes
  `sampleWorkerThreadResource()` **immediately before**
  `workerLoop(workerIndex)`, and again after it returns;
  stores one delta in its worker-exclusive slot.
  No counters are updated per task, stolen task, inbox submission,
  condition wait, or worker loop iteration.
- Slots are allocated before worker threads start; only each worker
  writes its own slot, only once, after its loop. The controlling
  thread accesses a copied snapshot **after closeAndJoin()**
  under the existing `OwnedTaskExecutor` lifecycle lock.
  Attempting that accessor before `Lifecycle.stopped` throws.
- The existing strong GC roots, `TaskRef` borrow lifetime,
  close/join ordering, bounded rejection-before-allocation,
  wake-generation predicate, worker search/deque traversal,
  TaskHandle completion and `NotificationPolicy.always`
  remain **unchanged**.
- The new worker measurement includes almost the entire worker
  loop lifetime but excludes startup between OS-thread creation
  and the first sample, and work after its final sample.
  The snapshots have microsecond resolution and add two
  system calls at worker lifecycle boundaries only.
  They are **not** a causal trace of individual lock waits,
  futex operations or condition wake-to-run latency.
  On exceptional worker termination without normal loop return,
  a complete sample is not guaranteed; research benchmark
  rejects missing `sampled` worker slots.

DUB configurations:
- `task-pipeline-mixed-full-victim-sweep`: **OFF**,
  original optimized full-victim baseline, no new counters;
- `task-pipeline-mixed-full-victim-worker-resource`: **WORKER**,
  same full victim search, plus
  `R05WorkerThreadResources`, no hot-path Admission/Inbox/Parking
  probe.

**Do not call these executables codegen-identical:** They have
different compile-time versions, even though the actual queue,
storage, task and scheduler decisions are unchanged. Paired ON/OFF
throughput is a measurement-perturbation check, not speedup.

## Reproducibility on the native Dell XPS

Use the existing local checkout. Inspect/safeguard unrelated
tracked and untracked work before branch checkout; no other
workspace repository should be edited.

```bash
cd ~/Programmiersprachen/dlang/concurrency-d
git status --short --branch
git fetch origin
git switch perf/r05-owned-task-pipeline
git pull --ff-only origin perf/r05-owned-task-pipeline

python3 tools/research/r05_worker_resource_matrix.py \
  --compiler=ldc2 --workers=4 --tasks=30000 --rounds=5 \
  --producers 1 4 8 --budget=512 \
  --policies gc recycle --workloads minimal compute \
  --counter=shared --cooldown-ms=50 \
  --output=evidence/r05-xps-worker-resources

tar -czf r05-xps-worker-resources.tar.gz \
  -C evidence r05-xps-worker-resources
```

**Matrix:** 5 rounds × 2 workload families × 3 producer counts ×
2 storage policies × 2 resource-profiling modes
= **120 independent child processes, 30,000 completed Tasks each,
3.6 million Tasks**. Of these, **60** carry four independent worker
snapshots (**240 per-worker CSV rows**); the other 60 are uninstrumented
original control processes. Each has four workers, the same
full-victim scheduler, retained TaskRef/GC-root semantics,
`NotificationPolicy.always`, no task/parking/admission/inbox
stopwatch, and a shared execution counter for direct context with
the earlier uninstrumented native run. The previous 10-round
`shared/striped` experiment did not show a general win for
producer stripes and does not need to be repeated here.

The driver (only on Linux) records and checks per-process:
`raw.csv` 120 rows, `worker.csv` 240, `pairs.csv` 60
paired worker-profile/off observations, `summary.csv` 12
five-round factor summaries, `producer_scaling.csv` 80 within-round
4/1 and 8/1 producer throughput ratios (when 1 is selected),
plus `environment.txt` source SHA, both executable hashes,
toolchain and governor snapshot.

The scaling file contains 5 rounds × 2 workloads × 2 policies
× 2 modes × 2 non-single producer counts = **80 rows**.

Every benchmark process performs D release-runtime
accepted/executed/completed checks, typed results, GC-visible
wide callable handling and deterministic compute checksum.
The Python runner also checks each worker's indexed record,
its `sampled` marker, exact total worker count,
matching result checksum across modes, and child/producers
resource-field sanity.

Run on AC power and avoid competing large workloads if possible.
The `powersave` governor and a one-time `lscpu` frequency
snapshot **do not** establish stable clocks; no affinity or
privilege changes are made. No perf hardware counter or kernel
trace is required (previous XPS perf preflight was refused
with `perf_event_paranoid=4`).

## What can be concluded

The pair supports descriptive questions: do workers,
producers or *both* show higher CPU/resource-switch usage
as the producer count rises? Does worker CPU or switching
load vary strongly across worker indices? Does one worker
consume disproportionate CPU relative to the others?
Is the profile-on process observation visibly different
from the ordinary uninstrumented control?

Worker resource totals can be compared on their own across
factor groups and normalized per accepted Task.
**Do not attribute** worker voluntary switches directly to
`Condition.wait`, GC pauses, yielding or steal traffic:
RUSAGE_THREAD does not expose those causes. The residual
whole-child minus producer minus worker also includes
unobserved runtime activity and may have small signed
differences due to precision and different start/end
windows; never rewrite a negative residual to zero.
Per-worker CPU and voluntary switches measure lifetime
deltas, not a sampled distribution of one Task's latency.

**Decision gate:** Source identification, complete invariants,
separately compiled uninstrumented throughput controls,
repeated Dell XPS LDC evidence. If worker CPU/switches dominate
the *incremental* resource cost, prioritize narrow worker
parking/steal/notification evidence without weakening wakeup
safety; if producer CPU/switches dominate, examine the
outer admission serialization and its precise lifetime
guarantees first. If mixed, no unilateral lock redesign.
Any optimization would still require matched uninstrumented
task results, throughput, shutdown/GC-root/lifetime tests,
DMD correctness and LDC x86 native performance.

## CI qualification

[GitHub Actions #38306174396](https://github.com/alex-1974/concurrency-d/actions/runs/38306174396)
**PASS** on DMD 2.111 x86-64, LDC 1.41 x86-64 and
native LDC 1.41 ARM64. The source smoke runs 16 small
child workloads (both storage policies, minimal/compute,
1/4 producers, both modes), expects 32 valid indexed
worker records, checks deterministic checksums and all
completed tasks, worker versus producer data presence,
distinct mode binary hashes, and separate scaling pairs.
No hosted throughput or memory value is an acceptance gate.

Grandfathered PR #35 remains Draft; Issue #20 OPEN.
No promotion or broad merge to `develop`; no other
workspace repository changes.
