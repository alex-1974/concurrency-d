# P42.5 adversarial schedule qualification

The source-pinned P42.5 scenario oracle (`tools/research/m1_p42_adversarial_scenarios.py`) composes the bounded P42.2 ticket/search/park model with P42.3 owner-deque handoff. It adds six named checks:

1. Publish before worker ticket capture.
2. Publish after empty search but before mutex-held park check.
3. Two workers enrolled in wait, followed by two producer publications.
4. Inbox batch handoff followed by thief execution.
5. Owner-local completion when the owner wins the local deque.
6. Close during in-flight completion with another worker waiting.

The assertions target concrete reachable states; a missing transition fails immediately and CI executes the script on both baseline compiler jobs (Python model is compiler independent). This is **not a compositionally complete scheduler model**: P42.2 and P42.3 have different state representations, no actual multi-worker deque race is executed, and no operating-system threads, ownership roots, capacity-rejection execution, or fairness proof is furnished.

Checklist items 7 and 8 from P42.4 remain covered separately by P41 repeated-wait testing and earlier bounded-ingress tests, but **not yet integrated into this oracle**. Treat them as open for a unified proof. No notification coalescing implementation or optimization decision is justified by a passing scenario oracle.
