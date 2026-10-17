# P42.14 — optimized XPS idle publication-to-execution measurement

The P42.13 correctness gate at https://github.com/alex-1974/concurrency-d/actions/runs/39058808463 completed successfully for DMD 2.111.0 and LDC 1.41.0. P42.14 collects comparative **native** timings; no XPS results have been received yet.

Run from the separate research worktree, using a fresh output directory:

```bash
bash tools/research/m1_p42_idle_native_benchmark.sh "$HOME/p42-14-idle-xps-results"
```

The script refuses existing output/overlay paths, builds optimized LDC baseline and conditional binaries before measurements, records source SHA-256, compiler, CPU/platform, binary hashes, three untimed warmups for each arm, and 3 sessions × 6 alternating pairs × 2 arms × 64 iterations = **2304 raw timing samples** in `results.csv`; additionally archives full raw stdout from each run.

**Measurement definition:** `publish_to_start_ticks` is a difference of `MonoTime.currTime.ticks` captured immediately before task admission and in the callback. It includes submission lock acquisition and producer scheduling as well as wake and dispatch. The observed `parkCount` proves entry into the condition-variable wait function at some time, **not confirmed sleep at the instant of submission**. This benchmark creates a new one-worker pool each round; pool startup and shutdown are *outside* the timed interval but affect machine state. The 64 iterations of each run are correlated. Tail summaries (P95/P99) should be reported as exploratory and stratified by session/run, not as independently sampled kernel wake latencies. Positive performance evidence is not a safety proof.

The native runner has not yet run on the XPS; optimized benchmarking is distinct from the passing debug correctness gate. No production code, public API or scheduler decision has been changed.
