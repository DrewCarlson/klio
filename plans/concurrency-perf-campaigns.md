# Four campaigns: concurrency correctness + the three performance fronts

Every library census suite is at zero and the compose_plugin gate holds its
ratchet. What remains is one throughput-bound compose test and the open
performance fronts. This plan tracks all four to completion.

Discipline: root-cause only, peel one root at a time, full battery before
every commit, example + pinned output per interpreter root, never `zig build`
while a background battery runs.

Standing gate (2026-08-27): **1389 passed / 1 failed / 0 DNC at 397s**,
ratchet 1386, `MAX_FAILED = 5`, width 8 — the best recorded. The one failure
is `validatePotentialDeadlock`, the last real item.
`PausableCompositionTests.resumeOnBackgroundThread` fails only under gate
contention (25/25 solo) and is a wall-cap artifact, not a defect.

---

## Task 1 — compose_plugin concurrency group: zero real failures

CLOSED except one test. The "race family" was DISPROVEN as races
(2026-08-23: 5 classes x 6 solo reps, counts 100% stable) — every failure was
a deterministic THROUGHPUT timeout, amplified at gate scale by 8-way
contention. 10/10 SOLO CONFIRMATION (2026-08-27): 40 class runs at the gate's
coroutine budget, zero failures (List 65/65, Set 21/21, Map 59/59, Pausable
25/25, ten times each).

Landed roots: TTAS spin locks (5f6b22be); host equality for the vendored
PersistentHashMap (c8dda94e, contended replace 630 -> 78ms) and for the
persistent vectors (47d9c817); the whole-cycle `SnapshotStateMap.put` serve;
the GC stop-the-world rendezvous fix; and the call-throughput rounds
(mixrep 3.06 -> 0.77s/rep, putrep3 78 -> 22ms, frames/insert ~30 -> ~5.3).
Rejected with measurements: backoff-sleep ladder (667 vs 630ms), module-cell
locking (already Noop), name-identity and field memos (already present).

- [ ] OPEN — `RecomposerTests.validatePotentialDeadlock`: **416s solo vs the
      gate's 90s per-class cap (4.6x)**, down from 753s on this round's
      dispatch work (the failure it reports is its own 60s `runTest` budget —
      still throughput, no correctness component). COST MODEL MEASURED (2026-08-27,
      replica `f10_texts200`: 200 texts, ten frames, both composers):
      `advanceTimeBy(5_000)` x10 at a 16ms frame clock = ~3120 frames, each
      recomposing the root and its 200 `Text` children = ~624k composable
      recompositions. Frames and recompositions are CORRECT (9 frames ->
      10 recompositions for 160ms; no divergence, no runaway drain), and the
      per-recomposition cost is ~1.05ms, which multiplies out to the observed
      wall. So the gap is throughput per composable recomposition, not a
      scheduling pathology, and it needs ~7x.
      KOTLIN-LEVEL PROFILE (the new `KLIO_FN_PROF`): a quarter of the time is
      `Operation.executeWithComposeStackTrace` self-time — a three-line
      wrapper whose body is two bare MEMBER-EXTENSION dispatches
      (`getGroupAnchor`, `execute`) — plus ~11% in the drain and ~11% in
      lambdas. The interpreter-level profile is diffuse behind that (memset
      ~16%, getIndex 4.8%, runFrameExec 3.8%, eqlBytes 3.2%).
      FRAME CENSUS (`KLIO_FRAME_CENSUS`, added this round): one Text
      recomposition costs **~355 interpreted activations**, and the census is a
      flat list of compose-runtime one-liners (IntStack push/pop, slot-table
      group reads, Stack push/pop/isEmpty, compoundWith, OpIterator.getInt).
      A tiny member call measures ~0.4us, so activations account for only
      ~18% of the wall — the rest is dispatch, host serves, allocation and GC,
      and the interpreter profile behind them is a long tail of 1-5% items
      (memset 9%, runFrameExec 9%, eqlBytes 5%, execInst 3%, getIndex 2%).
      TWO LEVERS MEASURED AND REJECTED on that basis:
      widening the def-before-use analysis and the frame write-mask from 64 to
      256 registers halves the register-fill memset in the profile but leaves
      the wall unchanged (3093ms vs 3094ms), and extending the frameless leaf
      serve to requests carrying a pending enclosing-chain pop removes 12% of
      activations for no wall change. So frame COUNT and frame SETUP are both
      off the critical path. What is left is raw interpreted work: ~1833
      tree-walked instructions per recomposition (plus the bytecode tier's own
      stream, which does not pass through `execInst`) for ~765us, spread over
      a long tail no single lever dominates. That is the interpreted-vs-native
      factor, and only Front A moves it.
      LANDED THIS ROUND (78132521): a member-extension winner is now memoized
      under the chain-folded key (the owner is re-found on the chain at serve
      time), which took a member-extension call from 3.0us to 1.5us and the
      replica from 4.37s to 3.06s. DISPROVEN by A/B: the wrapper's cost is
      NOT `getGroupAnchor` or the inline `withCurrentStackTrace` — deleting
      both from the pack saved 2.4%. It is the op bodies plus their dispatch,
      which `KLIO_FN_PROF` attributes to the caller whenever the callee is
      leaf/bytecode-served rather than framed.
      Reaching 90s means native-speed execution of that inner loop: **Front A**
      (bake-time AOT object-shape natives), with Front B's frame/allocation
      levers as the compounding half. The test races two infinite writer loops
      against the drain, so recompose+apply speedups converge on it
      superlinearly.

## Task 2 — compose suite wall time — EXIT MET (2026-08-27)

**334s at width 8** vs the 727s baseline (2.18x), better than the halving
target. Width rose 6 -> 8 (`KLIO_ITEST_JOBS` overrides for measurement) once
the throughput work and the GC rendezvous fix stopped the concurrent-snapshot
family from failing at wider jobs.

Facts that shaped it: the wall floor is compute-heavy classes run interpreted
~300x native (`oneRectBenchmarkSimulation` repeat(10000), `SlotTableTests`);
loop JIT does not help this shape (378 vs 326s) and `klio test` forces it off;
`buildSubTable` is LINEAR (2.08/2.09/2.07 ms per round across 4000 rounds), so
the lever was per-call overhead, not a pathology; lowering the runTest
dispatch cap is HARMFUL (teardown-deadlock hangs).

## Task 3 — Value layout stage 5b — RESOLVED

`Value` is 24B today (stage 5b first half landed). Stage 5c (24 -> 16: Array
pointer-bit tag + IrClosure boxing) is DEFERRED by its own measurement
discipline — IrClosure boxing adds an allocation to compose's hottest creation
path. Re-opens only when a profile shows Value-copy traffic dominating.

## Task 4 — C transpiler speedup — EXIT MET (2026-08-23)

rangebench transpiled native **124ms vs 164ms interpreted** (1.32x; was 830 vs
291 = 2.9x SLOWER at diagnosis). Roots: the hot view never engaged (layout
probes read undefined padding -> UB trap); char ranges now lower as counted
register loops for BOTH tiers (4d00da2f); fused counted-loop emission extended
to descending loops (28c73118). Battery green, `char_range_loops.kt` pinned,
corpus transpile timeout 300 -> 600s.

---

## The three fronts (defined 2026-08-26)

### Front A — precompiled natives for the heavy library functions (OPEN)

The loop JIT and bytecode tier accelerate SCALAR code only; snapshot and
collection functions are object- and call-heavy. The C transpiler already
produces AOT bodies bound to a pinned image, but its replay set is scalar-pure
(the leaf-miss tally puts the boundary at "escape-op 57 = object work"). The
existing hand serves (snapshot_fast, persistent_map_mut) are hand-written
instances of what this generalizes.

- A1. Object-shape sub-ABI: native access to Instance field slots
  (index-claimed like the GetField site memos), object-array elements,
  instance minting via the persistent_map_mut template mechanism, and
  native->native calls; bail-to-interp on shape surprise. Oracle: the
  transpiler corpus at byte parity (293/293 today), extended with
  object-shaped programs. NOTE: A1 alone moves no gate number — the emitted
  bodies only run once A2 registers them.
- A2. Bake-time AOT: transpile the hot library functions at pack bake (ids are
  pinned there) and ship the .so with the pack, registered through
  `klio_rt_register_native_leaf`. No runtime JIT. Oracle: the compose gate
  count unchanged with the natives engaged (`KLIO_NATIVE_TRACE` is the
  engagement check), then vpd's wall.
- A3. Retire the hand serves one for one; each serve is its function's oracle.
- Exit: the snapshot write cycle (currentSnapshot -> readable ->
  builder/put/build -> attemptUpdate) runs with zero interpreted frames.

WHY NOTHING SMALLER WORKS (ceiling arithmetic against the frame census, so a
future round does not re-derive it): the hot bodies are spread thin. Serving
the slot-table group readers natively covers ~90 of the ~355 activations per
recomposition (~1.3x), the composer end/enterGroup/exitGroup another ~46
(~1.15x), the changelist pushes ~25 (~1.08x) — about 1.6x compounded, and
~2x with the measured -20% ReleaseFast gate build. vpd needs 4.6x. Only
compiling the whole recomposition path reaches it.

The census tool for both fronts is `KLIO_FN_PROF` (see
`docs/development/debugging.md`): it samples the INTERPRETED program's
currently executing function, so a profile names the Kotlin body to serve
instead of the interpreter internals underneath it.

### Front B — interpreter floor (OPEN)

- B1. Frame cost: activation open/close is the diffuse floor (runFrameExec
  ~6%, memset/poison ~7%). Levers: register-bank reuse pools; the
  ReleaseFast-for-gate build policy (measured -20%, awaiting a user call).
- B2. Id-keyed dispatch: eqlBytes 4.2% + getIndex ~5% + hash family are
  string-keyed cache probes; intern symbol ids at bake and key on them.
- B3. Allocation rate: boxing per put is ~GBs per stress test; A1's native
  bodies cut it structurally.
- Exit: the timed replica's per-rep wall (~8s warm) reaches <= 3s.

### Front C — inline parity with kotlinc — COMPLETE (2026-08-26)

kotlinc inlines every inline-fun lambda; klio now matches on the map path:
qualified-inline splice, the ext-lambda tier, seated windows, the subject-bind
receiver fix and the recursion-guard base took map frames 3.62M -> 1.59M
(~5.3 per insert, from ~30 at session start).

---

## Closed rounds (chronological, one line each)

- Gate-red round (2026-08-24): five roots; `scripts/gate.sh` GREEN.
- Collection hot paths, call-throughput rounds 2/3/4, candidate-pool chip,
  round 5 (ceiling quantified), round 6 (compounding core), round 7
  (receiver-formed lambda splicing), round 8/8b (splice receiver tower,
  with-family correct under RFS).
- Snapshot-read wrapper serves (throughput 2x), currentSnapshot native serve,
  map-builder CHAMP serve + slab spare aging, getter-route serves + builder
  mint, GetField fast serves (wall record 402s), dead forwarded-literal
  elision (394s), concrete param heads + width-matched scalar splices,
  outer-hop field routes, snapshot-map livelock root (07939c91).
- 2026-08-26 whole-cycle `SnapshotStateMap.put` serve (2.9x; replica 12.5s vs
  a 30s budget), then the GC work that unblocked it.
- 2026-08-26/27 THE GC ROOT: not a missing root — a **stop-the-world
  rendezvous hole**. The collector could begin MARKING while another mutator
  ran, walking a tearing frame chain and sweeping cells a running thread was
  still linking (`KLIO_GC_STW_AUDIT=1` showed ~90k violations per stress run).
  Four holes: `parkForStop` published a park with no stop in progress; the
  count was per-REASON so one thread could satisfy the rendezvous alone;
  non-mutator helpers were counted against a mutator-derived total; and
  `exitMutator` published as parked before decrementing `mutators`, covering
  for a different running mutator. Membership now takes a `mutator_lock` the
  collector also holds while snapshotting `mutators` and raising the stop, and
  parking is tallied in a `stopped_count` reset per stop. Violations 90k -> 0,
  every crash repro passes, normal-mode wall unchanged. The worker perm-mint
  stopgap stays retired (`KLIO_WORKER_PERM=1` restores it for bisecting).
- 2026-08-27 compose UI examples: `compose_window`, `compose_multiwindow` and
  `compose_material3_text` run clean. One family, three roots + one latent
  unsoundness (8fc9d086, be029ef6):
  1. A bare member-extension call picks its DISPATCH receiver innermost-first
     among tower receivers whose class OWNS the declaration, and its EXTENSION
     receiver independently from the innermost receiver satisfying the
     declared type. The committed static target no longer decides the callee —
     that is what made `with(other) { f() }` inside `f` re-enter `f` forever
     (six `PostInsertNodeFixup` executions against five `InsertNodeFixup`, the
     window pair's `IndexOutOfBoundsException`) and what passed the node
     instead of the enclosing `MeasureScope` to
     `with(layoutModifierNode) { measure(m, c) }`.
  2. Member-extension VISIBILITY consults the executing frames' own receivers
     (`frameThisChainIter`), which the dynamic enclosing chain never carries:
     `Dp.roundToPx()` inside `MeasureScope.measure` needs that frame's Density.
  3. A bare NAME inside a member-extension body reads the EXTENSION receiver's
     member before the enclosing class's same-named one.
  4. A 1-2 character all-caps receiver type was ALWAYS treated as a bare type
     variable, so a user `interface R` accepted any receiver; a declared class
     of that name is now proven like any other.
  Guards: `member_extension_receiver_tower.kt`, `short_uppercase_user_type.kt`.

## Traps (hard-won, do not re-learn)

- `KLIO_GC_DEBUG` only LOGS; never-free is `KLIO_GC_NOFREE`.
- Perf-tier heads must be DECLARED evidence: deriving a receiver head
  heuristically made the ext-lambda tier splice eager `Iterable.filter` onto
  an infinite Sequence (SequenceTest spun forever).
- `klio-harness run` is GC-mode; the itest harnesses run the ARENA profile.
  Never sweep a suite on the Debug harness.
- `scripts/compose-test.sh` defaults the coroutine-test timeout to 10s but the
  gate uses upstream's 60s; export 60s for any solo confirmation.
- `scripts/corpus_check.py` is OBSOLETE (diffs against the retired
  `target/release/klio`). The live example oracles are `itest-check_examples`
  and `itest-parity_corpus_pinned`.
- `KLIO_LEAF_TRACE` is a TRANSPILE-TIME emitter trace, not a runtime one.
- `klio dump-ir` lowers lazily (only `main` unless something forces more), and
  `KLIO_BARE_TRACE` never reaches a pack build's own lowering — answer
  pack-side questions with runtime frame-params dumps (`KLIO_ERR_TRACE=1`).
- Installed packs shadow `kotlin-klio/` sources: rebuild and reinstall after
  any lowering change or the measurement is of old code.
- A member-extension override must be picked by its DECLARED extension
  receiver, not by name+arity alone: the class index's first match sent
  `LayoutModifierNodeCoordinator` into the wrong body (`get_field 'type'`).
- `declaringClassName` was an O(classes x methods) scan; any dispatch arm that
  consults candidate fids must answer from an index (it reached 63% of a
  compose profile before it was memoized).
