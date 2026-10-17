# P42.9 native benchmark protocol — not yet measured

The paired research benchmark uses the **same D consumer** for original and conditional notification. Source: `consumer/p42_benchmark.d`, with `P42Baseline` selecting the unchanged internal pool. Both arms execute identical non-owning TaskRefs, bounded capacity 256, per-record atomic increments, producer admission retries, and exact-once completion assertions. Only the research overlay condition-notify policy differs.

Run on the XPS from the repository root, with LDC 1.41+ installed:

```bash
bash tools/research/m1_p42_native_benchmark.sh /path/to/new/results-directory
```

The runner refuses to overwrite an existing generated overlay; keep the research tree clean. It records source SHA-256, Git commit, LDC version, raw CSV, and CSV hash. Each run measures pool creation, producer start/join, submission and close/join, then checks every task. It exercises 1/1, 2/2 and 4/4 producer/worker pairs, 8192 tasks each, across three sessions and four paired measurements per session, rotating execution order.

**Qualification limits:** this is an end-to-end completion throughput microbenchmark, **not** a task wake-to-execute tail-latency measurement or CPU profile. Builds occur inside `dub run` before timed code, but CLI overhead, thermal state, benchmark order and environment must still be reported. No direct statement about notification-call savings or latency is supported. Add independent warmups, frequencies, thermal conditions and larger/varied task costs before treating any delta as a production candidate. The script and configurations are research-only; no benchmark numbers or performance claims exist until real native XPS archives are inspected.

## P42.10 protocol revision — 2026-10-17

P42.9 XPS results (72 rows, commit `26deaca911c1a92f933a24cfb6cabb8f628218fe`) did **not** demonstrate a consistent benefit: the median paired deltas were −2.19% (1/1), +1.22% (2/2), −2.03% (4/4), with substantially larger within-case dispersion. See the independent archived XPS analysis; do not infer a speedup. The previous `dub run` benchmark used 8192 tasks per measurement, each ~2–5 ms.

The revised `m1_p42_native_benchmark.sh` now **requires a fresh output directory**, generates the source-pinned overlay, builds each optimized LDC arm once, copies the binaries into the results directory, records hashes and host metadata, performs three untimed warmup executions per arm and configuration, and executes 131072 tasks for each of 72 measured runs with alternating paired arm order. The consumer uses explicit completion/once-only exceptions even when release assertions are disabled. Execution prints progress to stdout; DUB build output is preserved separately in logs. The benchmark remains end-to-end pool lifecycle plus submission and join; it does not isolate wake-up tail latency.

The new XPS run is **not yet executed** and the changed benchmark code/runner are **not yet CI-qualified**. Benchmark comparability across versions is limited because task count and warmups changed: analyze paired deltas *within* a run, never mix raw microsecond values from P42.9 with P42.10. Do not overwrite or regenerate the P42.9 evidence.
