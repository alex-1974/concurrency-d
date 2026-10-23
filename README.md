# concurrency-d

`concurrency-d` is a D library for CPU task execution. Version 0.1.0 is
published on [DUB](https://code.dlang.org/packages/concurrency-d) and
[GitHub](https://github.com/alex-1974/concurrency-d/releases/tag/v0.1.0).
That release contains the maintainer-accepted M0 executor API.

The v0.2.0 candidate on `develop` adds a bounded lexical task
scope through `Executor.withScope`. This API is `@system`, experimental, and
not part of the published v0.1.0 archive. It drains accepted children through their
post-dispatch return before scope exit; same-pool workers help available queued
work while admitting or joining nested scoped tasks. `Executor.join(left,
right)` adds a typed two-way path that schedules one branch and runs the other
inline. The retained-task budget must cover active parents and children, and
blocked callbacks can still stall the pool. This does not make arbitrary
captures safe or make ordinary
`TaskHandle.get()` waits cooperative. Its cancellation token is cooperative and
does not waive the join. See the [API guide](docs/EXECUTOR.md)
and proposed [task-lifetime ADR](docs/adr/0002-task-lifetime-families.md).

The released API exports `Executor`, typed `TaskHandle` results and executor-use
exceptions through `import concurrency`. Submission is explicitly `@system`:
callers must keep captures valid and synchronize shared state. Root the executor
and call `closeAndJoin` explicitly. Uncertain native worker start/join and
escaped scheduler failures use the process-fatal lifecycle policy accepted by
the maintainer.

See the [independent CPU/completion example](examples/cpu-executor/source/app.d).
Run it from the repository root:

```sh
dub run --root=examples/cpu-executor --compiler=dmd
dub run --root=examples/cpu-executor --compiler=ldc2 --build=release
```

The provisional M1 recursive scoped fork-join example also verifies the same
sum with one and four workers, including worker-side nested helping. It is a
correctness example, not evidence of a speedup:

```sh
dub run --root=examples/nested-scopes --compiler=dmd
dub run --root=examples/nested-scopes --compiler=ldc2 --build=release
```

## Project status

M0 passed the pinned DMD/LDC and native ARM64 CI. The scoped Dell XPS 15
performance qualification passed its predeclared 10% bound for the two tested
kernels and 1P/1W plus 4P/4W scenarios; see
[the result and scope](docs/M0-PERFORMANCE-QUALIFICATION.md). This is not a
general hardware or workload guarantee. The project remains on the 0.x version
line; v0.1.0 does not promise 1.0 compatibility.

The M1 candidate adds structured tasks, practical lifetime control, cooperative
cancellation and evidence-based runtime choices. It also applies
the narrow conditional publish-notification policy selected in
[ADR-0003](docs/adr/0003-coalesce-idle-publish-notifications.md). Detailed
prototypes and measurements live in
[concurrency-d-research](https://github.com/alex-1974/concurrency-d-research).
Only explicitly recorded decisions are transferred into this repository; the
library has no build or runtime dependency on the research repository.

This repository keeps production source, active regression and release gates,
maintained qualification benchmarks, examples, user documentation and concise
architecture decisions. The
[research separation decision](docs/adr/0001-research-repository.md) describes
the migration boundary and preserved history.

The current v0.2 candidate's satisfied and outstanding release gates are listed
in the [v0.2 qualification record](docs/V0.2-RELEASE-QUALIFICATION.md).

## License

MIT. See [LICENSE](LICENSE).

## Development acknowledgement

Assisted by AI.

The library has been developed and reviewed with assistance from multiple AI
systems and models. API compatibility and source correctness remain subject to
the repository's verification gates; the maintainer makes final release
decisions.
