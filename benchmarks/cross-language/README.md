# Cross-language CPU reference

This diagnostic runs the same deterministic per-item CPU kernel used by
`benchmarks/end-to-end` through Taskflow, oneTBB and Rayon. It is a comparison aid, not
a universal ranking or a release threshold. It reports only elapsed wall time
and verifies the same checksum for every arm.

The matching workloads are `fine` (1,024 items at base cost), `medium` (256 at
8x), `coarse` (32 at 64x), and `irregular` (256 at 4x with the same
deterministic item-cost formula). `workers` is the total execution budget for
each runtime: D `Executor(workers)`, Taskflow's worker count, or Rayon
`ThreadPoolBuilder::num_threads(workers)`. Pool/executor startup and shutdown
are included in each timed sample. The D executable has additional arms and
grain sizes; filter it to the comparable `parallelForReused` or
`parallelForAdaptiveReused` arms and match worker count, workload and grain.
The optional `WAVES` argument repeats work inside one timed runtime. Use
`WAVES=1` with D's non-reused `parallelFor` to compare cold pool/executor
startup, or `WAVES=8` with D's reused arms to compare long-lived schedulers.
Each multi-wave adapter reuses its executor/pool and output storage; total
chunks and checksum cover all waves.

Taskflow exposes static and guided partitioning. Rayon exposes `with_min_len`
and `with_max_len`; these are library-specific grain controls and are not
semantically identical to Taskflow's partitioner chunk size or D's fixed and
adaptive claim sizes. oneTBB exposes simple and auto partitioners over a
blocked range. Its process-wide scheduler is warmed once per executable, so
its first global runtime initialization is excluded; per-sample arena creation,
work and destruction are timed. Sweep the knobs and compare each library's
best observed setting as well as matching numeric settings; do not treat one
setting as an equivalent implementation policy.

Versions are pinned: Taskflow source commit
`45366fe5bc4f2f8ec9aa590b40c504e296886865` (v4.1.0), oneTBB source commit
`3046c8b0c29df995980003ea24f4d78c80ec0c8d` (2023.1.0), and Rayon 1.12.0
with its complete dependency graph in `rayon/Cargo.lock`. C++ uses C++20 and `-O3
-DNDEBUG`; Rust uses Cargo's release profile. For reproducible host-specific
measurements, record compiler versions, CPU/kernel, power mode, thermal state,
exact command, raw CSVs, and separate process sessions.

```sh
cmake -S benchmarks/cross-language -B /tmp/taskflow-reference -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/taskflow-reference --target taskflow_reference onetbb_reference -j
cargo build --manifest-path benchmarks/cross-language/rayon/Cargo.toml --release

/tmp/taskflow-reference/taskflow_reference 4 20 5 128 > taskflow.csv
/tmp/taskflow-reference/onetbb_reference 4 20 5 128 > onetbb.csv
benchmarks/cross-language/rayon/target/release/rayon-reference 4 20 5 128 > rayon.csv
dub build --root=benchmarks/end-to-end --compiler=ldc2 --build=release
benchmarks/end-to-end/concurrency-end-to-end-benchmark 4 20 5 128 > d.csv
```

Arguments are `WORKERS SAMPLES WARMUPS BASE_ITERATIONS [WAVES]`. All arms
validate checksums and exit nonzero on mismatch. Compilation and benchmark
executables are outside the D package archive.
