# Four campaigns: concurrency correctness + the three performance fronts

STATUS 2026-08-29: **all four tasks and all three fronts are closed.** The
standing gate is 1390 passed / 0 failed / 0 DNC, vpd child 602s on the
ReleaseFast gate harness, budget ratchet 700s. What remains is not open
work in this plan but the hand-off below: the ratchet that banks future
throughput wins, the recorded future veins, and the traps.

Discipline that got it here: root-cause only, peel one root at a time,
full battery before every commit, example + pinned output per interpreter
root, never `zig build` while a background battery runs.

---

## Completed

### Task 1 — compose_plugin concurrency group — CLOSED 2026-08-28

The "race family" was DISPROVEN as races (5 classes x 6 solo reps, counts
100% stable; then 40 class runs at the gate budget, zero failures) — every
failure was a deterministic THROUGHPUT timeout amplified by 8-way
contention. Landed roots: TTAS spin locks (5f6b22be); host equality for
the vendored PersistentHashMap (c8dda94e) and persistent vectors
(47d9c817); the whole-cycle `SnapshotStateMap.put` serve; the GC
stop-the-world rendezvous fix; the call-throughput rounds (frames/insert
~30 -> ~5.3). `validatePotentialDeadlock` was never wedged — it PASSES
given budget (the 90s cap is a hang detector that read "slow" as "stuck",
and the old 416s figures were upstream-runTest ABORTS, not passes). It
runs under a declared budget (`KLIO_TEST_WALL_CAP_FOR`), a ratchet.

### Task 2 — compose suite wall time — CLOSED BY MEASUREMENT 2026-08-29

The metric is honest now and the target was not: the 364s figure descends
from the abort-era wall (a wall that skipped most of vpd's real
computation). From the first genuine full-pass baseline (847s) the landed
rounds reached **~615s (vpd child 602s)**, gate 1390/0/0 throughout:

- serve/splice/dispatch rounds: 253 -> 182us per composable, wall 847 ->
  ~700s (see Closed rounds).
- ReleaseFast gate policy (e2192a48): `klio-harness-fast`, spawned only
  by `fast_exe` suites; replica 191 -> 163us (1.17x), vpd 708 -> 623s.
  Sweeps, units, and every other itest keep ReleaseSafe.
- Throw-capable host serves + the changelist wrapper serve (f79ca3cf):
  replica 194 -> 186us, vpd 637 -> 608s.
- vpd budget ratchet: 900 -> 800 -> 700s.

WHY IT CLOSES HERE (all measured, quiet box, 4x reps):
- Three execution-tier architectures are neutral on this workload — the
  per-op C transpiler, the bytecode tier, the A1d fused walker — for one
  reason: the heavy-op BODIES (field lookup, dispatch, alloc) dominate
  and run through the same host paths in every tier.
- The serve vein below the reimplement-the-composer line is dry: the
  whole-drain serve measured NEUTRAL (its 7.8% profile share was its
  callees' dispatch billed under its stamp; the drain itself frames only
  ~124x/run), the push-block serve needs value-class receiver boxing for
  ~2%, and the rest of the profile is a flat tail of upstream composer
  bodies (max 4.4%) whose serves would port composer logic wholesale —
  out of bounds for a suite that exists to validate the upstream code.
- Compounding every remaining visible lever optimistically lands ~470s.
  The old target requires an inlined-dispatch native-frame compiler,
  measured out three times.

### Task 3 — Value layout stage 5b — RESOLVED

`Value` is 24B. Stage 5c (24 -> 16) is a recorded future vein (below).

### Task 4 — C transpiler speedup — EXIT MET 2026-08-23

rangebench transpiled native **124ms vs 164ms interpreted** (1.32x).
Roots: hot view never engaged (layout probes read undefined padding — UB
trap); char ranges lower as counted register loops both tiers (4d00da2f);
fused counted-loop emission extended to descending loops (28c73118).
`char_range_loops.kt` pinned.

### Front A — precompiled natives — CLOSED (measured dead end for compose)

The object-shape sub-ABI landed and pays where it applies (stored-field
reads 2.6x, IntArray reads 1.75x, writes with the GC barrier; A1a-A1c).
THE RESULT THAT MATTERS: 6575 compose bodies emitted as C = 1828-1835us
vs 1758us interpreted per recomposition — NO speedup; the emitted C hands
every uninlined op back to `klio_op_*`. Do not re-try a wider op selector.

A1d, the fused native-bank walker, is CLOSED as landed default-on
infrastructure with its perf leg measured dead (~2% overhead even at full
coverage). What stands: the walker (C-bank registers, no Frame, per-block
GC safe point, transitive host-in-the-verdict classification, no-abandon),
MATERIALIZE-ON-DEMAND (fused prefix, real Frame at the first heavy op; the
framed-parity chain window the frame inherits whole; windows/args as GC
thread roots; a fused body IS the executing function for visibility, the
receiver tower, call-site span, and package; erased-cast leniency; the
ambiguous-site host-binding gate; MINPREFIX 24), and flagged dynamic-call
arms (KLIO_FUSED_DYN=1). Knobs: KLIO_FUSED=0/fqn-list, KLIO_FUSED_MAT=0,
KLIO_FUSED_MINPREFIX, KLIO_FUSED_TRACE, KLIO_FUSE_CENSUS. Fixtures:
fused_throw_catch, fused_member_ext_owner, fused_private_companion_ext,
fused_erased_cast. Full root list: session memory
`klio-four-campaign-session`. Do not reopen a frameless walker as a WALL
lever.

### Front B — interpreter floor — CLOSED (B1 adopted; B2/B3 recorded below)

### Front C — inline parity with kotlinc — COMPLETE 2026-08-26

Map-path splice frames 3.62M -> 1.59M (~5.3 per insert, from ~30). The
splice-hygiene family (depth-tagged mutable homes, per-finally replay
windows, the member-body scope floor `splice_body_floor`) and the
monomorphic member-inline tier landed with it; `splice_hygiene_shadow.kt`
pins every shape; `KLIO_MEMBER_INLINE` / `KLIO_PMI_TRACE` bisect.

---

## Remaining / future work (nothing open; recorded for the next campaign)

1. **The vpd budget ratchet (700s) is the permanent guard.** Every future
   recomposition-throughput win must bank into it — shrink the budget,
   never let it grow.
2. **B2 — id-keyed dispatch**: intern symbol ids at bake and key the
   string-keyed cache probes on them (`eqlBytes` ~5% of the interpreter
   profile). Cross-cutting refactor, single-digit yield; first vein for a
   future interpreter-floor campaign.
3. **B3 — allocation rate / typed storage**: the structural boxing cut
   needs typed collections — the compiler direction measured dead three
   times; only worth revisiting with a genuinely new architecture
   (inlined dispatch + native frames).
4. **Value stage 5c (24 -> 16B)**: Array pointer-bit tag + IrClosure
   boxing. Re-opens only when a profile shows Value-copy traffic
   dominating (IrClosure boxing adds an allocation to compose's hottest
   creation path).
5. **A2/A3 (bake-time AOT registration; retiring the hand serves)**:
   only meaningful after a compiler tier that actually wins; the hand
   serves (`snapshot_fast`, `compose_fast`, `persistent_map_mut`) stay
   as the working instances.
6. **Push-block serve precondition**: `push(op) { args }` can be served
   only with a boxed WriteScope receiver (value-class member dispatch
   belongs to the framed machinery); ~2% if ever built.

## The serve seams (how to add the next serve)

`src/ir/compose_fast.zig` behind `KLIO_COMPOSE_FAST` (bits 0-5 pure
serves, bit6 the throw-capable wrapper serve; default 127), wired at
`hostRouteServe` + `hostRouteServeThrowing` on the recursive and flat
seams (a flat throw rides rthrow). Discipline: reads and validations
before any write; raising branches stay interpreted unless the serve uses
the throwing seam; ref returns retain; field writes adopt via define; a
serve that has performed side effects may never decline (prevalidate,
then fail LOUD). Before serving a profile-hot body, check its FRAME
CENSUS count — fn-prof bills a callee's host-serve work to the caller's
stamp (the drain-serve mirage).

MEASURED AT OR NEAR ZERO (do not re-try): register-fill reduction,
leaf-coverage gains, a polymorphic field-site cache, the bytecode tier on
this shape, loop JIT, allocation/GC profile switches, string interning, a
chain-hash memo, a member-ext site cache on CallMember, string
interpolation, lowering the runTest dispatch cap (HARMFUL), buildSubTable
(linear), scheduling (mined out three ways), the whole-drain serve, typed
unboxing on the walker.

---

## Closed rounds (one line each; details in the session memory files)

- 2026-08-29: A1d slices (chain window, GC-stress roots, framed-context
  parity, MINPREFIX), ReleaseFast gate policy, throw-capable serves +
  changelist wrapper serve, fn-prof fused stamping + ghost caveat; wall
  ~700 -> ~615s.
- 2026-08-28b: compose host serves + call-site cache + unlocked class
  identity (253 -> 220us, wall 847 -> 797s); register-fill proof 64 ->
  512 slots (fills 4.62M -> 0.49M).
- 2026-08-28a: EXPONENTIAL LOWERING fixed — infix chains re-typed the
  left operand per resolution arm (24 terms = 20M queries; 28 never
  finished); memoized (`KLIO_TY_MEMO=0`); `wide_infix_chain.kt`.
- 2026-08-27: compose UI example family via four member-extension
  dispatch roots; member-ext winner memoized under the chain-folded key
  (3.0 -> 1.5us).
- 2026-08-26/27: THE GC ROOT — four stop-the-world rendezvous holes
  (`KLIO_GC_STW_AUDIT=1` 90k violations -> 0); whole-cycle
  `SnapshotStateMap.put` serve (2.9x).
- Earlier: gate-red round (five roots); call-throughput rounds 2-8b;
  snapshot-read/CHAMP/getter-route/GetField serve rounds; snapshot-map
  livelock root (07939c91).

## Traps (hard-won, do not re-learn)

- A host serve matched by FQN *suffix* must be checked against EVERY
  composer (the link-buffer `pushOp` divergence took MovableContentTests
  44 -> 4).
- NEVER time a dispatch arm end to end — it bills the callee to dispatch.
- Check the FRAME CENSUS before serving a profile-hot body; fn-prof
  names can also be cross-module id-collision GHOSTS (the report says so
  — verify with KLIO_TRACE_PATH or a frame-push count).
- Judge the gate wrapper by EXIT CODE — zig build prints a dim
  'failed command:' line even on exit-0 runs; a piped tail masks the code.
- Measure FULL PASSES, not where a budget cuts a run off (the 416s trap);
  solo vpd without the gate env ABORTS at upstream's 60s runTest budget;
  KLIO_ERR_TRACE=1 poisons vpd timing.
- An activation cut does NOT imply a wall win: only measure the clock.
- Diagnostic code on a serve seam costs more than the serve saves.
- Installed packs shadow `kotlin-klio/` sources — rebuild and reinstall
  after any lowering change or the measurement is of old code.
- `klio-harness run` is GC-mode; itest harnesses run the ARENA profile;
  never sweep a suite on the Debug harness.
- `scripts/compose-test.sh` defaults the coroutine timeout to 10s; the
  gate uses upstream's 60s — export 60s for solo confirmation.
- `klio dump-ir` lowers lazily; answer pack-side questions with runtime
  frame-params dumps (`KLIO_ERR_TRACE=1`).
- A member-extension override must be picked by its DECLARED extension
  receiver, not name+arity.
- Any dispatch arm that consults candidate fids must answer from an index
  (`declaringClassName` was an O(classes x methods) scan at 63% of a
  profile).
- Perf-tier heads must be DECLARED evidence (the
  eager-filter-on-infinite-Sequence trap).
- `KLIO_GC_DEBUG` only LOGS; never-free is `KLIO_GC_NOFREE`.
- `scripts/corpus_check.py` is OBSOLETE; live oracles are
  `itest-check_examples` and `itest-parity_corpus_pinned`.
