# Object-runtime campaign: move the interpreted floor itself

STATUS 2026-09-01: NOT STARTED. Successor to the verification-latency
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

- [ ] Tighten ratchet floors to the repeatedly-measured greens:
      compose 1386 -> 1390, androidx 1830 -> 1841, coroutines 1285 ->
      1295 (solo 1299; keep load margin), and shrink the vpd declared
      budget 645 -> 580 (GC-relaxed in-stack 525-535 across four
      stacks, solo 510).
- [ ] The two absorbed load-flakes: root-cause or record-as-measured.
      resumeOnBackgroundThread breached its 300s cap once under the
      all-eight-width-4 census wave (structure since replaced);
      tl_cancel_via_coroutine_context is a legitimately racy fixture
      (yield() is not a barrier) structurally dodged by litmus-last.
      Neither may be papered over silently.

## Task 1 — widen kl_ eligibility to object shapes (the campaign core)

Measurement-first, driven by the ACTUAL hot bodies (vpd, fromEpochDays,
SlotTable), not by inst-kind coverage tables. The recorded future vein
from the native-floor campaign, now with named customers. Candidate
rungs, each gated on the corpus parity check staying 401/401 and
measured on the named bodies before the next rung:
- Known-layout field load/store (SHAPES-guarded) in kl_ regions.
- Object construction of shape-stable classes.
- Monomorphic member dispatch on shape-guarded receivers (deopt to
  interpreter on guard miss — the transpiler's pinned-image ids make
  the guard stable per bake).
- Boxed-value round-trip elimination inside a kl_ region (Value stays
  16B; unbox at entry, rebox at exit — the value-layout campaign's
  measured frame).
Exit per rung: measured wall movement on at least one named customer,
or a recorded closed-by-measurement verdict.

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

Exit: Round 0 landed green; each Task 1 rung landed-with-measured-win
or closed-by-measurement; Task 2 items fixed or root-caused into the
triage plan. The full battery (scripts/stack.sh) green throughout.
