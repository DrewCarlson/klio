# Four campaigns: concurrency correctness + the three performance fronts

Standing after the library-100 campaign (see `plans/census-gates-and-red-mass.md`
B1–B33): every library census suite is at zero, the compose_plugin gate holds
its 1375 baseline, and the native channel machinery is deleted. What remains
red anywhere in the project is one family of cross-thread compose tests, and
the three measured-but-open performance fronts. This plan tracks all four to
completion.

Discipline carried over: root-cause only, peel one root at a time, full
battery before every commit, examples + pinned output per interpreter root,
never `zig build` while a background battery runs, census scratch homes as
documented in the census plan.

---

## Task 1 — compose_plugin concurrency group: zero real failures

The last real red in the project. The gate tolerates `MAX_FAILED = 11`
because this family flips run to run:

- `SnapshotStateListTests.concurrent*` / `SnapshotStateMapTests.concurrent*` /
  `SnapshotStateSetTests.concurrent*` (cross-thread global-snapshot
  modification: writer threads mutate while the main thread applies)
- `RecomposerTests.validatePotentialDeadlock`
- `PausableCompositionTests.resumeOnBackgroundThread` /
  `markInvalidFromBackgroundThread`

The itest's own baseline comment records the instability as real tracked open
work, not test noise: the flip lives in klio's MVCC snapshot machinery
(upstream `Snapshot.kt` runs interpreted — see the snapshot-core port memory)
and/or the pump/worker cross-thread handoff.

Work items:
- [ ] Measure the per-test flip rate SOLO (each class run N times alone) to
      split "fails deterministically" from "races under any load" from
      "races only under 8-way census load".
- [ ] Root-cause the deterministic/solo-racing subset first; peel one
      mechanism at a time (suspects: snapshot pinning/advance vs the
      interpreter's cross-thread value visibility, `SpinMutex` fairness,
      worker-pump mailbox ordering, `KLIO_SYNC_RESUME` default).
- [ ] Each interpreter root ships an example + pinned output.
- [ ] Exit: the concurrency classes pass 10/10 consecutive SOLO gate runs;
      `MAX_FAILED` lowered to the new honest ceiling (target 0, and the
      baseline expect tightened accordingly).
- [ ] Verify whether the 5 standing corpus compose load-flakes
      (compose_foundation/material3/material3_text/multiwindow/window under
      `--jobs 4`) share the root; they are contention-sensitivity of the same
      machinery by hypothesis. If they fall, pin them green in the corpus
      run; if not, they move to task 2 (throughput) or get their own root
      entry here.

## Task 2 — compose suite wall time

The plugin gate takes minutes; every compose iteration pays it. The perf
memory (`klio-compose-suite-perf`) already established:
- The wall floor is compute-heavy classes run interpreted ~300x native
  (`SlotTableBuilderTests.oneRectBenchmarkSimulation` repeat(10000),
  `SlotTableTests` 138 pure-compute tests).
- Loop JIT does NOT help this shape (378s vs 326s measured), and `klio test`
  forces JIT off anyway.
- 8-way CPU contention inflates per-class walls 3-8x.
- Lowering the runTest dispatch cap is HARMFUL (teardown-deadlock hangs).
- OPEN QUESTION pinned: profile whether `buildSubTable` is an O(n^2)
  pathology or genuine cost.

Work items:
- [ ] Profile the heavy classes (KLIO_PROF on the ReleaseSafe harness — never
      the Debug one) and answer the buildSubTable question first.
- [ ] Attack the top interpreter frames the profile names (dispatch, field
      access, allocation — whatever actually dominates), measure after each
      change on the SAME solo class before touching the suite.
- [ ] Exit: full solo `itest-compose_plugin_commontest` wall time halved from
      the current measured baseline (record it first), with the gate still at
      its pass baseline.

## Task 3 — Value layout stage 5b (measure-first)

The value-layout campaign shrank `Value` 56B -> 40B; stage 5b (toward 16B
boxing) is pinned open with a measure-first discipline: the interpreter is
compute-bound, so layout wins multiply everything, but the last attempt
recorded measured-negative roads (see `klio-static-dispatch-bake` /
`klio-value-layout-campaign` memories for the traps).

Work items:
- [ ] Re-measure the standing baseline (rangebench + a compose heavy + the
      stdlib sweep wall) on the CURRENT tree before any change.
- [ ] Prototype the 5b boxing step behind a build option if the change is
      structural; measure each step against the recorded baseline; keep only
      measured-positive steps.
- [ ] Exit: either a landed, measured-positive layout step with the full
      battery green, or a recorded disproof in the value-layout plan closing
      stage 5b with numbers.

## Task 4 — C transpiler speedup (inline hot-view sub-ABI)

The transpiler is at 293/293 corpus byte-parity but measured perf-NEUTRAL
(rangebench RF 14.44 vs 14.55 JIT-off). The speedup campaign (inline
hot-view sub-ABI) is pinned open in the transpiler plan. Traps recorded:
ids need the PINNED image artifact (bakes are not cross-process id-stable),
the 256MB runCli initial-thread stack, `KLIO_NATIVE_TRACE` is the engagement
oracle.

Work items:
- [ ] Re-read the transpiler plan's speedup design; confirm the sub-ABI
      surface against the current Value layout (task 3 may change it — run
      task 4 AFTER task 3 settles, or pin the layout first).
- [ ] Implement the inline hot-view sub-ABI; verify engagement with
      KLIO_NATIVE_TRACE; hold 293/293 byte-parity.
- [ ] Exit: a measured speedup on rangebench (target: beat interpreted
      JIT-off by a recorded factor, not neutrality), corpus parity intact,
      full battery green.

---

## Running log

- 2026-08-22: plan written. Task 1 started.
