# P42.19 — thermally screened independent native E2E replication

**Status:** Research-only protocol fixed **before** a new XPS run.
**Inherited evidence:** P42.18's optimized LDC 1.42.0, same-work 4P/4W
Light/Medium end-to-end candidate showed paired medians −10.41% / −5.92%.
The fully source-pinned capture passed integrity and consumer correctness
checks. However, CPU package temperatures reached 100°C, and the 4P/4W
Light AB/BA medians were −18.17% versus −5.95%. This is a **candidate**,
not proof of sustained general benefit or safe production promotion.

P42.18 complete original evidence and report
[`p42_18_native_xps_review_2026-10-18.md`](p42_18_native_xps_review_2026-10-18.md)
are immutable. **No altered production scheduler**, public API, ownership
contract, DRUNTIME setting, pinned dependencies or measurement consumer.

## Scope: isolate operating-state drift without changing task semantics

Re-run the *same P42.18* four binaries and configurations, generated afresh
from the current exact qualified P42.19 branch HEAD, with the unchanged
`p42_benchmark.d` consumer and historical two-argument conditional
overlay generator:

- 131,072 TaskRefs per run, exactly-once and accepted/completed checks;
- Light: one observable hit increment per task;
- Medium: 32 additional dependent atomic increments per task;
- Target: 4 producers and 4 workers; policy-exposed comparison control:
  1 producer and 1 worker;
- Same LDC `--build=release --force` on *both* policy arms;
- 6 sessions × 6 alternating paired cycles × 2 costs × 2 shapes × 2 arms =
  **288 separate process runs**, **144** baseline/conditional pairs;
- 2 warmups per built binary and worker configuration; all four executables
  and build logs archived and checksummed.

No source change introduces per-worker/TaskRecord timing or notification
instrumentation. The minimally maintained conditional waiter count is **part
of the policy itself**, not extraneous diagnostic overhead. Neither
arm is given exclusive pinning or optimization flags. Both receive exactly
the same start-temperature acceptance rule.

### Fail-closed thermal acquisition: fixed parameters

P42.18 recorded `coretemp-isa-0000 / Package id 0` on the XPS. Instead of
arbitrary `thermal_zone*/temp` values, this replication requires exactly
one `/sys/class/hwmon/hwmon*/name == coretemp` device with a labeled
`Package id 0` temperature input. **No alternate sensor is silently
selected.** A missing/ambiguous sensor means the run is not qualified.

Immediately **before every single baseline or conditional process**:

1. read the chosen CPU package temperature sensor at least twice;
2. require the final **two consecutive readings ≤70,000 m°C**, spaced at
   least **3 seconds** by the guard's configured sleep;
3. keep checking at the same cadence if too warm, with a **600-second
   per-arm cooldown deadline**;
4. after each finished measured process, read the same sensor again;
   **abort at ≥95,000 m°C** post-run;
5. start successive sessions at least **30 seconds** apart in addition
   to the per-arm cooldown gate.

The guard leaves CPU governor, CPU affinity, boost/turbo and fans **untouched**.
Record actual settings, all per-arm pre/post sensor readings with UTC
timestamps, plus preexisting CPU frequency, pressure and broader thermal
snapshots. `m1_p42_thermal_guard.py` tests unique sensor selection, plausible
temperature values, *two cool measurements* and trace completeness/order.
Its negative fixtures reject too-hot admissions, too-hot post-readings,
missing or misordered entries, and missing cooling interval.

**Critical limits:** temperature snapshots before/after processes do
*not* continuously monitor per-core/package heat, guarantee stable CPU
frequencies, prove absence of thermal throttling, or make one day's six
sessions six independent machines. A safety abort deliberately leaves
`run_state.txt` as **INCOMPLETE** and all captured raw files intact. Do
**not** selectively discard a hot pair or substitute a later run into the
same nominal session. The study must be restarted as a **new separate**
output directory if the finite capture aborts. The native runner's Python
parser must validate exact AB/BA order, raw-to-CSV equality and every one of
288 matched run IDs in the thermal audit before marking **COMPLETE**.

### Predeclared decision criteria (replication, not production)

The same primary exploratory P42.18 threshold is retained without looking
at new results:

- 4P/4W **Light:** session-level median paired conditional/baseline
  improvement **≥3%** in at least **5/6** sessions; **no session median
  regression >+2%**.
- **Medium:** report all six session deltas and any regression; a
  persistent positive latency cost or a session median >+2% bars a
  simple broad-performance-benefit claim.
- **Control:** report the 1P/1W paired target/control directions by
  session. The control remains policy-exposed and is **not** a
  thermal-normalization oracle; if the apparent improvement is similar
  in control and target, treat attribution as unqualified.
- **Order sensitivity:** report baseline-first and conditional-first
  4P/4W medians separately. If their difference is **>5 percentage
  points**, flag the replication as order-sensitive and do not treat
  the throughput effect as fully stabilized, even if the Light threshold
  otherwise passes.
- **Thermal acceptance:** all 288 processes require two prior cool
  samples and one post sample below the abort bound. A partial,
  overheated or unverified trace is **inconclusive**; its completed
  observations are preserved as evidence, not silently censored.

The primary unit for interpretation is the **session block**; the 36
paired invocations within a day are correlated. Report both per-session
and pooled paired deltas descriptively without manufacturing 288
independent replicates or applying task-level confidence intervals.
A favorable independent replication licenses a **separate policy safety,
ownership/lifetime and consumer-benefit review**, not a merge or ADR
acceptance. If the effect reverses/vanishes, retain the contrary evidence
and stop performance promotion.

## Exact-head CI and native XPS run

P42.19 changes only the research tool/script/protocol and adds syntax,
sensor/temperature negative fixtures to the existing DMD 2.111.0 and
LDC 1.41.0 correctness gate. All code-gate jobs must pass on the **exact
current Research HEAD** before the XPS run. The native LDC version
is recorded and may differ from CI. Do not use CI elapsed times as a
native performance signal.

From the dedicated XPS worktree, with a **new nonexistent result path**:

```bash
cd ~/Programmiersprachen/dlang/concurrency-d-p42
git status -sb
git fetch origin
git pull --ff-only origin research/m1-task-lifetime-boundaries

bash tools/research/m1_p42_cool_replication_native.sh \
  "$HOME/Downloads/p42-19-xps-01"

tar -C "$HOME/Downloads" -czf \
  "$HOME/Downloads/p42-19-xps-01.tar.gz" \
  p42-19-xps-01
```

Upload the **entire result directory archive**, including any
`run_state.txt` failure marker, not just `raw/`. Stop and inspect an
INCOMPLETE run before repeating it under a different output directory.
Do not overrun deliberate thermal aborts.

## Repository boundaries

Research branch `research/m1-task-lifetime-boundaries`, grandfathered
PR #38 targeting `develop` remains **Draft**. ADR-0001 is Proposed.
Grandfathered PR #35, historical P42.16/17/18 outputs, canonical M0 code,
`develop`, API surface, workspace documents and all sibling repositories
are not modified. No branch retarget, merge or publication authorized.
