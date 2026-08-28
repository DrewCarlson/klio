# Four campaigns: concurrency correctness + the three performance fronts

Every library census suite is at zero and the compose_plugin gate holds its
ratchet. What remains is one throughput-bound compose test and the open
performance fronts. This plan tracks all four to completion.

Discipline: root-cause only, peel one root at a time, full battery before
every commit, example + pinned output per interpreter root, never `zig build`
while a background battery runs.

Standing gate (2026-08-28): **1390 passed / 0 failed / 0 DNC at 797s** — fully
green and deterministic, ratchet 1386, width 8. Three measured-slow tests
(`validatePotentialDeadlock` ~724s, `resumeOnBackgroundThread`,
`pausingTheFrameClockStopShouldBlockWithFrameNanos`) run under DECLARED
budgets instead of being cut off by the 90s hang detector; each budget is a
ratchet that must only shrink. The wall is 797s because those tests run to
completion — driving it under 364s is the one open item, and it is
recomposition throughput.

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

- [x] CLOSED 2026-08-28 — `RecomposerTests.validatePotentialDeadlock` PASSES
      in the gate; the suite is **1390/0/0**. It was never wedged: it races two
      infinite writer loops against ~3120 frames of 200 composables and
      completes in ~724s, so the 90s HANG DETECTOR was reporting "slow" as
      "stuck", and upstream's 60s `runTest` budget fired non-deterministically
      on top (the 416s figures were ABORTS, not passes). The test now declares
      its own budget (`KLIO_TEST_WALL_CAP_FOR`: 900s for the test, 1200s for
      its class), with the suite coroutine budget above klio's cap so the cap
      stays the guard. The budget is a RATCHET — it must only shrink.
      The cost is Task 2's metric: the wall went ~400s -> 847s because the test
      now runs instead of being cut off, so the two are ONE piece of work —
      recomposition throughput. Its cost model, and every lever measured
      against it, is in Task 2.

## Task 2 — compose suite wall time — OPEN, and JOINTLY UNSATISFIABLE with Task 1 today

THE TWO EXITS CONFLICT AT CURRENT THROUGHPUT, proven from both sides: cut
`validatePotentialDeadlock` off at 90s and Task 1 is red (it is reported as a
failure for being slow); let it run and Task 2 is red (it alone is ~800s, and
the suite wall is its slowest child). Only a ~2.2x faster recomposition
satisfies both.

WHERE A RECOMPOSITION'S TIME GOES (replica, ten frames x 200 composables):
0.5s composition+effects baseline, ~1.3s the plugin's per-call-site ritual,
~1.5s node emission (ComposeNode + Updater.set + changelist + applier).
String interpolation is FREE: alternating two constant strings costs the same
as building one per call (3284 vs 3290ms), so the parameter CHANGE (which
defeats skipping), not the string, is what costs.
Sized levers, none of which reach 2.2x: a native changelist serve ~10-20%, a
native composer group/slot serve ~15-25%, frameless leaf WRITES ~2%, the
ReleaseFast gate harness 1.20x (a policy call that trades the safety checks a
test suite wants).

ANATOMY OF ONE COMPOSABLE RECOMPOSITION (2026-08-28, measured, not sampled —
`KLIO_FRAME_COUNT` deltas between a 10-frame and a 60-frame replica run):
**740 IR instructions, 173 activations, 319 field reads, ~250us.** That is
335ns per instruction against a 20ns walker floor (6ns under the bytecode
tier), so the cost is entirely in what the heavy ops do, not in the loop.
Attribution, each measured by ablation or by a wall-clock bucket:
- member-call RESOLUTION is only ~63ns per call (arg run + site replay +
  flat prepare, all timed at phases that return before the callee runs). The
  590ns a whole-arm timer first reported was the callee's own execution
  billed to dispatch — do not time a dispatch arm end to end.
- field reads 12% (23 getter-route reads and 34 ladder reads per composable)
- register fill 7% before the fix below, ~1.5% after
- every dispatch fast path *together* (KLIO_FLAT, KLIO_FLAT_VCALL, the site
  memo, the leaf tier) is worth 14%: turning them all off costs only that
- the leaf tier and the CallMember site memo are each worth ~0% here
The distribution is FLAT — no single removable component is worth more than
15%, which is why nine separate hypotheses (fills, a field PIC, leaf
coverage, the bytecode tier, register banks, allocation, GC, string
interning) each measured at or near zero on the wall.
Landed this round: **253us -> 220us (13%)** on the replica and the suite
wall **847s -> 797s**, fully green (1390/0/0). The wins, each measured
alone: host serves for the composer's IntStack, the composite-key rotation,
BOTH changelists' push, the write scope and the slot-table index math
(`KLIO_COMPOSE_FAST` is a bisect mask over them); a polymorphic call-site
cache; and reading an instance's class identity without its reader lock
(~380 such reads per composable). ReleaseFast would add a further 1.18x and
is still unused by default.
What is left in the sampled profile after that: GetField 13.4%, Call 12.7%,
CallMemberOrGlobal 8.9%, CallVirtual 7.6%, the member-extension fallback
7.5% (98.8% of its probes HIT — the cost is rebuilding the key, not the
walk), SetField 5.0%, NewInstance 4.8%. Nothing above 14%.
Also measured at zero this round and not kept: a chain-hash memo (the chain
mutates as often as it is read) and a member-extension site cache on
`CallMember` — those fallbacks come from BARE calls through
`CallMemberOrGlobal`, whose member leg resolves per implicit-receiver
candidate, so a site cache there needs the winning candidate too.
The exit needs 2.2x. No measured lever exceeds 14%, and the biggest ones are
already taken, so the remaining path is an execution core that does not
resolve, frame and box per call — the same conclusion Front A reached, now
priced at the instruction level.
vpd does exactly the work its design implies — 3125 virtual frames x 200
Texts x 2 composers = 1.25M recompositions, confirmed by counting the state
reads (276k in a 150s window) — so there is no amplification to remove, only
throughput.



**334s at width 8** vs the 727s baseline (2.18x) was met on 2026-08-27 — but
that measurement had `validatePotentialDeadlock` cut off at 90s. With the
three measured-slow tests running to completion the wall is **847s**, and the
suite's long pole IS `validatePotentialDeadlock`: the wall equals that one
test, so scheduling cannot move it and only its throughput can. Width rose
6 -> 8 once the throughput work and the GC rendezvous fix stopped the
concurrent-snapshot family from failing at wider jobs.

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

### Front A — precompiled natives for the heavy library functions (RE-SCOPED 2026-08-28)

**MEASURED DEAD END for the recomposition path.** With
`KLIO_TRANSPILE_PKGS=androidx.compose.runtime` the transpiler now emits and
registers natives for library bodies (6575 compose functions, 1226 of them as
frameless leaf replays) against a pinned image. On a 50-composable
recomposition loop over the real compose runtime the result is **1828-1835us
per recomposition against 1758us interpreted** — no speedup, output identical.
The emitted C calls the same `klio_op_*` helpers for every op it does not
inline, and a recomposition is dispatch and frame machinery, so the C adds a
layer without removing work. (The inlined ops do pay where they apply: a
field-heavy loop is 2.7x and an IntArray loop 1.75x.)
So closing vpd needs a compiler that inlines DISPATCH and manages frames
natively — a different architecture from the per-op ABI, not a wider op
selector. That is a research-scale project; nothing in the current transpiler
design reaches 4.6x.

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
  transpiler corpus at byte parity. NOTE: A1 alone moves no gate number —
  the emitted bodies only run once A2 registers them.
  - [x] A1a stored-field reads (d535383b, d10e4051): the site caches the
        (class cell, stored slot) route and reads the slot inline behind a
        class guard. Field-heavy loop 514 -> 197 ns/iter (2.6x). The gate is
        `fieldSiteRoute`'s own verdict, NOT `plainStoredFieldIndex` — the
        latter matches a `by lazy` delegate's storage slot by name and handed
        back the delegate object.
  - [x] A1b IntArray element reads (2867f7ef): tag, primitive-storage
        discriminator (probed) and index guarded, escape otherwise.
        IntArray loop 1403 -> 803 ns/iter (1.75x).
  - [x] A1c stored-field + IntArray WRITES (c1bb7f05): write memo gates the
        route, GC write barrier on the cell. Mutator loop 1.31x — and with
        reads AND writes inlined a compose recomposition is STILL 1788us
        native vs 1737us interpreted, which is the measurement that says the
        path is bound by calls, not data access.
  - [ ] A1d would be inline DISPATCH (native frames, inline caches) — the
        only remaining piece that could move compose, and a different
        architecture from the per-op ABI.
  `KLIO_OBJVIEW=0` disables the object view for single-binary A/B.
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
  ReleaseFast-for-gate build policy — RE-CONFIRMED 2026-08-28 on the
  recomposition replica, **2574ms vs 3091ms (1.20x)** with
  `zig build klio-harness -Dharness-optimize=ReleaseFast`. It is a policy
  call, not code: the gate harness is ReleaseSafe so a failure stays
  debuggable. Taking it puts vpd at ~347s, still 3.9x over its cap.
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

- 2026-08-28 round: nine measured-zero hypotheses (above) plus five landed
  roots — the exponential typing memo, the scoped `$sgetter$` field route
  (half the ladder reads), deferred callees kept leaf-eligible (a callee
  probed before its body decoded cached "not a leaf" for the whole run), the
  register-fill proof widened 64 -> 512 slots (`GapComposer.end` alone carries
  502 registers; fills 4.62M -> 0.49M), and the compose host serves.
- 2026-08-28 EXPONENTIAL LOWERING (found while sizing frame cost): every
  resolution arm re-derives an operand's type, so a chain of infix calls
  re-typed its whole left operand once per arm. 24 terms = 20M type queries /
  17s; 28 terms never finished. Static typing is now memoized per outermost
  query (`KLIO_TY_MEMO=0` restores the old path); 120 terms lower in 5.5s.
  Fixture `wide_infix_chain.kt`. Typing is now off the compose critical path;
  it did NOT move suite wall (compose sources were already under the knee).
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

- A host serve matched by FQN *suffix* must be checked against EVERY composer:
  the link-buffer's `pushOp` raises `requiresApplication` from the operation's
  visibility while the gap-buffer's does not, and serving both took
  MovableContentTests 44 -> 4.
- Diagnostic code on a serve seam costs more than the serve saves: two
  `indexOf` scans over the callee fqn per call turned a 10% win into a 9%
  loss until they were removed.
- An activation cut does NOT imply a wall win here: -7% activations from the
  leaf work and -77% register fills both measured 0% on the clock. Only
  measure the clock.

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
