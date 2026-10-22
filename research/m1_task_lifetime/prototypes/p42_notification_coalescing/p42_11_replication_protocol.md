# P42.11 — independent-session replication plan

P42.10 measured 72 native XPS rows at 131072 tasks/run. Paired median deltas: 1/1 −2.78%, 2/2 +0.13%, 4/4 −5.81%. The 4/4 session medians were −11.24%, −6.65%, **+6.36%**: the sign changed. This is **not** evidence of a stable general win.

The P42.11 native runner executes **six** alternating-order sessions, four pairs per 1/1, 2/2 and 4/4 configuration: **144 measured rows**; warmups remain separate. Output directory must not exist. Wall clock start/end timestamps and compiler, source hashes, binary hashes, CPU and platform are recorded. Run several repetitions on different days with distinct output directories; never concatenate across machine/toolchain/source revisions as if they were a single controlled trial.

Analysis: group by session/configuration and compute per-pair conditional/baseline elapsed-time ratio, individual-session medians, aggregate medians and directional consistency. Large session-to-session variance is an adverse qualification finding. Record thermal/frequency state externally if reliable sensors exist. Bench numbers cannot establish tail wake latency or power use.

**Unfinished P42.11 dimensions:** task cost variants and idle-to-active wake latency require independently validated, semantically matched native consumers. They are **not** claimed implemented in this revision; do not use no-op loops vulnerable to optimizer elimination as synthetic work. No production changes.
