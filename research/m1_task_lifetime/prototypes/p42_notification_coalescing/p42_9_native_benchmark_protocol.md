# P42.9 native benchmark protocol — not yet measured

The paired research benchmark uses the **same D consumer** for original and conditional notification. Source: `consumer/p42_benchmark.d`, with `P42Baseline` selecting the unchanged internal pool. Both arms execute identical non-owning TaskRefs, bounded capacity 256, per-record atomic increments, producer admission retries, and exact-once completion assertions. Only the research overlay condition-notify policy differs.

Run on the XPS from the repository root, with LDC 1.41+ installed:

```bash
bash tools/research/m1_p42_native_benchmark.sh /path/to/new/results-directory
```

The runner refuses to overwrite an existing generated overlay; keep the research tree clean. It records source SHA-256, Git commit, LDC version, raw CSV, and CSV hash. Each run measures pool creation, producer start/join, submission and close/join, then checks every task. It exercises 1/1, 2/2 and 4/4 producer/worker pairs, 8192 tasks each, across three sessions and four paired measurements per session, rotating execution order.

**Qualification limits:** this is an end-to-end completion throughput microbenchmark, **not** a task wake-to-execute tail-latency measurement or CPU profile. Builds occur inside `dub run` before timed code, but CLI overhead, thermal state, benchmark order and environment must still be reported. No direct statement about notification-call savings or latency is supported. Add independent warmups, frequencies, thermal conditions and larger/varied task costs before treating any delta as a production candidate. The script and configurations are research-only; no benchmark numbers or performance claims exist until real native XPS archives are inspected.
