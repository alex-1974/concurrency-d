# Contributing

`concurrency-d` is currently research-first.

Correctness and explicit invariants precede optimization, but performance is
a primary engineering property.

Performance changes require reproducible measurements against the relevant
baseline and, where practical, mature external reference implementations.

Detailed experiments, exploratory harnesses and raw evidence belong in
[concurrency-d-research](https://github.com/alex-1974/concurrency-d-research).
Do not add research/, docs/research/ or tools/research/ to this repository.
Promote reviewed conclusions through library code, active regression/release
checks, concise decisions and documentation. Keep the maintained executor and
parking qualification benchmarks here. Preserve research provenance and link
to pinned research commits when explaining an implementation decision.
