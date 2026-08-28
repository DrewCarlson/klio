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
budgets (`KLIO_TEST_WALL_CAP_FOR`) instead of being cut off by the 90s hang
detector; each budget is a ratchet that must only shrink. Driving the wall
under 364s is the one open item, and it is recomposition throughput.

---

## Task 1 — compose_plugin concurrency group — CLOSED 2026-08-28

The "race family" was DISPROVEN as races (5 classes x 6 solo reps, counts
100% stable; then 40 class runs at the gate budget, zero failures) — every
failure was a deterministic THROUGHPUT timeout amplified by 8-way contention.
Landed roots: TTAS spin locks (5f6b22be); host equality for the vendored
PersistentHashMap (c8dda94e) and persistent vectors (47d9c817); the
whole-cycle `SnapshotStateMap.put` serve; the GC stop-the-world rendezvous
fix; the call-throughput rounds (frames/insert ~30 -> ~5.3).

`RecomposerTests.validatePotentialDeadlock` PASSES in the gate. It was never
wedged: it races two infinite writer loops against ~3120 frames of 200
composables and completes in ~724s, so the 90s hang detector was reporting
"slow" as "stuck", and upstream's 60s `runTest` budget fired
non-deterministically on top (the old 416s figures were ABORTS, not passes).
It now declares its own budget (900s test / 1200s class), a ratchet that must
only shrink. The cost is Task 2's metric — the two are ONE piece of work:
recomposition throughput.

## Task 2 — compose suite wall time — OPEN (797s, target 364s)

The wall EQUALS `validatePotentialDeadlock` (its slowest child), so
scheduling cannot move it; only recomposition throughput can. The wall target
needs ~2.2x; returning vpd's budget to the 90s default needs ~8x. vpd does
exactly the work its design implies — 3125 virtual frames x 200 Texts x 2
composers = 1.25M recompositions, confirmed by counting state reads — so
there is no amplification to remove.

ANATOMY OF ONE COMPOSABLE RECOMPOSITION (2026-08-28, measured by
`KLIO_FRAME_COUNT` deltas between a 10-frame and a 60-frame replica run, not
sampled): **740 IR instructions, 173 activations, 319 field reads, ~220us** —
335ns per instruction against a 20ns walker floor (6ns under the bytecode
tier). The cost is in what the heavy ops do, not the loop, and the
distribution is FLAT: nothing above 14%.
- member-call RESOLUTION is only ~63ns per call (timed at phases that return
  before the callee runs). NEVER time a dispatch arm end to end — it bills
  the callee's execution to dispatch (read 63ns as 590ns).
- field reads ~12%; every dispatch fast path *together* (KLIO_FLAT,
  KLIO_FLAT_VCALL, the site memo, the leaf tier) is worth 14%.
- sampled profile after this round: GetField 13.4%, Call 12.7%,
  CallMemberOrGlobal 8.9%, CallVirtual 7.6%, member-ext fallback 7.5%
  (98.8% of its probes HIT — the cost is rebuilding the key, not the walk),
  SetField 5.0%, NewInstance 4.8%.

LANDED 2026-08-28 round: **253us -> 220us (13%)** per composable, wall
**847s -> 797s**, fully green. Each measured alone: host serves for the
composer's IntStack, the composite-key rotation, BOTH changelists' push, the
write scope and the slot-table index math (`src/ir/compose_fast.zig`;
`KLIO_COMPOSE_FAST` is a bisect mask, wired at `hostRouteServe` AND the
flat-call seam); a polymorphic member-call-site cache; unlocked
class-identity reads (`InstanceData.classIdentityUnlocked`, ~380 per
composable). ReleaseFast (`-Dharness-optimize=ReleaseFast`) adds a further
1.18x and stays unused — a policy call that trades the safety checks a test
suite wants.

MEASURED AT OR NEAR ZERO (do not re-try): register-fill reduction (-77%
slots), leaf-coverage gains (-7% activations), a polymorphic field-site
cache, the bytecode tier on this shape, loop JIT (`klio test` forces it off
anyway), allocation/GC profile switches, string interning, a chain-hash memo
(the chain mutates as often as it is read), a member-extension site cache on
`CallMember` (those fallbacks come from BARE calls through
`CallMemberOrGlobal`, whose member leg resolves per implicit-receiver
candidate), string interpolation (parameter CHANGE defeats skipping, not the
string), and lowering the runTest dispatch cap (HARMFUL —
teardown-deadlock hangs). `buildSubTable` is LINEAR — per-call overhead, not
a pathology.

EXIT PATH: no measured lever exceeds 14% and the biggest are taken, so the
remaining path is an execution core that does not resolve, frame and box per
call — Front A1d. Serve-sized levers from here are single digits.

## Task 3 — Value layout stage 5b — RESOLVED

`Value` is 24B. Stage 5c (24 -> 16: Array pointer-bit tag + IrClosure boxing)
is DEFERRED — IrClosure boxing adds an allocation to compose's hottest
creation path. Re-opens only when a profile shows Value-copy traffic
dominating.

## Task 4 — C transpiler speedup — EXIT MET (2026-08-23)

rangebench transpiled native **124ms vs 164ms interpreted** (1.32x). Roots:
the hot view never engaged (layout probes read undefined padding -> UB trap);
char ranges lower as counted register loops for both tiers (4d00da2f); fused
counted-loop emission extended to descending loops (28c73118). Battery green,
`char_range_loops.kt` pinned.

---

## The three fronts

### Front A — precompiled natives (per-op ABI COMPLETE and a MEASURED DEAD END for compose; A1d open)

The object-shape sub-ABI landed and pays where it applies: stored-field reads
2.6x on a field loop (A1a, d535383b — gate on `fieldSiteRoute`'s verdict, NOT
`plainStoredFieldIndex`, which matches a `by lazy` delegate's slot by name),
IntArray reads 1.75x (A1b, 2867f7ef), stored-field + IntArray writes with the
GC barrier (A1c, c1bb7f05). `KLIO_TRANSPILE_PKGS` widens emission to library
bodies; `KLIO_OBJVIEW=0` A/Bs the object view; `KLIO_NATIVE_TRACE` is the
engagement oracle.

THE RESULT THAT MATTERS: with 6575 compose-runtime bodies emitted as C
(1226 as frameless leaf replays) against a pinned image, a recomposition is
**1828-1835us native vs 1758us interpreted** — no speedup. The emitted C
hands every uninlined op back to `klio_op_*`, and a recomposition IS dispatch
and frame machinery, so the C adds a layer without removing work. Do not
re-try a wider op selector.

- [ ] A1d — inline DISPATCH and native frames (inline caches, native
      activation records): the only remaining piece that could move compose,
      and a different architecture from the per-op ABI. Research-scale.
      SCOPED 2026-08-28 (`[census-split]` in the frame census): per
      recomposition window the activation split is compose 70% + compose
      accessors 18% + lambdas 3.6% = **~92% of activations live inside the
      emittable compose set**; coroutines 2%, long-tail stdlib 6%. So a
      native set that elides dispatch+frames BETWEEN its own bodies covers
      the window; the interpreter bridge is the ~8% tail, not the spine.
      Next: native->native direct calls for bake-resolved targets within the
      emitted set, C-local register banks with GC keepalive registration,
      bail-to-interp on polymorphic-guard miss / suspension / throw.
- A2 (bake-time AOT registration) and A3 (retire the hand serves) only
  matter once A1d exists; the hand serves (`snapshot_fast`, `compose_fast`,
  `persistent_map_mut`) stay as the working instances.

The census tool is `KLIO_FN_PROF` (docs/development/debugging.md): it names
the Kotlin body, not the interpreter internals. Caveat: a leaf- or
bytecode-served callee is attributed to its caller.

### Front B — interpreter floor (OPEN, single-digit levers)

- B1. ReleaseFast-for-gate: re-confirmed 1.18-1.20x, policy call, unused.
- B2. Id-keyed dispatch: eqlBytes + getIndex + hash family are string-keyed
  cache probes; intern symbol ids at bake and key on them.
- B3. Allocation rate: boxing per put is ~GBs per stress test; A1d cuts it
  structurally.

### Front C — inline parity with kotlinc — COMPLETE (2026-08-26)

Map-path splice work took map frames 3.62M -> 1.59M (~5.3 per insert, from
~30 at session start).

---

## Closed rounds (one line each; details in the session memory files)

- 2026-08-28b: compose host serves + call-site cache + unlocked class
  identity (253 -> 220us, wall 847 -> 797s); scoped `$sgetter$` field route;
  deferred callees kept leaf-eligible; register-fill proof 64 -> 512 slots
  (`GapComposer.end` carries 502 registers; fills 4.62M -> 0.49M).
- 2026-08-28a: EXPONENTIAL LOWERING fixed — every resolution arm re-derived
  an operand's type, so infix chains were exponential (24 terms = 20M
  queries / 17s; 28 never finished). Memoized per outermost query
  (`KLIO_TY_MEMO=0` bisects); 120 terms in 5.5s. Fixture
  `wide_infix_chain.kt`. Did not move the suite wall.
- 2026-08-27: compose UI example family (window/multiwindow/material3_text)
  via four member-extension dispatch roots (8fc9d086, be029ef6); guards
  `member_extension_receiver_tower.kt`, `short_uppercase_user_type.kt`,
  `member_extension_owner_memo.kt`. Member-ext winner memoized under the
  chain-folded key (3.0 -> 1.5us).
- 2026-08-26/27: THE GC ROOT — a stop-the-world rendezvous hole (four
  distinct holes; `KLIO_GC_STW_AUDIT=1` went 90k violations -> 0). Whole-cycle
  `SnapshotStateMap.put` serve (2.9x).
- Earlier: gate-red round (2026-08-24, five roots); call-throughput rounds
  2-8b; snapshot-read/CHAMP/getter-route/GetField serve rounds;
  snapshot-map livelock root (07939c91).

## Traps (hard-won, do not re-learn)

- A host serve matched by FQN *suffix* must be checked against EVERY
  composer: the link-buffer's `pushOp` also raises `requiresApplication`;
  serving it with the gap-buffer body took MovableContentTests 44 -> 4.
- NEVER time a dispatch arm end to end — it bills the callee to dispatch.
- Diagnostic code on a serve seam costs more than the serve saves (two
  `indexOf` scans per call turned a 10% win into a 9% loss).
- An activation cut does NOT imply a wall win: only measure the clock.
- Measure FULL PASSES, not where a budget cuts a run off (the 416s trap).
- `KLIO_GC_DEBUG` only LOGS; never-free is `KLIO_GC_NOFREE`.
- Perf-tier heads must be DECLARED evidence (the eager-filter-on-infinite-
  Sequence trap).
- `klio-harness run` is GC-mode; itest harnesses run the ARENA profile.
  Never sweep a suite on the Debug harness.
- `scripts/compose-test.sh` defaults the coroutine timeout to 10s; the gate
  uses upstream's 60s — export 60s for solo confirmation.
- `scripts/corpus_check.py` is OBSOLETE; live oracles are
  `itest-check_examples` and `itest-parity_corpus_pinned`.
- `KLIO_LEAF_TRACE` is also a transpile-time emitter trace; the runtime leaf
  decline census is `KLIO_LEAF_TRACE='*'` on the harness.
- `klio dump-ir` lowers lazily; answer pack-side questions with runtime
  frame-params dumps (`KLIO_ERR_TRACE=1`).
- Installed packs shadow `kotlin-klio/` sources: rebuild and reinstall after
  any lowering change or the measurement is of old code.
- A member-extension override must be picked by its DECLARED extension
  receiver, not name+arity.
- Any dispatch arm that consults candidate fids must answer from an index
  (`declaringClassName` was an O(classes x methods) scan at 63% of a
  profile).
