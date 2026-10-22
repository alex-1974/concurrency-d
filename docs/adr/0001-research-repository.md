# Research repository separation

Date: 2026-10-22. Status: accepted repository boundary requested by the maintainer.

## Decision

Detailed research lives in
[concurrency-d-research](https://github.com/alex-1974/concurrency-d-research).
Production source, active regression/release validation, maintained parking and
public/internal executor qualification harnesses, examples and concise decisions
remain in concurrency-d. No library dependency on the research companion is
introduced. The exported library archive remains unchanged by the migration.

## Evidence preservation

Initial research commit: `894cfe81bcf41ca88e20a418eb90d6f2de7c83f9`.
[Provenance and exact manifest](https://github.com/alex-1974/concurrency-d-research/blob/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9/PROVENANCE.md).

The import inventories 25 research-bearing branch tips (23 distinct snapshots),
including R0 integration, M1 through P42.20 and public M0 candidate ebce22d.
1,834 imported files / 13,163,288 bytes include immutable historical variants
and a convenient current corpus. File bytes, modes and blob identities are
verified; these counts include duplicate versions in distinct snapshots.

Only research/, docs/research/ and tools/research/ are moved out of the current
production candidate. Previous library commits and branches are retained; no
history rewrite or claim of reduced historical clone size is made. Research
scripts requiring a full source tree use the companion preparation tool to
check out the exact original library commit. A successful snapshot integrity
check does not mean historical experiments or measurements were rerun.

## Candidate implementation evidence

The moved M0 reports remain pinned under
[docs/research](https://github.com/alex-1974/concurrency-d-research/tree/894cfe81bcf41ca88e20a418eb90d6f2de7c83f9/docs/research),
including native lifecycle boundaries, typed/owned tasks, retention reclamation,
submission allocation, parking and public API validation. Current consumer
semantics remain in [the executor guide](../EXECUTOR.md) and active tests.
The split does not approve the pending lifecycle policy, promote conditional
notification, qualify performance or authorize a release.
