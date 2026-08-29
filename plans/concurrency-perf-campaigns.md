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

LANDED 2026-08-28 rounds: **253us -> 182us (1.39x)** per composable; vpd
SOLO **~724s -> ~480s (1.5x)**; suite wall **847s -> ~700s**, gate
1390/0/0, vpd budget ratcheted 900 -> 800s. The [child-wall] diagnostic
now names the wall exactly: the vpd child at **694s in-suite** vs ~500s
solo (1.4x co-tenancy inflation across separate processes — memory
bandwidth / turbo, not a lock), every other child drains by ~300s.
SCHEDULING IS MINED OUT, measured three ways: width 6 vs 8 = 767 vs
758s; vpd's own child (negated --filter tokens) + its compile trimmed
~180s -> ~20s bought ~30s combined.
Remaining arithmetic: wall 364s needs vpd solo ~260s = another ~1.9x of
recomposition throughput; serve batches yield ~10% each with the largest
un-served census item now ~2%. ReleaseFast (1.18x policy) would land
~590s in-gate — still short alone. The open code paths: the
member-inline tier hardening (below) and Front A1d. The
serve family (`src/ir/compose_fast.zig`, `KLIO_COMPOSE_FAST` bisect mask,
wired at `hostRouteServe` AND the flat-call seam): IntStack, the
composite-key rotation, BOTH changelists' push, the write scope, the
slot-table index math, then SlotReader
next/startGroup/endGroup/groupKey/isGroupEnd/nodeCount/objectKey,
SlotWriter.dataIndex (both same-fqn overloads — the member fun and the
IntArray member-extension whose owner reads from the enclosing-chain top),
the OpIterator drain cursor (both composers), the requiresRecompose flag
bit, GapComposer's node assertion, and ObserverHolder.current. Plus a
polymorphic member-call-site cache and unlocked class-identity reads.
Serve discipline that kept it correct: reads and validations before any
write (a decline must not half-mutate), raising branches stay interpreted,
ref-valued returns retain and field writes adopt via define. ReleaseFast
adds a further 1.18x and stays unused (policy).
MEASUREMENT TRAPS hit here: a solo vpd run without the gate env aborts at
upstream's 60s runTest budget (~325s wall = compile + abort, NOT a pass),
and KLIO_ERR_TRACE=1 on a vpd run prints per-miss diagnostics until the
budget fires — never profile vpd with it.

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
LANDED after the first attempt was reverted and its blockers root-caused
(2026-08-28, 41b35ffd + 140384da):
- SPLICE HYGIENE: mutable-var homes were a flat name-keyed map, so a
  spliced body's own `var index` hijacked the call-site lambda's
  `index = ...` write — LATENT in the whole splice tier (Duration's parse
  cursor). Homes now carry their binding depth and honor the
  splice-resolve window. Fixture `splice_hygiene_shadow.kt`.
- FINALLY WINDOW: a finally replayed at a jump re-lowered under the jump
  site's window; each finally now records and replays under its own
  (the spliced `synchronized` finally resolved `lock` to a foreign
  package's global).
- The MONOMORPHIC MEMBER-INLINE tier itself, scoped by declared evidence:
  monomorphic owner class (a generic owner's `as T` reads the
  process-global slot), PROVABLE receiver type (the permissive check
  spliced SnapshotIdSet.fold onto a List), callback shape matched,
  exactly one survivor. `KLIO_MEMBER_INLINE` bisects by name list;
  `KLIO_PMI_TRACE` lists picks.
- [x] member-inline tier hardening CLOSED (2026-08-28): the loop-body
  failure was not about loops — the spliced body's bare `slots` (a field
  on the bound receiver) bound the CALLER's parameter of the same name.
  A member body's lexical scope is its owner class, never the call site,
  so a member splice now sets a scope FLOOR (`splice_body_floor`): bare
  names resolve only at or above the splice base, the caller-lambda
  window overriding it while an arg lambda lowers. The loop-free
  restriction is lifted; forEachTailSlot and the traverse family splice.
  Fixture extended (`splice_hygiene_shadow.kt`, `drain(slots: Table)`).

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

- [ ] A1d — the fused native-bank execution tier, now DESIGNED AGAINST
      MEASUREMENT (`KLIO_FUSE_CENSUS`, landed): a per-body classifier
      tallies which activations a walker with C-stack registers, routed
      field access and host-entry slow paths could run end to end.
      - Package split: ~92% of activations live in the emittable compose
        set (70% named + 18% accessors + 3.6% lambdas).
      - OPEN-WORLD expressibility (dynamic calls allowed): 58% of
        activations; blockers CallMemberOrGlobal 23k / LoadGlobal 23k /
        LoadFromThisOrGlobal 21k / NewInstance 21k per replica run.
        Admitting those four via host entries reaches ~96%.
      - CLOSED-WORLD (dynamic calls excluded): only 27% (~7% wall) —
        CallMember alone blocks 36k. NOT worth a tier alone.
      - The boundary is RESUMABILITY: a frameless body cannot sit under a
        suspending callee. The sound design is SUSPENSION
        MATERIALIZATION — on `.Suspended` from a callee, build the real
        Frame from the C bank at the current (block, inst) and hand it to
        the park machinery as if it had always been framed. Abandon never
        exists in this tier (bodies have writes); errors RAISE.
      - Ceiling arithmetic: frame machinery is ~270ns of a ~430ns framed
        call (measured on a 1M-call probe); full open-world coverage is
        ~25% of the recomposition wall -> vpd solo ~360s, in-suite ~520s.
        Slice 1 (the walker + materialization) does NOT close Task 2 by
        itself; slice 2 is typed unboxing + direct native->native calls on
        the same skeleton.
      SLICE 1a+1b LANDED, DEFAULT ON (78457be1, 8c148d3b): the fused
      walker — C-bank registers, unconditional GC safe point per block
      (pending() never sees another thread's stop_flag; gating on it let
      a fused spin-loop skip the STW rendezvous), pinned bank, no abandon
      (errors RAISE; binopValue extracted as the shared frame-free
      operator core), TRANSITIVE host-in-the-verdict classification
      (KlioContinuation.resumeWith runs its own body but calls the
      host-owned __klio_co_resume, and the resume machinery assumes a
      framed caller — the pump-stall root), generic markers excluded
      (frame reified context), INNER-class receivers excluded (bare reads
      reach the enclosing instance — IteratorImpl.hasNext reads the outer
      list's size; the subList CME root), seam fallback for declined
      callees. KLIO_FUSED=0 / name-list bisect; KLIO_FUSED_TRACE.
      MEASURED NEUTRAL on the replica at closed-world coverage — the
      skeleton is the deliverable.
      - [ ] A1d slice 2: open-world ops (LoadGlobal /
        LoadFromThisOrGlobal / CallMemberOrGlobal / NewInstance via host
        entries) with SUSPENSION MATERIALIZATION, then typed unboxing +
        direct native->native calls — the slices that carry the ~25%
        ceiling and beyond.
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
