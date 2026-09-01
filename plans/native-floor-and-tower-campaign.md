# Native-floor-and-tower campaign: transpiled output never loses; tower scoping goes exact

STATUS 2026-09-01: COMPLETE. Closing battery green with everything in
(parity 401/0, every census at its floor — coroutines 1299, compose
1390/0, ktor 450/0, datetime 519/0 — ui-gate 5/5, stack rc=0). Task 1:
floor landed (transpiled >= interpreted by construction; epochbench 2x
FASTER than interpreted, rangebench 5.1x, fib 25.8x); rungs A/ctor-tail
landed earlier, rung D stage 1 (field reads, 2.5x) and stage 2
(InstanceOf, 2.3x) landed with numbers below; rung E (stores) CLOSED BY
MEASUREMENT: the write-heavy surface (compose) measured leaf-neutral in
the object-runtime campaign — heavy-store bodies are gate-bound, not
replay-bound — and no floor-set program is store-bound (epochbench
closed 2x-faster, fib/rangebench scalar); the doorway vein is recorded
under Task 1 for a future heavier customer. Task 2: LANDED
strict-by-default (four named mechanisms, all root-fixed; plain pairs
deleted for getters and setters).

## Measured starting facts (do not re-derive)

- Transpiled binaries are perf-NEUTRAL on scalar code (rangebench
  ReleaseFast 14.44 vs 14.55 interpreter JIT-off) and ~10x SLOWER on
  object-heavy code: epochbench 41.6s native vs 4.0s interpreted,
  IDENTICAL with the leaf rungs stashed — the loss is the per-op
  `klio_op_escape` surround (one host-ABI crossing per instruction),
  the per-op law's starkest measurement. kl_ leaves are 34.5x where
  they engage (fib) and now serve INSIDE transpiled binaries via the
  fid-keyed path.
- The transpiled binary already embeds a full interpreter (libklio_rt)
  and its pinned image; the legacy fallback path proves the runtime
  can execute image fns without emitted C bodies.
- Corpus parity gate: scripts/transpiler-corpus-check.sh at 401/0 —
  the campaign's unbreakable floor. Traps in force: ReleaseFast
  libzstd.a for transpiled links; ids need the pinned artifact;
  KLIO_NATIVE_TRACE is the engagement oracle; the 256MB runCli thread
  (GNU_STACK ignored).
- Receiver-tower: the CALL-half public gating was closed-by-record at
  "~400 tests without full receiver-tower emulation" — non-private
  member extensions still register a PROGRAM-WIDE plain (recv, name)
  pair because the tower emulation missed legal frames. Since then the
  tower gained: both-receiver binding at the mext call arm,
  pushed-owner probing (ownerKeyedExtProp walks the enclosing chain),
  lazy-body ensures, file-scope class ranking, and the
  member-ext-property tail serve. The 400-test terms are stale.

## Task 1 — the native floor: transpiled output never loses

- Flip the execution default: the emitted `main` drives the program
  through libklio_rt's own interpreter drivers over the pinned image,
  with kl_ leaves registered — native >= interpreter by construction.
  Per-op op-helper C bodies stop being the default execution path;
  emit them only where they cannot lose (start: nowhere — the leaf
  bodies are the native share; the op-helper emitter stays for
  explicit opt-in/bisection until proven useful somewhere, then dies
  or stays per measurement).
- Measure the floor set: epochbench (object-heavy — the 41.6s must
  drop to ~interpreter speed + leaf wins), fib/rangebench (the scalar
  multiples must HOLD — they run through leaves; verify engagement
  with KLIO_NATIVE_TRACE/KLIO_LEAF_DIAG), and two corpus-representative
  programs. Corpus parity 401/0 throughout.
- Then coverage, measured-first: profile which floor-set hot bodies
  sit just OUTSIDE leaf eligibility and whether an object rung
  (D-shape: reads; E-shape: stores) has a customer whose numbers
  justify it. Land or close-by-measurement per rung, exactly as the
  object-runtime campaign did.
- FLOOR LANDED (2026-09-01): leaves-only emission by default
  (KLIO_TRANSPILE_OPHELPERS=1 keeps the per-op emitter for bisection);
  libklio_rt builds from the harness universe (the Debug universe made
  the embedded interpreter 3x slow). Measured: epochbench 41.6s ->
  2.0s (2x FASTER than interpreted; 1.77s on a ReleaseFast rt),
  rangebench 5.1x (was neutral), fib 25.8x; parity 401/0.
- RUNG D STAGE 1 LANDED (2026-09-01): genre-8 instance handles + plain
  stored-field reads in leaves (KVC frozen layout, per-site class-word
  guard, edge-view field_route resolver, one-level trivial-getter
  chase, scoped $sgetter names) + one-arg bitwise/shift virtuals +
  inv + Not. toEpochDays micro 721 -> 290ms (2.5x); datetime census
  green 107s; wide surface 2310 -> 3298 leaves. TRAPS: the field-route
  claim's identity value is NOT comparable to the receiver's class
  word (different spaces — bind the slot to the receiver's word); the
  layout check must compare field-by-field (memcmp trips on padding);
  the interpreter's frameless leaf evaluator already owns BRANCHLESS
  field readers, so kl_ field wins appear only where it declines
  (branchy bodies).
- RUNG D STAGE 2 LANDED (2026-09-01): InstanceOf as a leaf op —
  kl_instanceof caches a 1/2 verdict keyed to the receiver's class
  word per site, resolved once through the edge-view type_route (the
  host's `is` predicate over a borrowed cell view). Eligibility admits
  only plain non-nullable classifiers (no generic args, no bare type
  variables — reified context stays interpreted); non-genre-8 values
  bail to the exact re-run. Unlocks 104 bodies (3096 -> 3200 wide
  leaves), LocalDate.equals among them: the equals micro (600k calls)
  950 -> 420ms (2.3x), 599,982/600,599 served. TRAP: the leaf pack cc
  compiles against zig-out/include/klio_rt.h — refresh it after
  editing include/ (zig build klio-harness does not reinstall it).
- DOORWAY VEIN (recorded, not chased): at 290ms/300k calls the
  toEpochDays micro is doorway-bound (dispatch walk + marshal +
  per-call edge-view build), ~41% in the leaf itself. Back-edge-only
  safe-point polling in leaf bodies landed (forward jumps are bounded)
  but measured noise-level (285-290ms) — profile granularity at this
  scale cannot attribute further. The remaining levers (leaf route on
  member-site memos / fast_call plans, threadlocal cached edge view)
  stay recorded for a future campaign with a heavier customer.
- INLINE-STUB TRAP (2026-09-01, caught by the ktor census floor at
  410/40 on the first engaged stack): an INLINE fn's standalone
  lowered body is NOT its semantics — call sites splice the AST and
  the leftover body can be a bare identity stub (Map.iterator's leaf
  returned the receiver map). Inline fns are leaf-ineligible
  (3298 -> 3096 leaves). Any future emission surface must honor the
  same rule; the wide leaves had carried 202 such stubs through
  several green datetime/coroutines stacks before ktor's iteration
  paths exposed one.

## Task 2 — receiver-tower call-half gating, re-measured

- LANDED STRICT-BY-DEFAULT (2026-09-01): the first strict count was
  540 (compose 384, ktor 92, coroutines 51, datetime 13 — larger than
  the recorded ~400), and it decomposed into exactly FOUR named
  mechanisms, each root-fixed in sequence with the count re-run after
  each: (1) synthesized accessor/property-init fns had no decl_span,
  so the import-scoped probe lost the declaring file (`1.seconds` in a
  class property initializer; datetime 13 -> 4); (2) lambda bodies had
  no decl_span (`300.milliseconds` inside `withVirtualTime { }`;
  coroutines + datetime -> 0) — the lambda's file is where its body
  was WRITTEN, and a frame-walk fallback would attribute the
  invoker's file, which is wrong; (3) every remaining thunk shape via
  pushFuncSpanned (an inline splice lands the extension site directly
  in a `__top_prop_init_*` fn — DEFAULT_TIMEOUT's
  `runCatching { 60.seconds }`; ktor + most of compose -> 0); (4) the
  tower probe reaches an owner through supertype_names (simple names)
  but registration keyed fqn only, so a member extension on an
  implemented interface missed (PersistentCompositionLocalMap's
  `CompositionLocal<T>.currentValue`, the last 8 compose) — fixed with
  simple-owner alias keys (package segments stripped by case
  convention). Strict full stack GREEN rc=0 (every census floor,
  compose 1390/0, ui-gate 5/5), then the plain pair was deleted for
  getters AND setters (the setter pair had never been env-gated) and
  the env removed. A bystander's `x.decorated` can no longer see
  another class's member extension.
- Trace instrument kept: `KLIO_MISS_TRACE=<name>` now also prints
  `[imp-ext]` (frame fn, file id, import-path count) at the
  import-scoped probe.

## Standing policy

- Measurement-first with before/after on named numbers; corpus parity
  401/0, every census floor/ceiling, and the compose gate never
  weaken; scripts/stack.sh is the full battery.
- Traps in force: pinned-image id stability, ReleaseFast libzstd,
  leaf env matching, installed packs shadow sources, never `zig build`
  during a battery, set KLIO_BIN for install-local-packs.

Exit: the floor set shows transpiled >= interpreted on every program
in it with scalar multiples intact and parity 401/0; Task 1's coverage
rungs each landed-with-numbers or closed by measurement; Task 2 landed
strict-by-default or carries a refreshed, named-mechanism count. Full
battery green throughout.
