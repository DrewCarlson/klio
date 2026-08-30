# Interpreter next campaign: the native tier, and the last measured veins

STATUS 2026-08-30: NOT STARTED. This plan is the successor to
`plans/concurrency-perf-campaigns.md` (closed; its STATUS header carries
the standing numbers) and collects everything that remains between the
current interpreter and the desired performance/efficiency end state.
Standing baseline: compose gate 1390/0/0, vpd child 577s (budget ratchet
650s, shrink-only), recomposition replica ~130us on the ReleaseFast
harness, Value 24B, memory targets met.

The prior campaign's central measurement, which this plan must not
relitigate: three partial execution tiers (per-op C transpiler, bytecode
tier, fused frameless walker) are ALL neutral on dispatch-heavy code for
one reason — the heavy ops (field lookup, member dispatch, allocation)
run through the same host routines in every tier. Anything that keeps the
per-op host ABI is a measured dead end.

---

## Task 1 — the native compiler tier (the only big lever left)

Goal: a tier that compiles the OBJECT MODEL, not the instruction stream —
the one architecture the closed campaign identified as capable of moving
vpd materially below 577s.

What it must do (each item is exactly what the three dead tiers did NOT
do):
- Fixed field offsets per class shape: field reads/writes compile to
  loads/stores against a shape-checked layout, not `getFieldInner`.
- Devirtualized member calls: monomorphic/polymorphic-guarded direct
  calls, not the dispatch ladders.
- Unboxed scalars in machine registers; `Value` boxing only at tier
  boundaries.
- Native frames (stack, not the register-pool Frame), with a
  MATERIALIZE-on-deopt story — reuse the A1d MAT machinery (chain-window
  inheritance, GC thread roots, framed-context marks) as the deopt
  substrate; it is already hardened and default-on.
- Deopt guards where the interpreter is dynamic: shape mismatch, host
  binding shadowing (the `convertDurationUnit` trap), ambiguous sites
  (`FAST_CALL_AMBIG_FLAG` is the recorded precedent).

THE SUBSTRATE (recognized 2026-08-30, do not rediscover): `jit_loop.zig`
is already a real x86-64 JIT — W^X exec buffers, typed i32/i64/f32/f64
register slots with box/unbox at boundaries, native field bases, inline
sites for small callees, a rich trampoline (member calls, field
read/write with class guards + deopt codes, map/list subscripts,
suspension parking), and scalar native-to-native recursion. It loses on
compose (JIT-on replica 146 vs 132us) because the composer-shaped
bodies do not CLASSIFY (unsupported insts) and because every real op in
a compiled loop still trampolines into host dispatch.

Progress (each measured, gate-neutral — the gate runs JIT-off):
- [x] CallVirtual trampoline (e81efce7): slot dispatch stays dynamic, no
  class guard; suspension parks through the member-site stash. Litmus
  `tl_virtual_jit_dispatch_loop` pins two-class exactness.
- [x] Tramp arg cap 3 -> 6 (1c7d1da8).
- [x] Stage 2 CORE BET PROVEN (7dba3fbc): a loop-invariant virtual call
  inlines its monomorphic slot target natively (host
  `resolveVirtualFuncId` = the class resolve memo + main-module slot
  table, no fallbacks; member-inline machinery reused wholesale — entry
  class guard, field-NN deopt rules). Monomorphic virtual loop
  **349 -> 1 ns/iter**; a polymorphic later activation deopts exactly
  (litmus). The attribution behind the prize: an interpreted virtual
  call is ~26% leaf-tier serving + ~22% driver + ~10% dispatch — all of
  which the devirtualized native body removes.
- [x] SEAM METHOD TIER (f393319d): the tier-starvation family fixed —
  a fusable body never framed (walker yields once hot,
  `fusedShouldYieldToFuncTier`) and a member-dispatched one bypassed the
  framed entry hook, so the recursive seam now counts, compiles, and
  runs DEOPT-FREE method bodies (no calls, no division, NN-proven
  `this`-field reads: native memory ops, no guards, RETURN-only) with
  no frame at all; the flat driver serves them via a non-counting peek.
  Member-call field-bump loop 353 -> 165 ns/iter, activations 3.0M ->
  1.5K. `tl_method_jit_field_bump` pins the subclass guard-decline.
  TRAPS recorded: native field sites must not trip the tramp-required
  bail (has_tramp_sites); `\$sgetter\$` scoped names resolve through
  memberFieldName; the seam decline print is KLIO_JIT_DEBUG-gated.
- [x] Flat-activation function-tier hook (2b35a8bb): the flat driver
  makes the same attempt as the framed entry hook when an activation
  opens (RETURN delivers as the driver's own completion; throw/deopt
  resume in the fresh frame; function-mode bodies are suspension-free
  by construction). Compose helpers and can-deopt methods now compile
  and run from member dispatch.
- [x] Object-param plumbing + the DECLARED-receiver tramp fix
  (a10aab67): member tramp sites carry the declared head and dispatch
  through callMemberNamedDeclared (latent loop-mode bug); object params
  seed frame registers borrowed (unset write-mask = clean overwrite);
  KLIO_FJ_SKIP bisects bodies.
- [!] REGRESSION FOUND, DEFAULT REVERTED (d9da6346): the milestone's
  32-clean validation ran on a build whose instReadsDef scratch
  OVERFLOWED (the [4]Reg buffer vs 6-arg caps, fixed in 97d66d7e) — with
  real read-sets computed, the compose replica fails reproducibly under
  member sites (applyChanges runtimeCheck; live suspect =
  androidx.collection.ScatterMap.isNotEmpty in method mode: _size read
  field[5] name-verified returns 0, and a second same-name variant
  compiles with EMPTY method_fields on another thread — chase THAT
  variant first: which fid, why no field machinery, what it returns).
  Member/virtual sites are opt-in (KLIO_FJ_MEMBER=1) until this
  root-causes; the generic ESCAPE machinery landed opt-in too
  (KLIO_FJ_ESCAPE=1) with precise per-escape sync as its follow-up.
  Diagnostics that now exist for the hunt: every tryCompileFunc bail
  prints its line under KLIO_JIT_DEBUG; KLIO_FJ_SKIP=names bisects.
- [x] Member/virtual sites in FUNCTION mode machinery (d5315202).
  Both launch repros dissolved as ONE bug: the object-param seed table
  was never copied into the CompiledLoop, so member receivers read
  stale pooled-frame registers (the "GapComposer receiver" was pool
  garbage). Shipped with instance-layout hardening: native method
  field indexes re-verify BY NAME against the live receiver at every
  entry (field order is not class-static — dynamic defines append).
  KLIO_FJ_MEMBER=0 and KLIO_FJ_SKIP=names bisect. Gate 1390/0/0, vpd
  561s. TRAP for the record: a `zig build ... >/dev/null 2>&1` hid a
  compile error and a whole diagnosis round ran against a STALE binary
  — always let build errors print.
- [ ] Remaining classify blockers, in unblock order: CallMemberOrValue /
  CallMemberOrGlobal, InstanceOf, EnclosingPush/Pop, StoreGlobal,
  NewInstance, QualifiedThis (each is a tramp arm or a native check;
  composer bodies `recomposeToGroupEnd`/`settle`/`compositeKeyOf` name
  the exact needs).
- [ ] Then: function-tier coverage of the composer straight-line bodies,
  replica A/B, and only on a measured win the gate-policy question
  (safe profile keeps JIT off today; every seam/tier addition so far is
  `funcEnabled()`-gated, so the gate is untouched by construction).

Exit: vpd budget ratchets down with each landed stage; the tier is a win
only if the CLOCK moves (the closed campaign's "activation cut does not
imply a wall win" rule applies in full).

Unblocked by this tier (recorded in the closed plan): A2/A3-style AOT
registration, B3 typed storage, Value 5c re-evaluation.

## Task 2 — transpiler frozen hot-view — LANDED 2026-08-30

The frozen scalar sub-ABI landed (0ebbe957; detail in
`plans/c-transpiler-plan.md` § "The speedup campaign"): the layout fill
moved to the shared `ir.hot_layout`, the generated C carries every
offset/tag as `KVC_*` compile-time constants, and the runtime verifies a
registered frozen copy (`klio_rt_register_hot_frozen`, ABI 5) — mismatch
disables the view wholesale. Measured: fieldbench 57 -> 9.5 ns/iter (6x
on the op-by-op shape, ~20x over the interpreter); rangebench already
saturated by fused typed loops. Transpiler corpus 401/0 — the first
fully clean run: the standing `dispatched_delay` flake was a REAL
fused-classification race (cross-thread optimistic verdict before block
decode; b496543b fixes decode serialization, seam re-ensure, and
thread-local fixpoint), and the remaining parity noise was the ungated
`[ext-fb]` stderr census (now behind KLIO_DISPATCH_STATS). The
remaining "direct C-to-C calls + light frame-open" bullet is Task 1's
architecture question and is evaluated there.

## Task 3 — refcount-traffic vein — CLOSED BY MEASUREMENT 2026-08-30

The ~4% profile share was a RUN-MODE artifact (the arena-profile trap):
`klio test` forces reclaim OFF (`commands.zig` testRunEntry seams), so
the gate already skips every `clone`/`deinit` refcount atomic — those
costs exist only under `klio run`'s GC profile. The gate-relevant
remainder is the SpinRwLock shared borrow guards, and a direct
noop-the-guards build (measurement only, reverted) moved the replica
128-130 vs 128-131us — **at most ~1% wall**, below this plan's own >=2%
implement threshold. Deferred RC / borrow elision would buy the gate
nothing; do not re-try without a profile taken under gate-parity
conditions (arena mode, KLIO_JIT=0, fast harness). The
`interfaceDelegateFor` per-field-read scan rides inside the same
sub-noise envelope (its class-static memo idea is recorded here should a
future profile promote it).

## Task 4 — flag soak + finalization

Deleted 2026-08-30 (the cleanup round): `KLIO_FUSED_DYN` (+ the flagged
fused dynamic-call arms), `KLIO_FIELD_ID_STATS` (+ its hot-path branch),
the dead implicit-composer half of `vm/compose.zig` (callSiteKey /
argsHash / isComposable — the ambient-composer stack and threaded-arg
detection remain, the plugin path uses them), and the retired
`KLIO_COMPOSE_PLUGIN` env from `scripts/compose-fleet.py`.

CORRECTION recorded: `KLIO_FUNC_JIT` is NOT dead — `jit_func` is on in
the `fast` profile, so the whole-function tier is live in run mode. It
stays, as does `KLIO_JIT` (loop JIT: 60-79x on numeric loops, -27% on
compose shapes — a workload policy switch; `klio test` forces safe).

Soak list — bisect knobs for landed defaults; after one further green
gate cycle with no bisect use, delete the knob and keep the default:
- `KLIO_CANON` (name canonicalization; landed 2026-08-29)
- `KLIO_TY_MEMO` (typing memo; landed 2026-08-28)
- `KLIO_BC` / `KLIO_COUNTED` (bytecode tier; default-on since the
  static-dispatch campaign)
- `KLIO_COMPOSE_MEMO` / `KLIO_COMPOSE_SKIP` (plugin emission; the plugin
  is the only compose path)
- `KLIO_FUSED_MAT` / `KLIO_FUSED_MINPREFIX` (fold into the walker;
  `KLIO_FUSED=0` + the fqn name-list stay as the one permanent bisect)

Keep permanently (policy or active bisect, not soak): `KLIO_COMPOSE_FAST`
mask (caught the linkbuffer trap twice), `KLIO_MEMBER_INLINE` name-list,
`KLIO_JIT`/`KLIO_FUNC_JIT`, `KLIO_RECLAIM`, homes/caps/budgets, the GC
oracles (`KLIO_GC_STRESS`/`KLIO_GC_POISON`/`KLIO_GC_STW_AUDIT`), the
profilers, and the ~300 zero-cost `*_TRACE`/`*_AUDIT` diagnostics.

## Standing policy

- The vpd budget ratchet (650s, `src/itests/compose_plugin_commontest.zig`)
  is the permanent guard: every recomposition-throughput win must shrink
  it, it never grows.
- Serve additions stay above the reimplement-the-composer line; the
  measured-zero list and the traps live in
  `plans/concurrency-perf-campaigns.md` and the session memory — read
  them before touching a seam.
- Measure replicas with `KLIO_JIT=0` on the fast harness (gate parity);
  never read ReleaseSafe memset as allocation cost.
