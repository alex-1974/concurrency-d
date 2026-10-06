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
