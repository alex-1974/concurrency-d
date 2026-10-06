# Repository Engineering Context

This repository contains `concurrency-d`, a general-purpose high-performance
concurrency and task-execution library for D.

The repository is currently research-first.

Before changing architecture, public API, memory model, scheduling semantics,
threading behaviour, safety guarantees, testing, CI, release configuration,
repository structure, or toolchain policy:

1. inspect the current repository state and documentation;
2. preserve existing research and benchmark evidence;
3. do not promote research hypotheses to public contracts without evidence;
4. keep performance comparisons semantically fair;
5. prefer D-native specialization and safety mechanisms over mechanical ports
   of C++ or Rust implementations;
6. keep unsafe concurrency primitives inside the smallest reviewable boundary;
7. measure DMD correctness and LDC optimized performance explicitly.

Performance is a primary design requirement, but faster code with weaker
semantics is not an optimization.
