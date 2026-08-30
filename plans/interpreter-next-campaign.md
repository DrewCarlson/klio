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

Sequencing sketch (measure after every stage; the ratchet banks wins):
1. Shape layout + guarded field access for a closed set of hot classes
   (compose's slot-table/changelist family is the measured target).
2. Monomorphic call specialization over the same set.
3. Unboxed locals inside a compiled body.
4. Widen by profile, not by ambition.

Exit: vpd budget ratchets down with each landed stage; the tier is a win
only if the CLOCK moves (the closed campaign's "activation cut does not
imply a wall win" rule applies in full).

Unblocked by this tier (recorded in the closed plan): A2/A3-style AOT
registration, B3 typed storage, Value 5c re-evaluation.

## Task 2 — transpiler speedup: the frozen scalar hot-view sub-ABI

Already specified in `plans/c-transpiler-plan.md` § "Next: the speedup
campaign (open)". Independent of Task 1 (targets numeric/scalar code the
interpreter runs 1.32x slower than transpiled today, not compose
dispatch). Work it as written there.

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
