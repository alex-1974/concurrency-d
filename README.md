# concurrency-d

`concurrency-d` is a high-performance generic concurrency and task-execution
library for D.

The project is currently in the research and architecture phase. A version-zero
public CPU-executor candidate now exports `Executor`, `TaskHandle` and typed
executor-use exceptions through `import concurrency`. It is not a stable release.

See [the public executor guide](docs/EXECUTOR.md) and the independent
[CPU/completion example](https://github.com/alex-1974/concurrency-d/blob/feat/m0-public-executor/examples/cpu-executor/source/app.d). Submission is
explicitly `@system`; callers remain responsible for capture lifetime and
synchronization. Keep the executor rooted and explicitly `closeAndJoin` it.
The candidate native-lifetime policy is process-fatal on uncertain start/join.

From a repository checkout:

```sh
dub run --root=examples/cpu-executor --compiler=dmd
dub run --root=examples/cpu-executor --compiler=ldc2 --build=release
```

## Repository boundary

Detailed research, experimental prototypes, raw measurements and historical
variants live in [concurrency-d-research](https://github.com/alex-1974/concurrency-d-research).
Its [provenance](https://github.com/alex-1974/concurrency-d-research/blob/main/PROVENANCE.md)
records pinned library commits and verified file manifests. The library has no
build or runtime dependency on the research repository.

This repository keeps production source, active regression/release gates,
maintained qualification benchmarks, examples, user documentation and concise
architecture decisions. The consumer archive contains only the library and its
small public documentation set. See the
[research separation decision](https://github.com/alex-1974/concurrency-d/blob/feat/m0-public-executor/docs/adr/0001-research-repository.md)
for the migration boundary and preserved history.

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

## License

MIT. See [LICENSE](LICENSE).

## Development acknowledgement

Assisted by AI.

The library has been developed and reviewed with assistance from multiple AI
systems and models. API compatibility, source correctness and release decisions
remain subject to maintainer review and the repository's verification gates.
