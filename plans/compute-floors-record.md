# Named compute floors — evidence record and campaign seed

`open-campaigns.md` closes the perf era and asks for NEW profile evidence
before any interpreter-perf campaign reopens. This document is that
record: tests with a fixed input and a measured wall that today only
survive under generous caps. Each is a target with a reproducible
harness command; none is a correctness defect.

Parent plan: `green-main-backlog.md`. Harness practice: `BENCHMARKS.md`;
profiling: `KLIO_PROF` (`docs/development/debugging.md`); the perf-era
verdicts that bound what a per-op lever can still buy:
`interpreter-native-floor-campaign.md`, `interpreter-shared-op-campaign.md`.

## The floors (ReleaseSafe harness unless noted; 4 cores)

| Case | Wall | Cap it lives under | Command |
|------|------|--------------------|---------|
| `LocalDateTest.fromEpochDays` (kotlinx-datetime) | 190 s alone | `KLIO_TEST_WALL_CAP_FOR=…=900`, child 1000 s | `KLIO_ITEST_BIN=zig-out/bin/klio-harness KLIO_CENSUS_TIMES=1 zig-out/bin/klio-census datetime` |
| `LocalDateTest.toEpochDays` | 114 s alone | same | same |
| `JsonUnicodeTest.testRandomEscapeSequences` (json census) | ~195 s | 900 s | `… klio-census serialization_json` |
| `JsonHugeDataSerializationTest.test` | ~ (split child) | 900 s | same |
| `RecomposerTests.validatePotentialDeadlock` (plugin gate, ReleaseFast) | ~590-750 s | 900 s; baseline 1385 tolerates it | `zig build itest-compose_plugin_commontest` |
| `SnapshotStateListTests.concurrentMixingWriteApply_addAll_clear`, `SnapshotStateSetTests.concurrentMixingWriteApply_add` | load flakes on 4 vCPU | tolerated by `MAX_FAILED` | same |
| androidx `ScatterMapTest`, `OrderedScatterSetTest`, `SieveCacheTest` | the compute-heavy tail; 180 s per-file base cap | 180 s ×4 on Debug | `zig build itest-androidx_collection_commontest` |
| `differential` (kotlinx-pack examples in two load modes, in-process) | ~17 min | shard weight 36 | `zig build itest-differential -Dharness-optimize=ReleaseSafe` |
| stdlib `DeepRecursiveTest.testBadClass` | ~150 s (recorded in `verification-speed-plan.md`) | 300 s default | sweep `--filter DeepRecursive` |

CI context: with the ReleaseSafe harness every shard finishes in 6-26
minutes (`ci-green.md`); these floors set the slowest shards and the caps
that keep them green.

## Campaign rule

Profile before touching anything: `KLIO_PROF` on the single case, then
classify — (a) a per-op cost with a named emitter (the perf era's
verdicts say most of this is closed), (b) an algorithmic pathology in the
interpreter's handling of the shape (the string-runtime quadratics of the
serialization campaign were this class and paid 10x), or (c) genuine
interpreted compute (the suite-wall verdict), in which case the record
stands and the cap is the answer. Only (b) opens a fix; (a) needs the
profile to name a NEW emitter.

- [ ] `fromEpochDays` / `toEpochDays`: profile; the epoch-day arithmetic
      is a tight Long loop — check whether the loop JIT engages
      (`KLIO_NATIVE_TRACE`, `KLIO_JIT`)
- [ ] `testRandomEscapeSequences`: profile; the serialization campaign's
      string fixes moved it from 195 s to the current wall — see whether
      a StringBuilder or escape path remains quadratic
- [ ] `validatePotentialDeadlock`: profile; recomposition churn — compare
      against the suite-wall verdict before assuming a lever exists
- [ ] the androidx tail: profile one file; hash-map probing in
      interpreted code — likely (c)
- [ ] `differential`: it is two full corpus runs; the only lever is
      base-image reuse across load modes (`LAZY-IMAGE.md`)

## Log

- 2026-09-05: opened as the evidence record from the CI campaign.
