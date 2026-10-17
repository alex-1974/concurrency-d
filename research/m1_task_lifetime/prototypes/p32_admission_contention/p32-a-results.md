# P32-A — P31 native XPS retry classification (2026-10-15)

**Source:** immutable user-provided `concurrency-p31-xps-20261015T185755Z.tar.gz`, SHA-256 `f5d60e71775fe7a2af88fff345dbc0d333786b3c61f2caa490ade3385bc9900a`, originally recorded at commit `500a58c7cc06928bb2d46736b3f338ed219a758a`. The data were extracted and analyzed independently of the original P31 summary, with `attempts - accepted` as the aggregate producer retry count. No new native benchmark was executed.

All 324 raw records are present; the 243 measured records form nine rounds × 27 profiles. Exactly **227/243 measured records have attempts == accepted**, and only **16/243** contain any extra attempts. All **27 mode/work/producer profiles have median retries of zero** across nine rounds. Some outliers have high counts (for example shared_atomic/m0/2 producers has a maximum of 2,581, shared_atomic/deferred/4 producers has a maximum of 774), so retry absence is **not** a universal property.

In the minimal-work family, the median is zero for each ownership mode at each producer count:

| owner | 1p retries (median) | 2p retries (median) | 4p retries (median) | submission median ms: 1p / 2p / 4p |
|---|---:|---:|---:|---|
| m0 | 0 | 0 | 0 | 16.415 / 28.916 / 36.070 |
| deferred | 0 | 0 | 0 | 17.017 / 30.380 / 37.200 |
| managed | 0 | 0 | 0 | 18.437 / 32.763 / 37.781 |

**Supported:** most measurements show large multi-producer slowdowns without any caller-visible failed submission. Repeated full-queue admission retries are therefore insufficient to explain the principal pattern.

**Not supported:** absence of failed admissions does not imply absence of mutex waiting, thread scheduling, GC, cache interference, or expensive successful calls. A failed attempt may also reflect owner/retention rejection rather than inbox full, because the P31 aggregate counter lacks rejection-reason classification. Submission phase includes producer launch/join and overlapping execution, not isolated queue latency. These are observational associations, not causal performance measurements.

**Next:** P32-B should instrument a generated copy of the exact pinned M0 scheduler (and compare against untouched M0 with the same work), measuring acquisition waiting separately from critical-section hold, worker inbox operations and submission wrapper costs. Only then may a causal claim be considered. No production or safety-contract changes.

Reproduction with original extracted raw CSV:

```sh
python3 tools/research/m1_p32_classify.py --self-test
python3 tools/research/m1_p32_classify.py --input /path/to/benchmark.csv --min-rounds 9 --json /path/to/p32-a-summary.json
```
