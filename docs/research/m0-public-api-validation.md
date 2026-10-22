# M0 public executor candidate — implementation and qualification

Date: 2026-10-22. Status: **API candidate, not a stable published release**.
Dependency: lifecycle code commit `0f4167cf7ccf0e98fcafd1c091e9de3e346b66da`
([Draft PR #40](https://github.com/alex-1974/concurrency-d/pull/40)).
Tracking: [typed submission #11](https://github.com/alex-1974/concurrency-d/issues/11),
[lifecycle #12](https://github.com/alex-1974/concurrency-d/issues/12),
[M0 release gate #16](https://github.com/alex-1974/concurrency-d/issues/16).

## Implementation boundary

The public `concurrency` module selectively exports Executor, TaskHandle,
ExecutorClosedException and WorkerSelfJoinException. Executor composes the actual
M0 OwnedTaskExecutor; it does not fork scheduler/queue/record logic. The existing
result cell and handle implementation move to concurrency.task, with ResultCell
and handle construction restricted to package(concurrency). No second public
handle wrapper or extra per-task handle allocation is added. There is one
facade object per Executor. auto ref forwarding avoids a facade-level callable
copy; the original storage/owned submission copies still occur.

The closed exception now has a public distinct type, retaining the existing
message and admission behavior. Self-close retains the lifecycle guard from #40;
its exception definition moves to the public errors module. Existing internal
lifecycle tests use that same type. Diagnostics/record counters and raw transport
are not part of the public facade.

The supportedTask constraint checks actual default-storage, copy-construction,
assignment and zero-argument invocation requirements for F and non-void R. It
rejects unsupported noncopyable/nonassignable cases at the facade. It is not a
transitive capture/ownership trait; submission remains explicitly @system. The
public guide records borrowing, root lifetime, result readiness, repeated value
get, shared-reference results, backpressure, error and blocking restrictions.

## Outcome-publication failure correction

The existing owned thunk caught a task Throwable and tried to record it, but
silently swallowed a failure in that second operation. A handle could then wait
indefinitely for an unreported outcome while the scheduler accounted the task
as complete. That second failure now invokes the existing WORKER fatal boundary.
A separate isolated source-overlay probe injects failure at record.cell.fail and
requires the WORKER marker plus SIGABRT. No new production fault flag is added.
This extends the lifecycle suite from ten to eleven synthetic cases per mode;
ordinary task-error delivery remains a normal handle outcome.

## Public-only consumers

`examples/cpu-executor` is a separate DUB package whose module is `app`, importing
only `concurrency` from this library. It computes 48 chunks, checks worker vs
controller identity, applies completion only on the controller and validates
repeated result access after explicit join/GC.

`tests/public_api` is also outside package concurrency and imports only the
public module. It exercises:

- typed and void results, repeated get, stored task Exceptions, function pointers
  and a caller-retained delegate;
- typed self-close failure followed by continued admission; typed close rejection
  for both submission methods and repeated external shutdown;
- deterministic ingress-full and independent retained-budget-full rejection;
  rejected work has no execution side effect; later submission reclaims the
  returned record budget without a public maintenance method;
- eight queued three-node GC graphs, dropped handles, four forced collections
  while a worker is blocked, and exactly one execution after release;
- eight four-producer/two-closer rounds with per-record accepted/executed equality
  and an accepted seed; these are bounded stress, not exhaustive scheduling;
- 256 sequential jobs through a record budget of two, plus invalid constructor
  limits and compile-time checks that private owners/cells/counters are absent.

Nine separately compiled whole-source negatives reject @safe submission,
noncopyable F, noncopyable R, nonassignable R, noncallable F, external handle/cell
construction, raw transport and private owner access. The gate requires intended
symbol/constraint/visibility diagnostics; an unrelated dependency/link error or
successful build cannot count as a rejection PASS.

## Reproduction

```sh
python3 tools/validation/m0_public_api.py dmd
python3 tools/validation/m0_public_api.py ldc2
python3 tools/validation/m0_lifecycle.py dmd
python3 tools/validation/m0_lifecycle.py ldc2
dub test --compiler=dmd --force
dub test --compiler=ldc2 --force
dub build --compiler=dmd --build=docs
```

Public consumers and all negative boundaries pass locally on DMD 2.111.0 and
LDC 1.42.0 in debug/release; LDC also runs assertions-on -O3 for the public
consumer. The lifecycle suite and root unit gates are required after the result
module move and publication-failure correction. Ddoc generation succeeds, and
the generated public modules contain the expected API symbols without exposing
ResultCell as a documented public class. CI adds the public gate to pinned
DMD 2.111.0/LDC 1.41.0 and native ARM64 alongside the full lifecycle suite.
An actual published-commit CI receipt is required before claiming pinned results.

## Remaining release work

This branch depends on the lifecycle policy in #40 and must not bypass its review
by merging the public facade independently. Final contract/API review, a matched
public-path optimized end-to-end baseline, license/package metadata, version/tag
and publication qualification remain open. No package release, Conditional
promotion, general safe TaskScope, OS-failure recovery, new fairness guarantee or
speedup claim follows from these functional/compiler checks. Historical research
branches and their source pins remain unchanged.

## Matched optimized public-path diagnostic

The standalone benchmarks/executor package instantiates the same workload over
the public facade and its actual internal owner in one LDC release binary. Both
use identical job values, work kernel, producer/worker counts, ingress 256,
record budget 512, handle/result checks and explicit join. The measured interval
includes owner startup, submission, result observation and join, excluding the
preallocated handle array, reference checksum, process launch and compilation.

`python3 tools/validation/m0_public_path.py NEW-RESULT-DIRECTORY` preserves source
hashes, compiler/version/platform, binary hash, warmups, alternating AB/BA raw
rows, per-pair ratios and an INCOMPLETE/COMPLETE receipt. Defaults are eight pairs
at 1P/1W and 4P/4W with 16,384 tasks per process. Existing result directories are
never overwritten. CI runs only a small same-work checksum smoke without a
performance threshold.

The first local exploratory run observed public/internal median ratios of about
1.026 (1P/1W) and 1.016 (4P/4W), with substantial individual variation. This is
neither an intrinsic facade-cost estimate nor a qualified no-regression result.
A thermally controlled native public-path baseline remains a release gate.
