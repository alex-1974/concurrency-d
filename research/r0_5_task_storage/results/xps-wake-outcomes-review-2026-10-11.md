# R0.5 — Dell XPS wake-to-first-search qualification (2026-10-11)

**Research status:** source evidence independently rechecked; **KEEP** the
existing `freshGc` default and generation-safe condition-variable
parking. **DEFER** notification coalescing, spin-before-park, typed-node
recycling and admission redesign. This report documents measurements; it
does not make a production performance or scheduling guarantee.

## Source/provenance

The user supplied `r05-xps-wake-outcomes.tar.gz` containing the original
Linux process-isolated `raw.csv`, `summary.csv` and `environment.txt`.
The files were read from the archive without executing archive content.

| Input | Bytes | SHA-256 |
|---|---:|---|
| Archive `r05-xps-wake-outcomes.tar.gz` | 10,735 | `06a2f0f6fa27eb933c663e867d1d6cacf7c5835d92a0e0585eee10dd383d18dd` |
| Original `raw.csv` | 21,760 | `27f4fc5b61a7e23bfbc86730bc07132d9af2c366db073c4f0e1759dd09dded8f` |
| Original `summary.csv` | 1,638 | `3f7379b7ed1e6a008d88d7e05ce14bae8708a212d81d062e6eeb9aba7438e2eb` |
| Original `environment.txt` | 5,669 | `f1385a846ca7942e1e803bf5e2fd7da95cd9d5fb43f8d3c3047172a54ef67777` |

The archive remains the authoritative **44-column original CSV**. To
make the experiment reviewable in Git, the
[12-group human-readable summary](./xps-wake-outcomes-2026-10-11-summary.csv)
has all source-reported numeric fields, and
[60 paired observations](./xps-wake-outcomes-2026-10-11-paired.csv)
retain the most relevant raw worker-search and throughput counters.
The paired CSV has 17 selected columns, not a lossless reproduction of
all 44 source fields; refer back to the original archive when needed.
The CSV in Git uses normalized LF line endings rather than asserting
byte identity with the original archive's CRLF files.

`environment.txt` confirms:

- **Source HEAD:** `340da23ef53ee35d9aa15d413248c45c3b8d5600`;
- **Compiler:** LDC 1.41.0 / LLVM 19.1.7 / DMD frontend 2.111.0;
- **OS:** Linux 6.17.0-22-generic, x86-64, glibc 2.43;
- **Hardware:** Intel Core i7-9750H, 6 physical / 12 logical cores;
- **CPU0 governor:** `powersave` at sampling time. Turbo/frequency,
  background activity, power source and temperature during the
  measurement interval were not controlled or logged.

Fixed workload: **4 executor workers, 30,000 accepted tasks/process,
5 paired rounds**, producers **1/4/8**, retention budget **512**,
`striped` execution counters, both `minimal` and `compute-1024`
tasks, both `freshGc` and `recycleTyped`. Each configuration ran
twice per round, with `parkingProfile=on/off` order alternated.
The instrumentation counts events but takes no per-task timestamps.

## Independent validation

- Original `raw.csv`: exactly **120 rows / 44 columns**, with
  **120 unique** (round, workload, storage policy, producer count,
  parking-profile mode) tuples;
- **60 exact ON/OFF pairs** and **12 group summaries**, five rounds
  for every group;
- Every row reports `fresh_nodes + reused_nodes = 30,000`;
- Every ON row reports `executions = claimed_tasks =
  ingress_notifications = 30,000`;
- Every ON row passes `condition_waits = wait_returns`,
  wait-predicate partition and useful/empty/drain search partition;
- Steal success never exceeds attempts and ingress occupancy never
  exceeds 64; OFF runs have no worker/inbox diagnostic fields;
- **All 12 published medians and round-paired ratios reproduced**
  independently from the raw CSV. Differences were limited to
  documented rounding (at most 0.005 percentage points).

No failed results, duplicate runs or incomplete joins were present.

## 1. Wake outcomes: *first search after* a completed wait

Each percentage's denominator is **final wait-loop exits**, not
all `Condition.wait` returns, submitted tasks or `notify` calls.
"Useful" means that the worker acquired work in its first following
local/inbox/steal search cycle. "Empty" means the worker returned to
the idle/park decision without acquiring work. Shutdown/drain makes
up the remaining fraction.

The data below are the **median of five independent run-level
percentages**, not ratios of group-median event totals.

| Workload | Producers | GC useful | GC empty | Recycle useful | Recycle empty |
|---|---:|---:|---:|---:|---:|
| minimal | 1 | 58.25% | 41.73% | 60.02% | 39.96% |
| minimal | **4** | **55.48%** | **44.50%** | 56.25% | 43.73% |
| minimal | **8** | **55.18%** | **44.81%** | 56.16% | 43.82% |
| compute-1024 | 1 | 76.69% | 23.28% | 80.99% | 18.97% |
| compute-1024 | **4** | **64.35%** | **35.63%** | 65.22% | 34.76% |
| compute-1024 | **8** | **63.31%** | **36.67%** | 64.39% | 35.58% |

The short **hosted** two-round x86-64/ARM64 CI experiment previously
showed roughly 61–62% useful search / 37–38% empty for GC/minimal
with four producers. The five-round **native XPS** result is materially
worse at **55.48% useful / 44.50% empty**. The qualitative finding
reproduces, but do not transfer hosted percentages or absolute
throughput to the XPS.

For GC/minimal/4p, the five individual empty fractions are tightly
grouped at **43.31%, 44.51%, 44.50%, 44.89%, 43.71%**.
This is consistent across the five XPS rounds, not driven by a
single bad run. For GC/compute-1024/4p the comparable span is
approximately **34.96%–36.44%**.

The workload difference is meaningful: doing compute-1024 work
produced fewer empty post-wait searches than tiny minimal tasks,
although **absolute throughput and producer scaling** must still
be separately qualified.

## 2. Worker churn and inbox batch occupancy

GC fresh medians normalized by 30,000 executed tasks:

| Workload | Producers | Condition waits / task | Failed steals / task | Claimed tasks / inbox batch |
|---|---:|---:|---:|---:|
| minimal | 1 | 0.6413 | 1.9065 | 2.043 |
| minimal | **4** | **0.8558** | **2.5153** | **1.569** |
| minimal | **8** | **0.8728** | **2.5527** | **1.566** |
| compute-1024 | 1 | 0.4171 | 1.1783 | 2.081 |
| compute-1024 | **4** | **0.6206** | **1.8257** | **1.470** |
| compute-1024 | **8** | **0.6601** | **1.9611** | **1.434** |

For GC/minimal/4p the median per-case observation represents
about 25,674 condition wait entries, roughly 75,459 failed steals
and roughly 11,238 empty first searches after waits during 30,000
tasks. These are *event counts*, **not wasted CPU nanoseconds**.

The eight-element ingress claim buffer remains lightly occupied at
four/eight producers, approximately 1.4–1.6 tasks per claim.
A larger buffer by itself does not create larger available batches;
deliberately delaying claims could harm tail latency or fairness.

## 3. What causes the empty wake search?

The `waitExitsGenerationOnly` median is **42.13%** of final
wait-loop exits for GC/minimal/4p and **42.97%** at eight producers.
Importantly, this predicate classification **overlaps with**
the later useful/empty search classification, and the two percentages
must NOT be added. A generation-only exit says the generation changed
while the inbox is empty when checked; it does not identify whether
`notify`, worker local-work announcement, another worker's claim,
or shutdown caused the scheduling event.

**Negative evidence:** In all 60 profiled XPS runs,
`still_blocked == 0`. Thus no immediate condition re-wait with
a still-blocked predicate was observed. The earlier hypothesis that
frequent *spurious return + immediate re-wait* explains the bulk of
worker churn is **not supported** in these runs.

Likewise `useful_local == 0` in all runs, consistent with the
current owner-only deque/publish model; the successful post-wait
searches occurred through inbox claims or stealing from peers.
For GC/minimal/4p the typical useful shares of all final exits
are about **48.4 percentage points inbox** and **7.1 points steal**.

The measured **44.50% empty next searches** remain genuine, but
do not prove 44.50% of notifications were unnecessary.
Another worker can claim work before the resumed worker searches;
a returned worker can also encounter more work in a subsequent
cycle. No causal per-notification tracking exists.

## 4. Profile observer effect and scaling

Five **paired ON/OFF throughput ratios**, by scenario:

| Workload | Producers | GC profiled/unprofiled | Recycle profiled/unprofiled |
|---|---:|---:|---:|
| minimal | 1 | 0.8891× | 1.0402× |
| minimal | 4 | 1.0358× | 0.9971× |
| minimal | 8 | 0.9745× | 1.0013× |
| compute-1024 | 1 | 1.0540× | 1.0201× |
| compute-1024 | 4 | 0.9414× | 0.9651× |
| compute-1024 | 8 | 1.0112× | 0.9894× |

On the XPS the opt-in event counters generally have a modest but
variable throughput impact; one-producer measurements are especially
noisy. They are **not free**, and ON/OFF performance cannot itself
be interpreted as an improvement in scheduler policy: the policy did
not change.

Example GC/minimal 4p: unprofiled median total throughput
**171,806 tasks/s** versus GC/minimal 1p **281,668 tasks/s**;
both values differ from prior XPS experiments under the same
CPU0 `powersave` governor, reinforcing caution about comparing
absolute rates across separate benchmark sessions.

This study did **not** measure per-task tail latency, per-wakeup
elapsed time, actual caller-facing fairness, idle CPU in no-work
steady state, or notify-to-task causal attribution.

## Decision: KEEP / DEFER

**KEEP** the production `freshGc` baseline; current condition-variable
generation predicate, exact-task accounting, lifetime/GC roots, and
shutdown semantics.

**DEFER** typed-node reuse as the default, spin-before-park,
notification coalescing, delayed ingress batch claiming, and
lock-free/batched producer admission. There is **no measured
end-to-end improvement from such a change** in this archive.

The next smallest research candidate should **isolate wakeup
notification policy** on a dedicated experimental branch or this
grandfathered research PR, alongside unchanged control, without
collapsing ownership/handle semantics. It must measure actual
notify/park/wait/useful-search event accounting plus **latency
p50/p95/p99, idle CPU, fairness, and shutdown** under controlled
frequency/governor conditions. An algorithmic alternative is
not yet justified as production code.

Prior hosted measurements support only the general observation that
short work triggers more idle coordination than compute tasks;
the native XPS evidence is authoritative for this machine.

See [research Draft PR #35](https://github.com/alex-1974/concurrency-d/pull/35)
and [research Issue #20](https://github.com/alex-1974/concurrency-d/issues/20).
The research branch must not be merged wholesale into `develop`.
