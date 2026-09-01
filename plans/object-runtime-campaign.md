# Object-runtime campaign: move the interpreted floor itself

STATUS 2026-09-01: Round 0 CLOSED green; Task 1 rung A/B in progress. Successor to the verification-latency
campaign (plans/verification-latency-campaign.md, closed targets-met):
verification is fast; the floors that remain ARE the production
runtime on object-heavy code.

MANDATE CONTEXT: the 2026-08-31 mandate covered verification AND "the
actual production runtime of the interpreter, jit code, and transpiled
C". This campaign is the runtime half.

## The measured starting facts (do not re-derive)

- Every wall-dominating body in the whole verification stack is
  object/dispatch-bound: vpd's recomposition (494s GC-relaxed solo
  body — the flagship customer), datetime fromEpochDays (100s:
  LocalDate ctor + equals dispatch per iteration), compose
  SlotTable/CompositionTests, coroutines machinery. All interpreted
  ~300x native.
- The loop JIT is NEUTRAL-to-NEGATIVE on these shapes (vpd 573s with
  JIT; datetime A/B flat in both run and test mode). The per-op host
  ABI is a measured dead end (interpreter-next campaign law).
- The kl_ scalar sub-ABI (C transpiler) is proven 34.5x where it
  engages (fib) with byte-exact parity (corpus 401/401 gate) — but
  none of the wall bodies are expressible in it today (scalars only).
- SHAPES (instance layout ids, site claims, fused stores, JIT
  guard_shape) landed in the shared-op campaign and are the layout
  foundation object lowering can key on. TRAP from that campaign:
  shape is LAYOUT not CLASS — never serve class-keyed routes off a
  shape key.
- GC Appel relaxation is exhausted as a knob (growth 8 == 16).

## Round 0 — hygiene (one short round, lock in last week's gains)

- [x] Ratchets tightened (2026-09-01): compose 1386 -> 1390, androidx
      1830 -> 1841, coroutines 1285 -> 1295 (solo 1299; margin kept
      for load), vpd declared budget 645 -> 580 (GC-relaxed in-stack
      525-535 across four stacks, solo 510). Battery VERDICT: full stack
      green at the new floors (compose 1390@1390, coroutines 1299@1295,
      androidx 1841@1841, vpd 528s under the 580 cap). Round 0 CLOSED.
- [x] The two absorbed load-flakes, recorded-as-measured
      (2026-09-01), neither papered over:
      * resumeOnBackgroundThread (1000 one-at-a-time cross-thread
        round-trips, ~40-55s solo): breached its 300s wall-cap ONCE,
        under the discarded all-eight-suites-at-width-4 wave that also
        dropped androidx children to DNC — an oversubscription
        casualty of a structure that no longer exists. Green in every
        stack under the two-wave L3-split structure. Its per-test cap
        stays 300s; a breach there again means the structure regressed,
        which is exactly what the cap is for.
      * tl_cancel_via_coroutine_context: the fixture itself is racy —
        `yield()` does not guarantee the launched child's first
        dispatch ran before `cancel()`, on the JVM oracle too; klio's
        interpreted window is just wider. Under load the pre-cancel
        dispatch loses the race and `c1-cancelled` never prints.
        Structural remedy (litmus runs last, alone, on a quiet box)
        matches the fixture's implicit assumption instead of hiding
        the mismatch; solo it is deterministic-green. An interpreter
        change to force yield-as-barrier would DIVERGE from Kotlin
        semantics and is rejected.

## Task 1 — widen kl_ eligibility to object shapes (the campaign core)

Measurement-first, driven by the ACTUAL hot bodies (vpd, fromEpochDays,
SlotTable), not by inst-kind coverage tables. The recorded future vein
from the native-floor campaign, now with named customers.

BAIL CENSUS (2026-09-01, KLIO_LEAF_TRACE over the datetime surface):
escape-op 1074 (84%), nonscalar-const 166, no-stream 19, bin-kind 7 —
object ops behind `escape` dominate exactly as predicted. Reading the
hot bodies' IR (dump-ir dateFromEpochDays/fromEpochDays) refines the
rungs to what the code actually needs:
- dateFromEpochDays is ~all scalar arithmetic; it bails only on (a)
  the COLD error path (StringConcat + NewInstance
  IllegalArgumentException + throw) and (b) the terminal
  `NewInstance LocalDate` returning the result.
- The fromEpochDays wrappers bail solely on STATICALLY-BOUND
  CallMemberOrGlobal/CallVirtual insts (the dump shows the binding).
The kl_ architecture is pure-replay-with-exact-bail (`return 0` =
interpreter re-runs from scratch; sound because nothing before the
bail had side effects). Rungs in measured-cheapest order, each gated
on corpus parity 401/401 + measured on a named customer:
- [ ] Rung A — bound-call widening: treat DYN-bound member calls and
      slot-resolved virtual calls as fixpoint call targets like
      `.Call` (no new ABI; unlocks every wrapper whose callee is
      eligible). Customer: fromEpochDays wrappers.
- [ ] Rung B — cold-throw tolerance: a path that provably ends in
      `throw` may contain non-scalar ops; emitted code bails
      (`return 0`) at entry to that path, the interpreter re-runs and
      throws for real. Purity preserved. Unlocks the pervasive
      require/IllegalArgument guard pattern. Customer:
      dateFromEpochDays sans terminal ctor.
- [ ] Rung C — terminal construction: `NewInstance` of a shape-stable
      class in tail position via a `klio_rt` host helper (allocation
      before a later bail is invisible — the object is garbage, GC
      collects it; purity holds). Customer: dateFromEpochDays
      complete -> the fromEpochDays test body's per-iteration
      LocalDate.
- [ ] Rung D — read-only object access: SHAPES-guarded field loads +
      array reads inside kl_ regions (guard miss = bail; loads are
      side-effect-free so the bail contract survives). Customer:
      LocalDate.equals (field compares), SlotTable IntArray reads.
- [ ] Rung E (only if A-D measure well) — side-effecting stores with
      real deopt points; breaks pure-replay, needs a materialization
      contract. Decide from the D measurement whether the remaining
      floor justifies it.
Exit per rung: measured wall movement on at least one named customer
(the datetime census's 119s / the vpd body / SlotTableTests), or a
recorded closed-by-measurement verdict.

## Task 2 — compose completeness residue (interleave when Task 1
blocks on measurement)

From the plugin triage plan (see it for detail): corpus 285/295 — the
10 highs include window family + foundation_lazy hangs, serial_names,
receiver-loss residue (entry 46); plus checkboxLike slot-exact anchor,
factory wrap, imbalance. Feature-correctness work, well-mapped.

## Standing policy

- Measurement-first: no rung lands without before/after on a named
  customer; neutral results get recorded and the rung closed.
- Correctness gates never weaken: corpus parity 401/401, all census
  floors/ceilings, the compose gate — same tests, same baselines.
- Traps in force: shape is LAYOUT not CLASS; ids need the pinned
  image (bakes not cross-process id-stable); ReleaseFast libzstd.a
  for transpiled links; bench on klio-harness, never Debug; installed
  packs shadow sources.
- NEW TRAP (2026-09-01, cost one corpus-gate run): zig cc trusts a
  cache-manifest hit WITHOUT stat'ing the artifact — pruning o/ dirs
  while their h/ manifests survive (names do not correspond) leaves
  dangling hits and ld fails on the missing .o. prune-zig-cache.sh now
  wipes h/ whenever it prunes; a mysterious "cannot open
  .zig-cache/o/...o" after any manual cache surgery means stale
  manifests — rm .zig-cache/h/*.

Exit: Round 0 landed green; each Task 1 rung landed-with-measured-win
or closed-by-measurement; Task 2 items fixed or root-caused into the
triage plan. The full battery (scripts/stack.sh) green throughout.
