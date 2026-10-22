# Benchmarks

Performance qualification will include, where applicable:

- task throughput;
- task scheduling latency;
- local push/pop cost;
- steal cost;
- contested steal cost;
- scaling across worker counts;
- wake-up P50/P95/P99 latency;
- idle CPU usage;
- allocation count and cost;
- cache misses;
- retired instructions;
- context switches.

Reference comparisons must perform materially equivalent work.

Current repository commands (benchmarks are excluded from the library archive):

```sh
dub run --root=benchmarks/parking --compiler=ldc2 --build=release -- 2 64
dub run --root=benchmarks/executor --compiler=ldc2 --build=release -- public 4 4 1024
```
