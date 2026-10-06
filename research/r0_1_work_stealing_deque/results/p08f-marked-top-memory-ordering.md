# R0.1 P08f — Marked-Top Memory-Ordering Argument

## Status

Initial memory-model argument.

The marked-top algorithm has a coherent portable ordering argument when
`researchSeqCstBarrier()` is implemented as an actual sequentially-consistent
fence.

The optimized LDC/x86_64 RMW barrier remains a separate architecture-qualified
path and is not yet covered by this language-level fence proof.

This document is therefore a proof obligation / qualification record, not yet
a final portability claim.

## Memory-order mapping

D `core.atomic.MemoryOrder` maps:

- `raw` -> C/C++ relaxed;
- `acq` -> acquire;
- `rel` -> release;
- `seq` -> sequentially consistent.

The portable marked-top argument is expressed using those standard atomic
memory-model concepts.

## Relevant state

The queue contains:

    topState = encoded(top, batchBusy)
    bottom
    buffer[]

The owner is the only thread that modifies bottom through push/pop.

Thieves coordinate removal through topState.

A batch thief temporarily changes:

    (top, idle) -> (top, busy)

before inspecting bottom and reading the batch slots.

It later publishes:

    (top + N, idle)

## Push publication

Owner push performs conceptually:

    buffer[b] = item              relaxed atomic store
    release fence
    bottom = b + 1                release store

A thief loads bottom with acquire ordering before consuming published slots.

If the acquire observes the relevant bottom publication, preceding slot
publication happens-before subsequent slot reads.

## Ordinary steal

Ordinary steal remains based on the established Chase-Lev ordering shape:

    load top
    seq_cst barrier
    load bottom
    read slot
    CAS top

The marked bit adds a fast rejection path but does not permit ordinary steal
to advance top while a batch owns the marked state.

If an ordinary thief observes an old idle state concurrently with a successful
batch idle->busy CAS, its later CAS against the old complete encoded state
fails.

Therefore stale observation of `idle` alone cannot commit a conflicting
single-item removal.

## Batch versus batch

Every batch begins with:

    CAS(topState, (top,idle), (top,busy))

Only one batch thief can succeed for a given encoded top state.

Other batch thieves either:

- observe busy and fail;
- or observe the previous idle state and lose their CAS.

Thus at most one batch owns the marked interval.

## Critical owner versus batch race

Owner pop:

    O1  bottom := bottom - 1       relaxed
    OF  seq_cst fence
    O2  state := load(topState)    relaxed

Batch steal:

    B1  CAS idle -> busy           seq_cst
    BF  seq_cst fence
    B2  bottom := load(bottom)     acquire

The critical question is whether both sides can miss the other's claim and
return overlapping tasks.

### Case A — B1 precedes OF in sequentially-consistent order

The batch busy publication precedes the owner's SC fence.

The owner's later atomic read of topState must observe the relevant SC
modification or a later modification in topState's modification order.

Therefore the owner observes either:

1. `(top,busy)`, in which case it restores its speculative bottom decrement
   and retries; or
2. a later `(top+N,idle)` publication, in which case the batch has already
   completed and the owner evaluates against the new top.

The owner cannot safely commit against the pre-batch top in this ordering.

### Case B — OF precedes B1 in sequentially-consistent order

The owner may observe the old idle top and continue.

However:

    O1 is sequenced-before OF
    OF precedes B1
    B1 is sequenced-before BF
    BF is sequenced-before B2

Hence:

    O1 < OF < B1 < BF < B2

For an atomic write to bottom before one SC fence and an atomic read of bottom
after a later SC fence, the fence ordering requires the later read to observe
that write or a later bottom modification.

Therefore the batch observes the owner's speculative bottom decrement or a
later state.

Its calculated available interval cannot include the task already selected by
the owner at the old bottom.

Thus the P08d0 overlap is excluded in the opposite SC ordering as well.

## Owner busy rollback

If owner pop observes busy:

    bottom = oldBottom

and retries.

The rollback need not publish work to the batch.

If the batch sees the transient decremented bottom, it merely chooses a
smaller conservative batch.

If it sees the restored bottom, it may choose the larger valid batch.

Neither observation permits overlap with a committed owner result because the
owner does not commit a result on the busy path.

## Batch slot lifetime

A successful batch keeps top logically at the old value while busy is set.

Push therefore cannot rely on the future `top + N` while the batch is still
reading those slots.

Possible push observations are:

1. old idle top;
2. busy top;
3. newly published top.

Cases 1 and 2 retain the old top and are conservative for capacity.

The new top is published only after all batch slot reads:

    slot reads
        sequenced-before
    release store(top+N, idle)

`tryPush()` reads topState with acquire ordering.

If it observes the new published top, the release/acquire synchronization
orders the completed batch reads before subsequent reuse of slots made
available by that new top.

Therefore the producer must not overwrite a slot before the batch has
finished reading it.

## Last-item race

For a one-item queue the same owner/batch dichotomy applies.

If the batch busy claim is ordered first, owner pop observes busy or the later
published top and does not independently return the same item.

If the owner fence is ordered first, the batch's post-fence bottom observation
must include the owner's speculative decrement and therefore cannot treat the
same item as available.

Exactly one side can commit the last item.

## Empty and underflow state

The owner may temporarily move bottom into the established modular
underflow representation.

A batch that observes this state classifies it as outside the valid bounded
occupancy interval and publishes the unchanged top back to idle.

This remains conservative.

## Important distinction: portable fence versus x86_64 RMW barrier

The current research helper has two implementations.

Portable fallback:

    atomicFence!(MemoryOrder.seq)()

Optimized LDC/x86_64 path:

    atomicFetchAdd!(MemoryOrder.seq)(fenceWord, 0)

The latter was previously qualified experimentally because optimized
LDC/LLVM lowers it to the desired locked x86_64 barrier instruction.

However, a seq_cst RMW on a separate atomic object is not, at the abstract
C/C++ memory-model level, automatically interchangeable with a seq_cst
thread fence.

Therefore:

- the proof above directly covers the true seq_cst-fence fallback;
- it does not by itself prove the specialized RMW implementation;
- the x86_64 path requires an explicit machine-level TSO/code-generation
  argument;
- this distinction must remain visible in the research record.

## Remaining proof obligations

### P08f1 — x86_64 specialization

Establish that the emitted locked RMW provides the machine-ordering edges used
by the marked-top algorithm for:

- owner bottom store -> topState observation;
- batch busy claim -> bottom observation;
- last-item race;
- batch versus owner overlap.

Verify actual optimized LDC code generation.

### P08f2 — weak-memory target

Qualify the actual-fence fallback on a weakly ordered target or formal model.

Preferred routes:

- ARM64 hardware;
- a litmus/model checker capable of representing the C/C++ atomic relations;
- both, if practical.

### P08f3 — ordering minimization

Only after correctness is established should stronger operations be weakened.

Do not remove or weaken the SC ordering merely because x86_64 tests continue
to pass.

## Current conclusion

The marked-top algorithm has a plausible and internally consistent
language-level proof for the true sequentially-consistent-fence path.

The critical P08d0 overlap is excluded by the two possible SC orderings:

    batch-before-owner  -> owner observes busy/new top

or:

    owner-before-batch  -> batch observes decremented bottom

This is the central correctness property of the design.

The optimized LDC/x86_64 RMW barrier remains architecture-specific research
until separately justified.

## P08f1 — LDC x86_64 specialization

Toolchain:

- LDC 1.41.0
- DMD frontend 2.111.0
- LLVM 19.1.7
- target x86_64
- host CPU Skylake

Stable wrapper symbols were used to prevent the qualification from depending
on D symbol mangling.

### Owner pop

Observed machine ordering:

    store bottom
    lock or [stack], 0
    load topState

The optimized research barrier therefore remains physically between the
speculative bottom decrement and the top/busy observation.

### Batch steal

Observed machine ordering:

    lock cmpxchg topState
    lock or [stack], 0
    load bottom

The successful idle-to-busy claim therefore precedes the locked barrier,
which in turn precedes the availability observation.

### Ordinary steal

Observed:

    load topState
    lock or [stack], 0
    load bottom
    ...
    lock cmpxchg topState

The established single-steal ordering is retained.

### P08f1 conclusion

For LDC 1.41 / LLVM 19 on x86_64 the specialized RMW barrier preserves the
required machine instruction order for the marked-top algorithm.

This is an architecture/compiler qualification, not a portable language-level
equivalence claim between an SC RMW on an unrelated atomic and an SC fence.

## P08f2 — AArch64 portable-fence lowering

The candidate was cross-compiled directly for:

    aarch64-linux-gnu

using LDC 1.41 / LLVM 19.

### Wrapper ordering

Owner pop emits structurally:

    STR bottom
    BL researchSeqCstBarrier
    LDR topState

Batch steal emits:

    LDAXR/STLXR topState
    BL researchSeqCstBarrier
    LDAR bottom

Ordinary steal emits:

    LDAR topState
    BL researchSeqCstBarrier
    LDAR bottom
    ...
    LDAXR/STLXR topState

Thus compiler scheduling preserves the required program-order structure
around the explicit helper call.

### Barrier helper LLVM IR

Direct compilation of the candidate module shows:

    define void researchSeqCstBarrier(...) {
        fence seq_cst
        ret void
    }

Therefore the portable non-x86 path retains a true sequentially-consistent
LLVM fence rather than the x86-specific RMW substitute.

### Barrier helper AArch64 machine code

The same helper lowers to:

    dmb ish
    ret

The core.atomic SC-fence wrappers emitted in the same module likewise contain
`dmb ish`.

### P08f2 conclusion

The portable path now has a complete observed lowering chain:

    D atomicFence!(MemoryOrder.seq)
        ->
    LLVM fence seq_cst
        ->
    AArch64 dmb ish

Together with the wrapper ordering this establishes the expected code-generation
shape for the marked-top proof obligations on AArch64.

This is still code-generation evidence rather than execution on AArch64
hardware.

## Qualification state after P08f2

Established:

- portable language-level SC-fence argument;
- LDC/x86_64 specialized machine ordering;
- LDC/AArch64 true-SC-fence lowering;
- acquire/release top/bottom operations lower to the expected AArch64
  acquire/release instruction families.

Still open:

1. formal litmus/model validation of the forbidden owner/batch overlap;
2. execution on weakly ordered hardware when available;
3. 63-bit versus full-64-bit counter-domain decision.

The next research step is P08f3: encode the minimum owner/batch interaction as
a memory-model litmus and ask whether the forbidden outcome can occur.

## Subsequent qualification

P08f3 completed the formal owner/batch overlap check using GenMC v0.19.0 under
RC11.

The SC-fence model was SAFE and a relaxed negative control reproduced the
forbidden owner/batch overlap.

P08g then reused the qualified post-busy-claim ordering while replacing the
63-bit encoded marker with a full-64-bit distance-marked state.

A separate GenMC positive/negative-control pair qualified the acquire
observation required to distinguish the Full64 busy representation safely.

See `p08g-full64-distance-marked-top.md` for the resulting architecture and
performance comparison.
