# Roadmap

## M0 — Public CPU executor candidate

The current M0 candidate exposes a bounded CPU executor with typed task handles,
explicit `closeAndJoin`, task-error delivery through handles, and an independent
CPU/completion consumer. Submission is `@system`; capture lifetime and shared
state remain the caller's responsibility. The maintainer has accepted the
process-fatal policy for uncertain native worker lifetime and the public
contract. See [the API guide](docs/EXECUTOR.md).

The exact-head DMD/LDC/native ARM64 CI passes. The scoped Dell XPS 15 / LDC 1.42
public-path baseline passed the predeclared 10% bound for its two kernels and
two producer/worker scenarios; see
[the qualification record](docs/M0-PERFORMANCE-QUALIFICATION.md). Exact-head
release CI and the final version/archive/tag/publication checks remain open.
License metadata and the MIT license file are present.

## M1 — Ownership and scheduler research

Detailed M1 work, including P42.20 and conditional notification experiments, is
preserved in [concurrency-d-research](https://github.com/alex-1974/concurrency-d-research/tree/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9).
These results remain research until separately reviewed and accepted. No general
`TaskScope`, conditional scheduler change, or broad performance claim is part of
the M0 public candidate.

## Longer-term directions

Potential follow-up areas include structured task lifetimes, cancellation,
execution-context integration, alternative allocation strategies and additional
consumers. Their scope and priority depend on M0 acceptance and demonstrated
consumer needs.
