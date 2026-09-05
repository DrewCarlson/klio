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
| `LocalDateTest.fromEpochDays` (kotlinx-datetime) | 113 s census child (was 166; user-method memo) | `KLIO_TEST_WALL_CAP_FOR=…=900`, child 1000 s | `KLIO_ITEST_BIN=zig-out/bin/klio-harness KLIO_CENSUS_TIMES=1 zig-out/bin/klio-census datetime` |
| `LocalDateTest.toEpochDays` | 101 s census child (was 114) | same | same |
| `JsonUnicodeTest.testRandomEscapeSequences` (json census) | 175 s census child; genuine compute | 900 s | `… klio-census serialization_json` |
| `JsonHugeDataSerializationTest.test` | 33 s solo (4 cores); its own census child for scheduling, not for its wall | 900 s | same |
| `RecomposerTests.validatePotentialDeadlock` (plugin gate, ReleaseFast) | 471 s solo (was 547) | 900 s; baseline 1385 tolerates it | `zig build itest-compose_plugin_commontest` |
| `SnapshotStateListTests.concurrentMixingWriteApply_addAll_clear`, `SnapshotStateSetTests.concurrentMixingWriteApply_add` | load flakes on 4 vCPU | tolerated by `MAX_FAILED` | same |
| androidx `ScatterMapTest`, `OrderedScatterSetTest`, `SieveCacheTest` | ScatterMapTest 38 s solo; genuine compute; 180 s per-file base cap | 180 s ×4 on Debug | `zig build itest-androidx_collection_commontest` |
| `differential` (kotlinx-pack examples in two load modes, in-process) | 176 s (ReleaseSafe test binary; the 17 min was a Debug lane) | shard weight 18 | `zig build itest-differential -Dharness-optimize=ReleaseSafe` |
| stdlib `DeepRecursiveTest.testBadClass` | ~42 s today under the sampler (was ~150 s when `verification-speed-plan.md` recorded it) | 300 s default | sweep `--filter DeepRecursive` |

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

- [x] `fromEpochDays`: VERDICT (b) then (a), 2026-09-05. Profile:
      `memset` 11.3%, `classHasUserMethod` 6.3%, `eqlBytes` 5.0%,
      allocSmall/freeSmall ~3%. `classHasUserMethod` (asked on every
      builtin member call of a data/value/object instance, here
      `assertEquals`' `equals`) had no precomputed `hierarchy_methods` set
      for the pack's `LocalDate` and walked the hierarchy per call with a
      fresh hash map and a LINEAR scan of every module class per hop.
      Fixed: a (class, method) memo keyed by the dispatch generation and
      an index lookup per hop (`builtin_members.zig`). Wall 166 s -> 113 s
      (census child, 4 cores). What remains: `memset` 12% = allocation
      zero-fill (`allocBytesWithAlignment`), fused-runner register
      windows, and free poisoning — per-op costs the perf era already
      priced; `runFrameExec`/`fusedInst`/`getIndex` are the interpreter
      itself. Genuine compute from here.
- [x] `toEpochDays`: 114 s -> 101 s after the memo (fewer `equals` calls
      per iteration than its sibling: the loop compares Longs). Same
      verdict: genuine interpreted compute from here.
- [x] `JsonUnicodeTest.testRandomEscapeSequences`: VERDICT (c), 2026-09-05.
      175 s (census child), 181 s under the sampler: `runFrameExec` 11.5%,
      `eqlBytes` 3.8% (hash-map hits on name keys), `execInst`,
      `runFlatLoop`, `deinit`, `memset` 1.8%, `callMemberInnerStatic`,
      `afterStep`, `write`, `newWithCaptures` — a flat interpreter
      profile with no quadratic string path left (the serialization
      campaign's cursor/memo fixes took the quadratics). 10,000 strings
      of up to 2,047 chars encoded and decoded: genuine interpreted
      compute; the 900 s cap stands.
- [x] `RecomposerTests.validatePotentialDeadlock`: profile 2026-09-05 (770 s
      under the sampler on 4 cores, ReleaseSafe): `memset` 11.5%
      (allocation zero-fill + register windows), `runFrameExec` 4.5%,
      `eqlBytes` 3.4% + `getIndex` 3.1% (name-keyed hash probes on
      dispatch), libc 2.6%, `allocLockedOne`/`allocSmall`/`freeSmall`
      ~4%, `putAssumeCapacityNoClobberContext` 1.4% + `collectClassClosure`
      1.3% — the one non-interpreter pair. VERDICT (b) for that share,
      fixed 2026-09-05: `extensionFnFallback` asked `enclosingOwnerSet`
      on every extension call not served by the inline cache (any call
      with a member-extension candidate is never cached), and the set was
      rebuilt per call — a supertype-closure walk of every enclosing
      `this` and every frame receiver plus a fresh hash map of every
      name — so its cost grew with the nesting depth of the composition.
      The set is now the chain's class identities probing per-class
      memoized closure-name sets (nothing allocated per call). Solo on 4
      cores, gate env, ReleaseFast: 547 s → 471 s (before measured twice
      on both core sets: 547/547; a first cut that cached the whole set
      per chain signature measured 631 s — chain signatures vary with
      recursion depth, so it missed and paid page-allocator churn).
      The remainder is (c): interpreted recomposition churn.
- [x] `JsonHugeDataSerializationTest.test`: VERDICT (a), 2026-09-05. 33 s
      alone under the sampler on 4 cores (ReleaseSafe): `memset` 21%, of
      which 62% is the allocator's zero-fill of fresh blocks
      (`allocBytesWithAlignment`) and 18% the free-path scrub — the test
      builds and re-parses one huge document, so it is allocation volume
      through the shared allocator, an allocator-policy lever, not a
      pathology in the path; `runFrameExec` 5.4%, `snapshotRange` 4.7%
      (string cursor snapshots), `eqlBytes` 4.1%. It is a separate census
      child because the batched json directory child would otherwise
      carry it, not because it nears a cap.
- [x] `SnapshotStateListTests.concurrentMixingWriteApply_addAll_clear` /
      `SnapshotStateSetTests.concurrentMixingWriteApply_add`: VERDICT
      scheduling, not compute, 2026-09-05. They pass solo and in the local
      battery (compose_plugin 1390/0 at 801c5eac); they fell only on the
      4-vCPU runner under the gate's full load (`ci-green.md`, third run),
      which is why the gate baseline is 1385 = 1390 − MAX_FAILED 5. No
      profile lever: the wall is the runner's contention, and the
      interpreter work is the ordinary snapshot apply path.
- [x] androidx `ScatterMapTest`: VERDICT (c), 2026-09-05. 38 s alone under
      the sampler (4 cores); profile is the interpreter itself
      (`runFrameExec` 9.6%, `memset` 6.9%, `execInst`, `allocLockedOne`,
      `eqlBytes` 2.5%, `invokeVirtualMember`), no dominant user frame and
      no pathological helper. Genuine interpreted compute; the 180 s
      per-file cap stands.
- [x] stdlib `DeepRecursiveTest`: VERDICT (c), 2026-09-05. 42 s under the
      sampler: libc (memcpy/malloc) 12.7%, `memset` 11.8%,
      `runFrameExec`, `allocLockedOne`, the minor GC (`sweepMinor`,
      `gcMarkFrameRegs`, `shade`) — deep recursion is frame-allocation
      churn, per-op costs already priced by the perf era. Genuine
      interpreted compute.
- [x] `differential`: VERDICT (c) by construction, 2026-09-05. Run directly
      as its test binary on the ReleaseSafe universe it takes 176 s (the
      17 min in the record was a Debug lane); it is every kotlinx-pack
      example run in two load modes, the sum of the corpus programs'
      own walls, and the in-process binary installs no sampler. The
      only lever is base-image reuse across load modes (`LAZY-IMAGE.md`),
      a design item, not a pathology. Shard weight corrected to 18.

## Log

- 2026-09-05: opened as the evidence record from the CI campaign.
