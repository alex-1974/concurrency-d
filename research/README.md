# Research

Research is retained separately from production API.

Initial reference implementations include:

- Taskflow;
- Rayon / Crossbeam;
- oneTBB;
- Tokio scheduler mechanisms;
- D `std.parallelism`;
- D `Fiber`;
- vibe-core.

Initial experimental sequence:

1. work-stealing queue;
2. task representation;
3. scheduler;
4. parking/wake-up;
5. allocation/recycling.

Research conclusions may be:

- adopt;
- adapt;
- benchmark/reference only;
- defer;
- reject.

External implementations are evidence, not the specification.
