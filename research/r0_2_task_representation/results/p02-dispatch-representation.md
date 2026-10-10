# R0.2 P02 — Dispatch representation

Status: PASS

## Decision

The leading general-purpose representation is:

```d
struct TaskRef
{
    shared(TaskRecord)* ptr;
}
```

with the execute target stored in immutable-after-publication TaskRecord
metadata.

The queue element remains exactly one machine word.

The scheduler can load the execute target from shared record metadata with
`core.atomic.atomicLoad` and invoke it from `@safe @nogc nothrow` code.

## Candidate outcomes

### Pointer-only + record execute function

Status: SELECTED GENERAL BASELINE.

Properties:

- TaskRef size: 8 bytes;
- open-world task types;
- one dependent metadata load before indirect dispatch;
- same queue representation established by R0.1 P10;
- shared metadata loads compile and run safely on DMD 2.111, LDC 1.41 and
  native AArch64.

### Pointer + execute function

Status: BLOCKED / NOT SELECTED.

Layout:

```text
size  = 16
align = 8
```

The form compiles as a containers-d 0.2.0 queue element, but real optimized
runtime transport failed under LDC:

- x86_64: SIGSEGV;
- native AArch64: SIGBUS.

An explicitly `align(16)` equivalent passes on DMD, LDC/x86_64 and
LDC/AArch64, strongly identifying insufficient 16-byte atomic alignment as
the cause.

Even if a future containers-d release strengthens this contract, the larger
TaskRef must still overcome the R0.1 measured queue-transfer disadvantage of a
16-byte element.

It therefore does not proceed as the R0.2 production candidate.

### Pointer-only + record discriminator

Status: SPECIALIZATION ONLY.

The queue handle remains 8 bytes and LDC can optimize a small closed-world
switch very effectively.

However, a fixed discriminator is not a complete representation for a
general-purpose task library with an open set of user task types. Turning it
into a generic registry/table would reintroduce an indirect target lookup and
additional registry semantics.

It therefore remains a possible later optimization for a bounded internal task
family, not the general TaskRef contract.

## P02 pure dispatch observations

The pure dispatch probe used:

- homogeneous one-type stream;
- alternating two-type stream;
- deterministic mixed four-type stream;
- zero-round tiny work;
- 16-round non-trivial work.

### LDC 1.41 hosted x86_64

Representative mixed-four results:

```text
rounds=0
    pointer-only       10.210 ns/task
    pointer+execute     7.556 ns/task
    record-tag          5.490 ns/task

rounds=16
    pointer-only       22.661 ns/task
    pointer+execute    21.979 ns/task
    record-tag         22.616 ns/task
```

The larger direct-reference form can reduce pure indirect-dispatch cost, but
this probe excludes its larger queue-transfer cost.

### DMD 2.111 hosted x86_64

DMD showed a materially different code-shape preference. In mixed-four tiny
work, pointer-only was faster than both alternatives.

This reinforces the project rule that compiler-specific transformation
behavior must be measured rather than inferred.

### Native AArch64 / LDC 1.41 / Neoverse-N2

Record-tag dispatch was consistently faster in the synthetic closed-world
kernel.

This does not override the genericity constraint described above.

## P02d equal-size queue + dispatch

P02d compares only the two 8-byte TaskRef forms through the real production
WorkStealingDeque, with identical queue representation.

### LDC 1.41 hosted x86_64

```text
homogeneous rounds=0
    pointer-only    8.911 ns/task
    record-tag      8.766 ns/task

homogeneous rounds=16
    pointer-only   17.112 ns/task
    record-tag     17.564 ns/task

mixed4 rounds=0
    pointer-only    9.119 ns/task
    record-tag      8.863 ns/task

mixed4 rounds=16
    pointer-only   18.053 ns/task
    record-tag     19.540 ns/task
```

For non-trivial work, pointer-only record-function dispatch wins on this LDC
x86_64 host.

### DMD 2.111 hosted x86_64

Pointer-only won all P02d cases.

### Native AArch64 / LDC 1.41

```text
homogeneous rounds=0
    pointer-only   15.230 ns/task
    record-tag     13.864 ns/task

homogeneous rounds=16
    pointer-only   21.701 ns/task
    record-tag     20.958 ns/task

mixed4 rounds=0
    pointer-only   15.208 ns/task
    record-tag     13.836 ns/task

mixed4 rounds=16
    pointer-only   24.711 ns/task
    record-tag     23.868 ns/task
```

The closed-world tag remains attractive on this architecture, but its semantic
scope is narrower than the general scheduler requirement.

## Safe shared metadata result

P02e proved that a record containing:

```d
ExecuteFn execute;
ulong payload;
ubyte kind;
```

can expose all three fields through `atomicLoad!(MemoryOrder.raw)` from a
shared TaskRecord.

Qualified callable path:

```text
@safe @nogc nothrow
```

on:

- DMD 2.111 / x86_64;
- LDC 1.41 / x86_64;
- LDC 1.41 / native AArch64.

This removes the need for the research-only shared-to-unshared casts used in
the first P02 timing probe.

## P02 conclusion

No larger TaskRef demonstrated a sufficient production reason to replace the
8-byte pointer-only contract.

Selected direction entering P03:

```text
TaskRef:
    8-byte non-owning shared(TaskRecord)*

TaskRecord hot metadata:
    execute target stored in record
    initialized before publication
    read through safe shared atomic load
```

A compact discriminator may be revisited only as an internal specialization
after the general scheduler exists.

## Remaining performance qualification

Hosted x86_64 values are not the final XPS performance baseline.

Before R0.2 closes, the selected representation will still receive local
native-x86_64 scheduler-neighborhood qualification on the project XPS and
native AArch64 coverage.

## Next gate

P03 — TaskRecord header and cache locality.
