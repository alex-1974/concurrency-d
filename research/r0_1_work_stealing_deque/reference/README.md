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
