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

- 2026-08-22 PERF BATCH 1 (tasks 2+3): the top profile frame of the heavy
  compose classes was memset (15.5% of oneRectBenchmarkSimulation) — Zig
  safety builds 0xAA-fill every `undefined` stack array at its DECLARED
  size, and three hot paths declared multi-KB buffers per call. Fixes:
  leaf-serve coerce buffer moved to a per-depth threadlocal bank; the leaf
  register-bank eager Unit-fill replaced by a wmask read-guard (reads of
  unwritten slots serve the fill value; reclaim builds keep the eager
  fill); two-tier buffers in invokeMethodFuncId (8 before 64 Value slots)
  and the runtime applicability shapes (6 before heap ArgShape). Measured:
  oneRect solo 64-65s -> 61s stable, SnapshotStateList.contains(1000)
  6.0ms -> 5.0ms, empty cross-thread launch 234 -> 214us, withContext
  round-trip 486 -> 424us. memset bucket 15.5% -> 7.8%. Full battery
  green.

- 2026-08-22: plan written. Task 1 started.
- 2026-08-22 flip-rate measurement (5 classes x 3 SOLO runs, itest-exact
  env): the group splits three ways.
  - DETERMINISTIC (3/3): List.concurrentGlobalModifications_addAll,
    List.concurrentMixingWriteApply_addAll_clear / _addAll_removeRange,
    Map.concurrentModificationInGlobal_put_replace,
    Map.concurrentMixingWriteApply_set / _clear,
    Set.concurrentMixingWriteApply_add, Recomposer.validatePotentialDeadlock,
    Pausable.resumeOnBackgroundThread.
  - FLAKY SOLO: Set.concurrentGlobalModification_remove (1/3),
    Recomposer.pausingTheFrameClockStopShouldBlockWithFrameNanos (2/3).
  - LOAD-ONLY (pass 3/3 solo): List.concurrentGlobalModification_add,
    Map.concurrentModificationInGlobal_put_new,
    Pausable.markInvalidFromBackgroundThread, MovableContent/Recomposer
    strays seen in gate runs.
  - Every deterministic failure lands EXACTLY on its cap (30.2s on the
    declared 30s runTest timeout, 10.3s on the 10s env cap, 90.2s on the
    wall cap). These are TIMEOUTS, not lost writes: no assertion failure
    observed anywhere in the group.
- 2026-08-22 microbench (scratchpad/xthread.kt): an EMPTY
  `launch(Dispatchers.Default) {}` costs ~1.5ms; an empty SAME-thread
  launch ~2.2ms; a `withContext(Default)` round-trip ~2.9ms. KLIO_PROF
  shows no sleeping (libc <2%) — the cost is flat interpreted compute:
  string hashing for dispatch-cache keys (`hash`/`hashString`/`mum` ~10%,
  via methodArgSig / memberSiteSig / instanceMethodKeyScoped), string
  equality (`eqlBytes` 4.4%), and the interpreter loop. The GetField site
  cache already serves field reads (mono+poly routes); the residue is the
  breadth of interpreted upstream Job/context machinery per launch.
  CONCLUSION: tasks 1 and 2 share one root — coroutine-op throughput —
  and the fix surface is task-2/3-shaped (shorten or cache the hot
  interpreted paths), NOT a memory-model race. Task 1 keeps two possibly
  genuine correctness items: validatePotentialDeadlock (hang-vs-slow probe
  under 400s wall in flight) and pausingTheFrameClockStopShouldBlockWithFrameNanos
  (frame-clock ordering, flaky 2/3).
- 2026-08-22 ROOT QUANTIFIED (ReleaseSafe harness this time — the earlier
  Debug numbers were 6x inflated): empty cross-thread launch 234us,
  same-thread 350us, withContext(Default) round-trip 486us — launches are
  NOT the problem. The killer is the VERIFY phase of the Snapshot tests:
  `SnapshotStateList.contains` at size 1000 costs 6.0ms/call (vs 27us on a
  plain klio ArrayList — 220x); the addAll test's 50x1000-contains verify
  loop alone needs ~300s against its 30s cap. Direct PersistentVector
  numbers (scratchpad/pvbench.kt): indexed get 9us, iterator step 8.2us,
  contains 9.6ms (≈19us/element scanned), snapshot `readable` read 27us.
  The per-element cost is INTERPRETED-CALL OVERHEAD (~6us/call across
  hasNext/next/equals), not instruction-walk: the bytecode tier moves it
  only 6% (KLIO_BC=0 A/B), CallMemberOrGlobal/callNamedOverload are COLD
  in the loop (64 CMGs total), and the profile is flat — libc (malloc/
  memcpy family) ~16-18%, runFrameExec ~11%, memset ~4% (callNamedOverload
  stack-buffer init), eqlBytes ~4% (name-keyed cache checks), everything
  else <3%. No single lever: the campaign target is per-call overhead
  (frame open/close, register-file init, name-identity string work), i.e.
  exactly tasks 2+3. Native shadow implementations of the vendored
  PersistentVector were considered and REJECTED on the same grounds the
  native channels were deleted.
- 2026-08-22 CONTAMINATION FIXED: two-part root. (1) The wall-cap abort
  unwound with an interpreter-level error that SKIPPED Kotlin catch/finally,
  so a capped test's infra teardown (compositionTest disposing its
  recomposer/composition, runTest cancelling children) never ran — its
  globally registered snapshot observers and live compositions poisoned
  every later test in the class. The wall cap is now STAGED: first fire
  throws a catchable kotlin.RuntimeException (finally/teardown runs) with a
  20s unwind budget; a second expiry hard-aborts + abandons as before.
  (2) The drain window was a fixed 200ms with an unconditional flag clear —
  a straggler in a bounded native wait (sync-resume spin) could outlive it
  and keep running its dead test forever with the flags cleared. The drain
  now polls a new `threads_in_eval` census until the cohort actually leaves
  interpreted code (10s bound, loud warning on timeout). Verified:
  RecomposerTests 4/4 runs = 11/1 with ONLY the throughput livelock red
  (pausing frame-clock was 2/3 red, now 4/4 green in class context);
  SnapshotStateSetTests.concurrentGlobalModification_remove 5/5 green
  solo — its earlier flake was the same contamination. Unit tests +
  coroutines census 1299/0 hold.
- validatePotentialDeadlock RECLASSIFIED: spin dumps 40s apart show
  different live frames (ChangeList apply, then a worker's snapshot write)
  — progress, not deadlock. Mechanism: the interpreted TestCoroutineScheduler
  drain iteration is slower than the worker round-trip, so the infinite
  withContext(Default) writer keeps the zero-virtual-delay task stream
  dense and advanceTimeBy never reaches its target (upstream passes only
  because real JVM threads out-pace the drain loop). Folds into the
  throughput campaign with the rest of the timeout family.
- 2026-08-22 CONTAMINATION MECHANISM (task 1 correctness item): the
  pausing frame-clock test is 4/4 green run as the ONLY test, but 2/3 red
  when its class runs — validatePotentialDeadlock (declared earlier in the
  class) hits the 90s wall cap first and its two INFINITE LaunchedEffect
  loops + Default-dispatcher workers are ABANDONED, not stopped; the
  successor test inherits stolen CPU and possibly dirty process-global
  snapshot state ("daemon task abandoned at run boundary" then surfaces in
  arbitrary later monitor waits). NEXT: verify what the run boundary
  actually does to abandoned worker loops, and make a wall-capped test's
  teardown quiesce them before the next test starts.
