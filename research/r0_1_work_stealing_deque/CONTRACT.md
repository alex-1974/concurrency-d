# R0.1 Correctness Contract

## Abstract deque model

A deque contains an ordered sequence of task references.

Exactly one owner may:

- push at the bottom;
- pop at the bottom.

Zero or more thieves may concurrently:

- steal from the top.

## Required properties

### Safety

- a task reference is returned at most once;
- no uninitialized slot is observed;
- no removed slot is observed as a new task;
- queue indices do not cause out-of-bounds access;
- races on the last remaining element resolve to exactly one winner.

### Sequential behaviour

For owner-only operation:

- push followed by pop is LIFO;
- repeated owner pops return most-recently-pushed elements.

For stealing:

- thieves observe work from the opposite end;
- successful steals remove the oldest stealable tasks.

### Concurrent accounting

After all producers/consumers finish:

    submitted == ownerPopped + stolen + remaining

with no duplicates.

### Wraparound

Index wraparound and mask arithmetic must preserve slot selection and
correctness for the supported counter domain.

### Capacity

For bounded variants:

    0 <= size <= capacity

and full detection must not overwrite live entries.

## Memory model

Memory-ordering requirements are part of the algorithm.

Do not strengthen all operations to sequential consistency merely to make
the first implementation appear correct.

Do not weaken reference ordering until the corresponding happens-before
argument is documented.

## Safety boundary

Raw atomic/pointer operations should remain internal.

The eventual reusable surface should be safe to call under its documented
single-owner/multi-thief preconditions.
