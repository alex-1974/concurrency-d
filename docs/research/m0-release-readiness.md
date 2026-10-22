# M0 / v0.1.0 release readiness

Date: 2026-10-22. Status: **NOT RELEASE READY**.
Source: develop `7af4409a2e09a303dfbc6c54033d28c92eb67581`, M1 research
`97578c8c1e8354539929292a5e8e7ec2861cf508`, and
[release gate #16](https://github.com/alex-1974/concurrency-d/issues/16).
The research branch retains unchanged production sources. This is a code/evidence
ledger, not a declaration that open issues or releases are complete.

| Release requirement | Current evidence | Remaining acceptance work |
|---|---|---|
| Explicit executor and external admission | Internal OwnedTaskExecutor/SubmissionWorkerPool; bounded ingress and record budget; external producer tests | Export a reviewed facade; document exact admission/copy/capture contract |
| Typed owned tasks/results | Independent ResultCell and TaskHandle, typed/void result and task Exception checks, retention-before-publish | Public-only consumer; enforce supported F/R constraints; public diagnostics |
| Shutdown and errors | Admission/close serialization; idempotent external close in normal paths; returned-marker reclamation | Resolve native start/join uncertainty; distinguish joined from unknown; reject same-worker close; specify fatal Error behavior |
| Parking/wakeup | Portable condition/generation baseline; full foreign-victim scan; P41/P42 race models and native fixtures | No finite test establishes all-schedule liveness; audit assumptions; preserve local/close/final notifications |
| Conditional candidate | P42.18/19 native end-to-end benefit; P42.20 local DMD/LDC races, ownership and handoff | Pinned CI PASS at 97578c8 (receipt below); focused review, idle/burst tail evidence as required by promotion criteria, and explicit selective adoption decision |
| Compiler/architecture validation | Existing CI config DMD 2.111.0, LDC 1.41.0; native ARM64 baseline job; local new checks DMD 2.111.0/LDC 1.42.0 | Record actual outcomes at the final public API/release commit; research CI is not the public release gate |
| Public consumer smoke | P42.20 CPU and controller-thread completion tests use research/internal modules | Independent package importing only the exported public module |
| Performance baseline | Extensive original M0 and research XPS evidence, semantically matched conditional A/B | Public-path representative baseline with no unexplained regression; no general C++/Rust parity claim |
| Public documentation/package | DUB library with containers-d 0.2.0; public module intentionally empty; no LICENSE/COPYING file or DUB license field found | Public Ddoc/examples, version/tag/package checks; choose and record the project license before publication |

## Immediate work order

1. Use the pinned P42.20 receipt below in the focused promotion/contract review. Keep PR #38 Draft.
2. Review the [proposed public contract](m0-public-executor-contract.md), especially
   native uncertainty, copyable F/R, root lifetime and same-worker waits.
3. Implement and qualify the chosen lifecycle boundary in a narrowly isolated
   change. Existing source-pinned research must remain reproducible; changing
   a pin requires re-audit, not a mechanical hash update.
4. Add the small public facade and independent consumer. Keep TaskScope and
   cancellation outside v0.1; do not expose implementation counters by accident.
5. Qualify the final public path, synchronize release docs/metadata and record
   acceptance against #16. Only then prepare a version/tag/package publication.

## Separate promotion from release

Conditional changes publication notification policy. It does not solve arbitrary
borrowed captures, native lifecycle ambiguity, safe TaskScope, same-pool deadlocks,
fairness or task cancellation. A narrow scheduler improvement and the first
usable executor release are separate decisions. PR #38 contains extensive
historical research and must not be merged wholesale merely because CI is green.

## P42.20 pinned CI receipt

Code commit `97578c8c1e8354539929292a5e8e7ec2861cf508` passed the full existing
M1 workflow with the two new P42.20 gates and all regression steps:

- [push run #39734514625](https://github.com/alex-1974/concurrency-d/actions/runs/39734514625): SUCCESS;
- [pull-request run #39734520083](https://github.com/alex-1974/concurrency-d/actions/runs/39734520083): SUCCESS.

Both runs include DMD 2.111.0 and LDC 1.41.0. The new P42.20 controlled-race,
return-boundary, real-owned, GC-graph and consumer-handoff steps pass; the LDC
qualification runner additionally exercises assertions-on -O3. This is a
research-code qualification receipt, not completion of the public release gate,
ARM64 qualification of the new API, a new performance result or native-failure
recovery proof. PR #38 remains Draft and no production policy has changed.
