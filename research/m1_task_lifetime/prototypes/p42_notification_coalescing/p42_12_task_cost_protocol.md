# P42.12 — task-cost sensitivity experiment

P42.11 reported a median paired change of −7.63% at 4 producers / 4 workers in one six-session XPS run; this is not enough to infer a mechanism or release readiness.

The new **research-only** `P42MediumTask` compile-time mode adds 32 relaxed atomic increments on a distinct per-task counter and checks the exact resulting value after join. This makes the additional work observable even under optimized LDC compilation. It intentionally increases memory-operation cost, not realistic CPU-only arithmetic; the light mode is the original one atomic hit. Both baseline and conditional use the same module source, task lifetimes, pool size, and 4/4 workload.

Run the isolated XPS task-cost experiment using a **new output directory**:

```bash
bash tools/research/m1_p42_task_cost_benchmark.sh "$HOME/p42-12-xps-results"
```

The script prebuilds four binaries, records their hashes and source/commit/compiler identifiers, warms each up independently, then collects **72 measurements** (2 costs × 3 sessions × 6 pairs × 2 arms), alternating arm order, with 131072 tasks per run. Results are not interchangeable with P42.9/P42.10/P42.11 due to changed cost, aggregation and ordering.

**Correctness and limits:** the medium-cost build must pass DMD and LDC gate checks before performance is qualified; this PR has not yet established that. This measures complete pool lifecycle/throughput, not the wake-to-execute latency. A distinct idle-to-active latency consumer remains future work. Conditional Notification remains experimental.
