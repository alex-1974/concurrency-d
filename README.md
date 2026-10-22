# concurrency-d

`concurrency-d` is a D library for CPU task execution. The current branch
contains the maintainer-accepted M0 public executor candidate for version 0.1.0.
The release archive, tag, and publication have not yet been prepared or approved.

The candidate exports `Executor`, typed `TaskHandle` results and executor-use
exceptions through `import concurrency`. Submission is explicitly `@system`:
callers must keep captures valid and synchronize shared state. Root the executor
and call `closeAndJoin` explicitly. Uncertain native worker start/join and
escaped scheduler failures use the process-fatal lifecycle policy accepted by
the maintainer.

See the [public executor guide](docs/EXECUTOR.md) and the
[independent CPU/completion example](examples/cpu-executor/source/app.d). Run the
example from the repository root:

```sh
dub run --root=examples/cpu-executor --compiler=dmd
dub run --root=examples/cpu-executor --compiler=ldc2 --build=release
```

## Project status

The M0 candidate combines the internal CPU executor with a small public
facade, bounded admission and retained-task limits, explicit shutdown, and a
public-only consumer example. The exact candidate has passed DMD 2.111, LDC 1.41
and native ARM64 CI. A scoped native performance qualification on the Dell XPS
15 with LDC 1.42 passed its predeclared 10% bound for the two tested kernels and
1P/1W plus 4P/4W scenarios; see
[the result and scope](docs/M0-PERFORMANCE-QUALIFICATION.md). This is not a
general hardware or workload guarantee. The maintainer has accepted the
lifecycle policy and public contract. Exact-head release CI and final
version/archive/tag/publication checks remain open. No stable release is
available yet.

## Repository boundary

Detailed experiments, raw measurements and historical variants live in
[concurrency-d-research](https://github.com/alex-1974/concurrency-d-research).
Its [provenance and manifest](https://github.com/alex-1974/concurrency-d-research/blob/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9/PROVENANCE.md)
pin their sources and file identities. The library has no build or runtime
dependency on that repository.

This repository keeps production source, active regression and release gates,
maintained qualification benchmarks, examples, user documentation and concise
architecture decisions. The
[research separation decision](docs/adr/0001-research-repository.md) describes
the migration boundary and preserved history.

## License

MIT. See [LICENSE](LICENSE).

## Development acknowledgement

Assisted by AI.

The library has been developed and reviewed with assistance from multiple AI
systems and models. API compatibility and source correctness remain subject to
the repository's verification gates; the maintainer makes final release decisions.
