# R0.5 — First paired native-runner storage comparison (2026-10-10)

Status: **KEEP GC-fresh as default; DEFER general typed-node recycling**.
This is a provisional benchmark decision, **not** a claim about a local
Dell XPS or a productized task-storage implementation.

## Qualified conditions

- Repo: `alex-1974/concurrency-d`, branch `perf/r05-owned-task-pipeline`.
- Exact source head: `5e386994611db12ca2ed09d94478fa144bc8b300`.
- [Full 2-platform matrix](https://github.com/alex-1974/concurrency-d/actions/runs/38086521625): **PASS**.
- [DMD/LDC and ARM64 consumer gate](https://github.com/alex-1974/concurrency-d/actions/runs/38086521658): **PASS**.
- Compiler: LDC 1.41.0, optimized release, GitHub-hosted Ubuntu 24.04,
  native x86-64 and native ARM64; never compare absolute numbers between
  these different machines.
- Four workers; 6000 accepted tasks **per isolated subprocess**; three
  paired rounds; same callable/payload and outcome semantics per pair.
- Retention budgets: 8, 64, 512, 4096. Concrete nodes recycled only
  after post-dispatch acquire release marker; old TaskHandles own distinct
  result cells. Both policies create ResultCells and handles per accepted
  task and reject full queues before per-task allocations.

## Median paired throughput ratio (recycle / GC-fresh)

> 1.00× means equivalent throughput; >1.00× favors typed recycling.
> These are **median of three paired ratios**, not the ratio of the
> independent median throughputs. Shared hosts introduce run-to-run noise.

| Szenario | Budget | x86-64 LDC | ARM64 LDC |
|---|---:|---:|---:|
| Scalar | 8 | 0.9648× | 0.9520× |
| Scalar | 64 | 0.9780× | 0.9749× |
| Scalar | 512 | 1.1064× | 1.0074× |
| Scalar | 4096 | 1.0133× | 0.9652× |
| 256-byte Callable | 8 | 0.9692× | 0.9666× |
| 256-byte Callable | 64 | 1.0406× | 0.9715× |
| 256-byte Callable | 512 | 1.0785× | 1.0651× |
| 256-byte Callable | 4096 | 1.0114× | 0.9448× |
| void | 8 | 0.9699× | 0.9781× |
| void | 64 | 1.0144× | 1.0004× |
| void | 512 | 1.0501× | 1.0725× |
| void | 4096 | 0.9519× | 0.9842× |

## Evidence retained

- [Raw x86-64 rows](./ci-x86-64-2026-10-10.csv): 72 measurements
  containing scenario, budget, policy, round, tasks/s, per-process
  peak RSS (KiB), and fresh/reused node counts.
- [Raw ARM64 rows](./ci-arm64-2026-10-10.csv): same 72-row schema.
- Extended GC producer-byte and heap-used-delta CSV plus environment
  files are attached to the GitHub Actions matrix run as 30-day
  artifacts. The permanent CSVs here preserve measured core workload
  rows even after those ephemeral artifacts expire.

## Conclusions and limitations

**KEEP (baseline):** GC-fresh owned nodes remain the default. The
record-retention budget and post-dispatch completion protocol are
unchanged, as are result/error/shutdown guarantees.

**DEFER (optimization):** Typed node reuse dramatically reduces the
`OwnedNode` constructor/GC allocation count for long-lived,
homogeneous workloads. For 6000 tasks with budget 8, the candidate
typically creates about **8** nodes and rearms **5992**; GC-fresh
creates 6000. This does **not** imply an equal reduction of total GC
allocations, because ResultCells, handles, and other objects remain
allocated. At present, throughput varies in sign and magnitude
across workload/budget/platform, including regressions.

**DEFER (qualified winner):** Before changing default policy or
proclaiming a speed win, repeat on controlled XPS LDC with steady
power/CPU conditions and longer runs; measure allocator/GC pause
profiles, GC-visible closures, mixed callable-type cache misses,
contention under multiple producers, allocation and peak RSS; compare
C++ Taskflow/Rust Rayon only with equivalent ownership and result
semantics. These are explicit issue #20/#17 tasks.

**Research/production boundary:** The typed-node cache is still
package-internal and experimental; it does not establish a new
public API or stronger `@safe` claims. If an implementation is promoted
to `develop`, preserve only the accepted and qualified code after a
deliberate PR; do not blindly merge experimental history.
