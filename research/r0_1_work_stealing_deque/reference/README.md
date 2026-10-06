# Reference Implementations

Reference source is not copied here merely for convenience.

For every reference record:

- project;
- exact commit/tag;
- source file;
- relevant algorithm/function;
- licence;
- semantic differences from the D probe.

Initial targets:

## Taskflow

Pinned R0.1 reference:

- commit: `bbd7251d577b33a4aeff434ce5f5569b94d4cc48`
- bounded WSQ source: `taskflow/core/wsq.hpp`
- benchmarked type: `tf::BoundedWSQ<std::size_t, LogSize>`
- compiler control: GCC 15.2.0
- primary x86_64 target: `-march=skylake`

Study:

- bounded WSQ;
- unbounded WSQ;
- executor worker-local queue;
- spill path;
- victim selection;
- worker notification.

## Crossbeam

Study:

- owner Worker;
- Stealer;
- dynamic buffer management;
- batch stealing;
- epoch reclamation.

## Rayon

Study:

- JobRef;
- StackJob;
- worker registry;
- work finding;
- sleep/wake protocol.

## Tokio

Study:

- bounded local queue;
- batch stealing;
- searching-worker limit;
- LIFO/direct-execution slot.
