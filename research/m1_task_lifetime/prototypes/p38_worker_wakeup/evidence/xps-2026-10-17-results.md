# P38 XPS — complete evidence 2026-10-17

SHA-256: db96c8b4ab588c2d804b4b35ce4643d2f1859b66244073d35f9ec9c4ae307fc4 (matches external receipt).
Native Git HEAD: dd2d8892a79ea01a668a26d4b8752183b30f6a9d.
Three complete rotated sessions; each arm (original/null/timed) contains 729 measured and 243 warmup rows. All nine session validator receipts PASS (P31, P38 paired including P37 projection, P34 three-arm). One unresolved queue timing interval in session 2 (clock granularity). Native worktree was dirty.

Median worker wait entries per 8192 tasks: 1 producer deferred null/timed 3342/3330; managed 3427/3512; 2 producers deferred 6369/6242; managed 6478/6173; 4 producers deferred 6683/6590; managed 6904/6896. All instrumented owned rows satisfy wait_entries == wait_returns <= park_calls. M0 does not emit worker counters.

Median submission durations (ms) for 1/2/4 producers, original/null/timed: Deferred 21.649/27.205/27.357, 43.762/48.739/52.058, 48.850/52.290/54.868; Managed 22.124/26.663/28.046, 42.462/48.547/51.684, 51.898/53.302/55.880.

Worker wait entries are not matched notification-to-wakeup events; notify timestamps include mutex contention and instrumentation cost. Data are diagnostic only: no production optimization conclusion. Next research: separate publish, local-work, shutdown and final-completion notification counts without changing wake-generation semantics. PR #38 Draft; ADR-0001 Proposed.
