# Native-floor-and-tower campaign: transpiled output never loses; tower scoping goes exact

STATUS 2026-09-01: NOT STARTED. Two fronts left standing by the leaf
era: the C transpiler's object-code regression (recorded in
plans/c-transpiler-plan.md as the pinned speedup campaign) and the
receiver-tower call-half gating terms (recorded in
plans/open-campaigns.md §2), which predate this week's tower machinery.

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
  (branchy bodies). Stage 2 (TypeTest -> equals) next.
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

- Gate the plain program-wide pair for NON-private member extensions
  behind an env (KLIO_MEXT_TOWER_STRICT=1: register/resolve
  owner-keyed only, the kotlinc-exact scoping), then run the full
  battery + compose gate + corpus under it and COUNT the delta
  against the recorded ~400.
- Delta ~0: land strict as the default and delete the plain-pair
  fallback (a correctness tightening — a bystander's `x.decorated`
  must not see another class's member extension).
- Small delta: fix the named misses (each is a tower frame the
  emulation still cannot see — the failure names the frame shape),
  then land.
- Still large: record the refreshed terms with the named mechanisms
  and keep the fallback; the count itself is the deliverable.

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
