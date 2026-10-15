# P33 native XPS: unchanged P31 versus producer-start-gated P33

Date: 2026-10-15. **Research evidence, not a causal optimization or API decision.**

## Provenance

Received archive `concurrency-p33-xps-20261015T194421Z.tar.gz`; independently computed SHA-256:
`2cc3b5cbd95a0e8f89b789af2d902d4e783115853517167bc86e027daeb8a480`.

Measured Git HEAD `85e0b19b4c96db98c46d3f2774b267481ab43b87`; source-pinned original P31 consumer blob `d19405f2ef0f8d7159978174c1a919ed6d66764f`, production owner blob `e74d6a73f956c562eab176e27687a47249f5815d`, pool blob `b7d8fafcb3179f00cba7e89e28c6d6b9b676353a`. Generated phase-consumer SHA-256 `40be827b5595f833cee55d7e0accebc3b0853703b77c970905207f81c9d79a24`.

XPS Intel i7-9750H 6C/12T, LDC 1.41.0, governor `powersave`. CPU0 frequency samples: start 4,240,877 kHz, end 3,655,460 kHz; no continuous thermal control. Archive contains git status with pre-existing untracked local benchmarking artifacts; it does not establish clean-room isolation. An accompanying `.sha256` receipt was not uploaded, so hash above is independently calculated rather than matched to a submitted receipt.

## Validation and matched work

Three sessions, 324 rows per session for each of original P31 control and gated P33; 972 rows per variant and 729 measured rows per variant. Each session has three warm-up rounds and nine measured rounds; each round consists of 27 fixed profiles (3 work kinds × 3 ownership modes × 1/2/4 producers). All six session CSVs parsed with the expected 19-control / 25-gated columns. Provided session analyzers report matched-work PASS and phase validation PASS. The maximum difference between the sum of P33 five submission-subphases and recorded `submit_ns` is 400 ns, attributable to separate timestamp boundaries; this is not a speed discrepancy. The values below are pooled medians across three sessions, not medians of per-round paired ratios.

**Minimal work, submit phase (milliseconds):**

| owner | producers | control | gated |
|---|---:|---:|---:|
| M0 | 1 | 17.042 | 17.366 |
| M0 | 2 | 30.596 | 37.843 |
| M0 | 4 | 38.706 | 39.360 |
| Deferred | 1 | 17.773 | 18.254 |
| Deferred | 2 | 32.874 | 34.872 |
| Deferred | 4 | 38.435 | 40.051 |
| Managed P29 | 1 | 18.317 | 18.649 |
| Managed P29 | 2 | 30.645 | 37.476 |
| Managed P29 | 4 | 41.132 | 41.517 |

**Shared atomic work, submit phase (ms), control → gated for 1/2/4 producers:**
- M0: 17.254→17.141; 29.222→32.584; 38.388→39.142.
- Deferred: 17.778→19.209; 33.564→34.219; 39.858→40.630.
- Managed: 18.140→18.477; 31.202→34.494; 40.743→41.272.

**Sharded atomic work, submit phase (ms), control → gated:**
- M0: 16.629→16.923; 30.042→32.445; 38.546→40.359.
- Deferred: 17.809→18.203; 29.899→34.214; 38.219→40.070.
- Managed: 18.373→18.899; 30.968→35.509; 39.966→42.012.

**P33 gated minimal-work P29 median phase decomposition (ms):**

| phase | 1 producer | 2 producers | 4 producers |
|---|---:|---:|---:|
| prepare | 0.001 | 0.002 | 0.002 |
| launch | 0.021 | 0.044 | 0.089 |
| reach start gate | 0.012 | 0.031 | 0.059 |
| release gate | 0.001 | 0.002 | 0.005 |
| release-to-producer-join | 18.561 | 37.408 | 41.396 |
| worker join/root reclaim | 0.085 | 0.079 | 0.062 |

**Interpretation:** for this admitted P31 ownership workload, thread start and gate synchronization are small compared with release-to-producer-join time. However this latter interval still includes owned TaskRecord allocation, manager/queue operations, worker execution, retry scheduling, producer completion and Thread.join. Barrier insertion can change scheduling; in some two-producer cells it materially increases observed submission duration and must not be treated as a constant offset.

**No evidence** that the P29 manager mutex or M0 inbox mutex individually dominates the remaining interval. The earlier direct TaskRef P32 experiment is not semantically matched to this ownership workload; its scaling results must not be substituted here. No production change or general `@safe` API decision is justified.

## Next study

P34 should decompose per-attempt allocation and management overhead on the *source-pinned actual P31 owner path*, using per-producer thread-local telemetry and a low-overhead null-probe control. Validate statistical disturbance separately; retain three work kinds, all three ownership modes, source blobs, native join/root reclamation and exact completion oracles. The admitted TaskRecord lifetime must remain valid until native join. Keep Issue #17 open, ADR-0001 PROPOSED, PR #38 Draft.
