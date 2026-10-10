# XPS native R0.5 benchmark environment — 2026-10-10

This is **user-supplied terminal provenance** for the
[120-row XPS mixed-producer dataset](./xps-mixed-2026-10-10-raw.csv).
The values below came from `git rev-parse HEAD`, `ldc2 --version`,
and `evidence/r05-xps-mixed/environment.txt` in the original local checkout.
They were supplied in a follow-up after the 30,000-task runs.

## Source identity

- Repository: `alex-1974/concurrency-d`.
- Checked-out research branch: `perf/r05-owned-task-pipeline`.
- **Exact benchmark source revision:** `2dd09d85235fde72279545d0efbdffb47b7c51c9`.
- Local checkout: `~/Programmiersprachen/dlang/concurrency-d`.
  The previously suggested `d-geospatial-workspace/libs/concurrency-d`
  directory was absent. This is a path correction, not a benchmark failure.
- Invoked via `tools/research/r05_mixed_producer_matrix.py`,
  which builds the `task-pipeline-mixed-benchmark` DUB configuration
  with `--build=release` and `--compiler=ldc2`.

## Compiler and OS

- LDC: **1.41.0**, based on DMD **2.111.0**, LLVM **19.1.7**.
- LDC default target: `x86_64-pc-linux-gnu`.
- `ldc2 --version` reports host CPU `skylake`; this does **not**
  independently establish the actual `-mcpu`/LLVM codegen target or
  additional optimization flags selected by DUB.
- Platform string: `Linux-6.17.0-22-generic-x86_64-with-glibc2.43`.
- Architecture: `x86_64`; Linux kernel `6.17.0-22-generic`.

## CPU and topology

- Model: **Intel Core i7-9750H @ 2.60 GHz**.
- Physical topology: **1 socket, 6 cores, 2 threads/core, 12 logical CPUs**.
- Reported clock range: **800 MHz minimum, 4,500 MHz maximum**.
- L1d: **192 KiB total (6 instances)**.
- L1i: **192 KiB total (6 instances)**.
- L2: **1.5 MiB total (6 instances)**.
- L3: **12 MiB (1 instance)**.
- One NUMA node, CPU list 0–11.
- `lscpu` reported 92% CPU frequency scaling **at the time of that
  command**, not a fixed measurement condition or a governor setting.

## Workload configuration

- Worker threads: **4**.
- Total accepted tasks: **30,000 per isolated subprocess**.
- Paired rounds: **5**.
- Producer counts: **1, 4, 8**.
- Retention budgets: **8, 64, 512, 4096**.
- Policies: `freshGc` and `recycleTyped`, alternating run order.
- Mixed workloads: scalar, GC-reachable wide callable payload, `void`.
- Benchmark output: `evidence/r05-xps-mixed/` with `raw.csv`,
  `summary.csv`, `environment.txt` locally.

## Still unknown

The supplied environment text does **not** establish:
CPU frequency governor, turbo/thermal throttling during the timed
runs, power source/profile, system background load or CPU affinity;
actual LDC `-mcpu`/microarchitecture build flags; total cross-thread
GC allocation, collection-pause distributions, or adequately resolved
per-case peak resident-memory differences.

These are relevant to interpreting **small percent-level throughput
changes**, so this document identifies the hardware precisely but
does not elevate short benchmark findings into production guarantees.
