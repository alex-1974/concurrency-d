# R0.3 P04 follow-up — Generic continuation thresholds

Status: NEGATIVE EVIDENCE

## Purpose

Determine whether one generic saturation threshold can make direct
continuation architecture-robust.

## Candidate 1 — outstanding >= workerCount

Focused P04 evidence was favorable on both hosted x86_64 and native AArch64.

However, the first combined P05 run reproduced the same source under a broader
qualification sequence and observed:

```text
hosted x86_64 irregular single:
    candidate / enqueue-all = 1.1276x
```

The candidate run also showed substantially wider timing dispersion than the
baseline.

Native AArch64 remained strongly favorable.

Conclusion:

The threshold is not stable enough as a universal cross-architecture policy.

## Candidate 2 — outstanding >= 4 * workerCount

The larger headroom was intended to publish substantially more parallel work
before allowing local continuation.

Repeated hosted-x86_64 qualification still found:

```text
recursive batch / 4 workers:
    candidate / enqueue-all = 1.1145x
```

Native AArch64 remained favorable:

```text
recursive:
    0.7613x .. 0.8875x

irregular:
    about 0.83x
```

Conclusion:

The architecture difference is not removed by merely increasing the global
outstanding threshold.

## Decision

Reject a universal generic continuation threshold for R0.3.

Do not weaken or inflate the performance gate to make one cross-architecture
policy appear acceptable.

Instead use compile-time architecture specialization:

- native AArch64: qualified saturation-gated direct continuation;
- x86_64: retain enqueue-all.

This preserves both the x86_64 robustness and the substantial AArch64 gain.

The headroom probes and failed CI gates are retained as research evidence.
