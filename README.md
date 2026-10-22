# concurrency-d

`concurrency-d` is a high-performance generic concurrency and task-execution
library for D.

The project is currently in the research and architecture phase.

Initial research focuses on:

- typed tasks and type-erased scheduling boundaries;
- structured concurrency and scoped task lifetime;
- CPU worker pools;
- work-stealing deques;
- task allocation and recycling;
- worker parking and wake-up;
- cancellation;
- execution-context abstraction;
- optional future fiber scheduling.

Performance is a primary design requirement. Mature C++ and Rust runtimes are
used as independent implementation and benchmark references rather than as APIs
to translate mechanically into D.

## Delivery status

The internal M0 CPU executor supports bounded external submission, typed result
handles, GC-retained task records, returned-marker reclamation and portable
parking. The public module is intentionally empty; no stable public executor
API is exported yet. Newer lifetime and scheduler candidates live on research
branches and are not automatically part of a release.

See the [M0 release-readiness ledger](docs/research/m0-release-readiness.md) and
[proposed public executor contract](docs/research/m0-public-executor-contract.md)
for the next delivery slice, evidence and unresolved native-lifecycle boundary.
