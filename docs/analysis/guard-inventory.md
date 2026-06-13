# KLIO Guard / Special-Case Inventory

Status: read-only audit of the live Zig tree at `main`. Builds on
`docs/analysis/execution-architecture.md` (the three bug classes A/B/C, the
branch map §3, the unified design §4, the §6 roadmap). Every entry below is
grounded in a concrete `file:line` citation.

Scope reminder: a *guard* here is a point-fix branch / fallback / thread-local
that masks a specific instance of one of the three structural bug classes
instead of fixing the underlying handling. Per the project owner each such guard
is both a **removal target** (it should be deletable once the matching §6
structural work lands) and a **test signal** (removing it and keeping the suite +
differential harness green proves the real fix; a guard that cannot be removed
without breakage pinpoints remaining structural debt).

A guard's "removal test" names the passing signal that would prove it safe to
delete. Note up front: as `execution-architecture.md` §5.1/§6 records, the
differential harness (`src/itests/differential.zig`), the closures+suspend fuzzer
(`src/itests/fuzz_closures_suspend.zig`), and the single-path tracer do **not yet
exist**, and the nested-collision regression (`nested_name_collision.kt`) runs
only under the kotlinc-oracle parity sweep, **not** the default `zig build test`
target (it is absent from `itests_files`, `build.zig:48-62`). So most "removal
tests" below are *prospective* — they name the detector that §6 items 1–3 must
build first. Where a guard is covered by an existing in-tree itest today, that is
called out explicitly.

---

## Summary table

| Class | Guards catalogued | Deletable (point-fix) | Keep (load-bearing) | Needs-verification | Removed |
| --- | --- | --- | --- | --- | --- |
| A — closure execution / lambda variable access | 9 | 7 | 1 | 1 | 3 (A1, A2 via 4b; A5 via item 9) |
| B — receiver/`this` across suspend/inline | 14 | 8 | 1 | 2 | 4 (B1 via item 6; B2–B5 relocated onto the frame chain; B6, B7, B10 via the item-6 close-out) |
| C — pack-vs-direct resolution | 12 | 10 | 1 | 1 | 1 (C6 via item 9) |
| Other-correctness / re-entrancy | 7 | 0 | 6 | 0 | 1 (O3's duplicate copy collapsed; the guard itself stays) |
| **Total** | **42** | **25** | **9** | **4** | **9** |

(A guard counted "needs-verification" is also counted in exactly one of
deletable/keep per its best-current assessment; the four NV rows are A4, B9,
B13, C12. A1 and A2 are now REMOVED via §6 item 4b; A5 (a Class-C
two-executable-forms guard catalogued under Class A) and C6 are now REMOVED via
§6 item 9; B6, B7, B10 and O3's duplicate copy are now REMOVED via the item-6
receiver-context close-out — see their entries.)

The **keep list** (load-bearing branches that are NOT point-fixes and must not be
deleted) is consolidated at the bottom.

---

## Class A — Divergent closure execution (lambda variable access)

The root mechanism (`execution-architecture.md` §2 Class A): an `IrClosure` is
executed by three engines that disagree on capture store and env. These guards
are the seams and the fallbacks that paper over the disagreement.

### A1 — `scoped_env` name-seeding + write-back on the HOF path — REMOVED (4b)

- **Status:** REMOVED in §6 item **4b**. Both the `evalClosureRaw` and
  `invokeCallable` scoped-env setups (the `Env.withParent(globals)` seed, the
  swap-in as the host `globals`, and the post-run read-back into `info.captures`)
  are deleted. The HOF invoke path now runs the closure body over the real
  top-level env, exactly like the main value path. A captured-and-written outer
  `var` is boxed into a shared `Value.Cell` at its binding site (var decl,
  function/lambda parameter, or inline-splice parameter), so the write is a
  `CellSet` on the shared cell and is visible at the declaration site by
  reference — no name-seeded scratch env or capture read-back.
- **Was at:** `src/interp_ir/vm/intrinsic_host.zig` (the two scoped-env blocks).
- **Class:** A.
- **Verified by:** `zig build test` (1517/1517, incl. the differential harness
  byte-identical across SourcePacks/CompiledPacks, the closures+suspend fuzzer,
  `parity_closures_advanced`/`parity_closures_deep`, and the
  `captured_var_carrier` e2e), corpus 80/80, `KLIO_FUZZ_SEEDS=128`,
  `KLIO_TRACE_INVARIANTS=1` (0 violations). A prove-dead pass replaced the
  captured-`var` `StoreGlobal` emission with a hard panic across the full detector
  set; the only hit was a captured *function parameter*
  (`kotlinx-coroutines-core/.../channels/Deprecated.kt`'s
  `toMap(destination: M) { consumeEach { destination += it } }`), root-caused as a
  boxing gap — `computeBoxedVars` boxed only `var` decls, not parameters a nested
  closure writes — and fixed by boxing such parameters, not by restoring the guard.

### A2 — `StoreGlobal`-for-capture lowering (the write half of A1) — REMOVED (4b)

- **Status:** REMOVED in §6 item **4b**. The three `b.knowsOuter(...)` capture
  arms that recorded a capture, emitted `StoreGlobal name`, and rebound locally
  are deleted: `writeBackLvalue` (compound assignment), the postfix `++`/`--`
  path (both `src/ir/lower/expr.zig`), and `storeCombinedToTarget`
  (`src/ir/lower/stmt.zig`). A captured-and-written outer var now always reaches
  the boxed `CellSet` branch (boxed at its binding site). The now-dead capture
  write-back machinery is also removed: the `WritebackCaptures` instruction
  (`ir.zig` + its `eval.zig` handler), the `emitWritebacks`/`lowerCallWith*`
  capture-writeback emission, `Host.readLambdaCapture` (the eval vtable slot, its
  `vmhost.zig` wiring, and the `host_call_value.zig` impl), and
  `lambdaMutatedOuterVars` + its walkers. `StoreGlobal` itself is kept — it is
  still the legit instruction for genuine top-level-global `var` writes (the final
  `else` "top-level binding" arm) and the inline trampoline `tp_global`.
- **Was at:** `src/ir/lower/expr.zig`, `src/ir/lower/stmt.zig`.
- **Class:** A.
- **Verified by:** same gates as A1. A `KLIO_FUZZ_SEEDS=128`-wide prove-dead pass
  confirmed no non-boxed mutated outer var reaches the writeback emission before it
  was deleted.

### A3 — Receiver-lambda value rebuild on the main value path

- **Location:** `src/interp_ir/vm/host_call_value.zig:299-360` (the
  `!last_vararg and args.len == info.n_params + 1 and this_cap_idx != null`
  branch): clone the closure's captures, overwrite the `this` slot with `args[0]`,
  build a fresh `IrClosure` value, and re-dispatch on the main path.
- **What it does:** special-cases an `R.(P)->T` lambda invoked value-style with one
  extra leading arg, binding arg0 as the receiver by **mutating the value-carried
  capture snapshot** (which the main path reads and the HOF path ignores —
  `execution-architecture.md` §2 Class A "aggravating factor").
- **Class:** A (the divergent capture-store seam), with a B aspect (it also pushes
  the displaced `this` onto `outer_this`, see B1).
- **Deletable?** Deletable. A single `invokeClosure(id, args, this_override)`
  (§4.1) subsumes this: the receiver override is a routine parameter, not a value
  rebuild.
- **Removes via:** §6 item **4b** + **5** (one closure routine + thin adapter).
- **Removal test:** differential harness over the ktor/builder examples (the engine
  interceptor `interceptor.invoke(pipelineContext, subject)` case named in the
  comment) byte-identical across modes, plus `parity_lambdas_and_dispatch` and
  `parity_suspend_shapes` green.

### A4 — `callValueWithThis` main-path bind-and-redispatch

- **Location:** `src/interp_ir/vm/host_call_value.zig:424-451`: when the callee is
  an `IrClosure` with a `this` capture and exactly one extra leading arg, clone
  captures, set the `this` slot to `this_value`, and re-dispatch via `callValue`
  (the main path) instead of the intrinsic-host invoke below it.
- **What it does:** routes an explicit-receiver receiver-lambda call onto the
  frame-snapshotting main path so a `suspend` body parks correctly — duplicating
  A3's logic for the `CallValueWithThis` instruction.
- **Class:** A (capture-store seam) / B (suspend correctness motive).
- **Deletable?** **Needs-verification.** It is structurally the same point-fix as
  A3 and should fold into the same `invokeClosure`, but the comment claims a
  concrete behavioral dependency (ktor `on(Send)` `handler(Sender(this,…), request)`)
  whose differential coverage does not yet exist — confirm the unified routine
  reproduces it before deleting.
- **Removes via:** §6 item **4b** + **5**.
- **Removal test:** differential harness over the ktor send-pipeline example +
  `parity_suspend_shapes` green; verify the `Sender(this,…)` case parks/resumes
  identically.

### A5 — Pack-binding short-circuit inside `callValue` for a closure body — REMOVED (item 9)

- **Status:** REMOVED in §6 item **9**. The per-call
  `installed_bindings.resolve(func.fqn)` probe before running an `IrClosure` body
  is deleted. Each symbol's single executable form (native binding OR lowered
  body) is now resolved ONCE at link time by `ProgramImage.linkResolvedForms`
  into the `resolved_native` table keyed by `FuncId`. The closure-body path
  consults `host_call_func.resolvedNativeForm(self, func.id)` directly — no
  per-call FQN probe — so a closure wrapping a pack top-level fn
  (`kotlinx.datetime.__kxdt_*`) still dispatches the native binding, but the
  decision is fixed at link time and load-order-independent.
- **Was at:** `src/interp_ir/vm/host_call_value.zig` (the closure-body short-circuit block).
- **Class:** C primarily (two-executable-forms, `execution-architecture.md` §2
  Class C "Two executable forms"), surfaced inside the Class-A closure engine.
- **Verified by:** `KLIO_LINK_AUDIT=1` (the link form equals the per-call probe's
  pick — 0 divergences over the full suite + all 82 examples + the differential
  corpus), `zig build test` green, corpus 82/82, the differential harness
  byte-identical across SourcePacks/CompiledPacks/EmbeddedOnly.
- **Removal test:** differential harness with `mode=CompiledPacks` vs `SourcePacks`
  byte-identical for a `kotlinx.datetime`-using example.

### A6 — Capture-metadata recomputation in `buildClosure`

- **Location:** `src/interp_ir/vm/host_call_value.zig:484-507` (and the twin
  `buildAstLambdaWithFlagFuncid` `:510-527`): runtime re-reads `f.capture_order`
  to derive `n_params` + `capture_names`, then stores **both** a live cell
  (`info.captures`) and a value-carried snapshot (`caps_ref`).
- **What it does:** maintains the two-store duplication (cell + snapshot) that A1/A3
  exploit divergently; capture metadata is computed at lower time
  (`build.zig:435-458`) and again here.
- **Class:** A.
- **Deletable?** Deletable (the *duplication* is). One capture vector keyed by
  `capture_order` (§4.1 "one capture-metadata authority"); drop the snapshot.
- **Removes via:** §6 item **11** (single capture-metadata authority) + **4b**.
- **Removal test:** single-path tracer (§5.5) asserts one capture store per closure;
  full `itests` green (capture mis-binding by position would fail many).

### A7 — `Value.Lambda` dead AST-closure arms

- **Location:** the `.Lambda` tag is constructed only in two test sites
  (`src/runtime/runtime.zig` GC test, `src/typeck/check/tests.zig` typeck test per
  §3.6) yet is handled in **31** `.Lambda =>` switch arms across the tree (e.g.
  `host_call_member.zig:248,1513`, `host_call_value.zig:215,868`,
  `host_globals.zig:689,716`, `eval.zig:1177`, …).
- **What it does:** every callable-handling switch carries a dead arm for a value
  that the real pipeline never produces.
- **Class:** A (cleanup).
- **Deletable?** Deletable — but it is 31 arms + 2 test constructors, not a one-liner
  (§3.6 caution).
- **Removes via:** §6 item **11**.
- **Removal test:** remove the two test constructors and the 31 arms; `zig build
  test` compiles and stays green (1506 tests).

### A8 — Stub closure-shape predicates (`callableReceiverShape` etc.)

- **Location:** `src/interp_ir/vm/host_call_value.zig:529-545`:
  `callableReceiverShape` returns `null`, `closureNeedsThisCapture` returns
  `false`, `overrideClosureThis` is a no-op. Consumed by the `CallValue` arm
  (`eval.zig:1160-1172`).
- **What it does:** vestigial host methods for a closure-shape protocol that was
  never wired; the `CallValue` arm's receiver-lambda handling is effectively dead
  through these and relies on A3/A4 instead.
- **Class:** A (cleanup).
- **Deletable?** Deletable. Dead seams; the real receiver-lambda binding happens in
  A3/A4.
- **Removes via:** §6 item **4b**/**5** (cleanup alongside the unification).
- **Removal test:** delete the three stubs and their `eval.zig:1160-1172` callers;
  `itests` green.

### A9 — `isShadowingCapture` callable-only restriction

- **Location:** `src/interp_ir/vm/host_globals.zig:681-692`: returns true only when
  the innermost scoped-global layer binds the name to a `Lambda`/`IrClosure`/
  `Function`. Consumed by `execCallMemberOrGlobal` (`eval.zig:1643`).
- **What it does:** decides whether a bare name is a closed-over callable that
  shadows a same-named member — but only because the HOF path's `scoped_env` (A1)
  puts captures in a child layer in the first place. Path-dependent by
  construction (`hasParent()` is only true on the HOF path).
- **Class:** A.
- **Deletable?** Deletable once A1 is gone (globals always the real top-level env →
  `hasParent()` is uniformly false → this predicate degenerates).
- **Removes via:** §6 item **4b** (per §4.1: `isShadowingCapture` becomes
  path-independent).
- **Removal test:** with `scoped_env` deleted, `isShadowingCapture` returns a
  constant; `parity_closures_advanced`/`parity_functional_patterns` green.

---

## Class B — Receiver / `this` context lost across suspend / inline

Root mechanism (`execution-architecture.md` §2 Class B): the enclosing-`this`
chain and its companion resolution flags live in process-wide thread-locals that
are NOT part of `FrameSnapshot` (`eval.zig:149-167`), so they leak across a park
or a re-entrant dispatch.

### B1 — `outer_this` thread-local stack + two push helpers — REMOVED (item 6)

- **Status:** REMOVED in §6 item **6**. The `outer_this` thread-local, its lazy
  `outerThisStack` page-allocator init, and the run-boundary `resetReceiverTls`
  (plus its call site in `resetReceiverThreadLocals`) are deleted. The
  enclosing-`this` chain is now the current `Frame`'s `enclosing_this` field in
  `src/ir/eval.zig`: it is seeded at frame entry from the caller's active chain
  (so a frame inherits the enclosing implicit receivers a dispatch pushed),
  snapshotted into `FrameSnapshot.enclosing_this` on suspend, and restored
  verbatim in `resumeContinuation`. A thread-local `active_chain` pointer routes
  reads/pushes to the *currently executing* frame's field; it is never receiver
  state of its own (it always points at a live frame, or is `null` between
  runs), so a frame-scoped chain cannot leak past the frame or across a `run`
  boundary. The push helpers (`pushAccessEnclosing`/`popAccessEnclosing`/
  `pushOuterThis`/`popOuterThis`) and readers (`enclosingThis`/
  `enclosingThisChain`) are kept as thin wrappers delegating to the `ir.eval`
  frame-chain primitives, so all existing call sites are unchanged.
- **Was at:** `src/interp_ir/vm/host_call_member.zig` (the TLS + helpers).
- **Class:** B (the root carrier).
- **Verified by:** `examples/receiver_across_suspend.kt` (e2e corpus, byte-
  identical) and the `enclosing_this_chain_survives_suspend` itest — a `suspend`
  member-extension parks at `delay` then resolves a bare member of its enclosing
  `this@Owner` after resume; before the fix this reported `unresolved global
  'owned'`. Reverting the frame carrier (restoring the TLS) makes both fail.

### B2 — Push-enclosing around `Call` for an extension callee

- **Location:** `src/ir/eval.zig:1117-1135`: when the callee's first param is named
  `"this"`, push the caller's `this` param onto `outer_this` for the call, pop
  after.
- **What it does:** keeps the caller's receiver reachable while an extension /
  member-extension runs — a fallback that recovers the receiver the snapshot
  doesn't carry.
- **Class:** B.
- **Deletable?** Deletable. The dispatch sets the callee frame's receiver slot
  directly (§4.2).
- **Removes via:** §6 item **6**.
- **Removal test:** `parity_extension_resolution` + the fuzzer green with frame-
  receiver threading; no `outer_this` push at this site.

### B3 — Push-enclosing around `CallMember`

- **Location:** `src/ir/eval.zig:1261-1271`: push `frame.params[0]` (the caller's
  instance `this`) onto `outer_this` around a `recv.member()` call when distinct
  from the receiver.
- **What it does:** same as B2 for the member-call instruction.
- **Class:** B.
- **Deletable?** Deletable (same as B2).
- **Removes via:** §6 item **6**.
- **Removal test:** same as B2.

### B4 — Receiver-lambda enclosing pushes (main value path)

- **Location:** `src/interp_ir/vm/host_call_value.zig:339-358`: push the displaced
  `prior_this` and/or the receiver onto `outer_this` around the receiver-lambda
  re-dispatch (paired with A3).
- **What it does:** keeps the lexically-enclosing receiver reachable for bare
  members in the receiver-lambda body across the displacement.
- **Class:** B.
- **Deletable?** Deletable (folds into §4.2 frame receiver context once A3 is gone).
- **Removes via:** §6 item **6** (with **4b** for A3).
- **Removal test:** ktor engine-interceptor example differential identical; fuzzer
  green.

### B5 — Receiver-lambda enclosing pushes (intrinsic-host path)

- **Location:** `src/interp_ir/vm/intrinsic_host.zig:636-661` (`pushOuterThis`/
  `popOuterThis` around `invokeCallable`), and the same pattern in `callMember`'s
  `enclosingCallableProperty` branch `host_call_member.zig:1797-1813`.
- **What it does:** the HOF/`with`/`apply` twin of B4.
- **Class:** B.
- **Deletable?** Deletable (same as B4).
- **Removes via:** §6 item **5** + **6**.
- **Removal test:** `parity_functional_patterns` (`with`/`apply`/`run` with member
  calls) + fuzzer green.

### B6 — `member_only_probe` thread-local — REMOVED (item-6 close-out)

- **Status:** REMOVED. `member_only` is now an explicit parameter:
  `callMemberOnly` calls `callMemberNamedInner(..., member_only = true)`,
  which forwards it to `callMemberInner`; the public `callMember`/
  `callMemberNamed` host surface forwards `false`. The flag is scoped to one
  resolution by construction — it can no longer be stolen by a re-entrant
  `callMember` inside `copyNamed`/`stdlibNamedDispatch`/`userMethodNamed`
  (the old TLS was consumed-and-cleared by whichever dispatch read it
  first). `irMethodWalk`/`samInstanceDispatch`/`extensionFnFallback` already
  took it as a parameter.
- **Removal test (passing):** `parity_extension_resolution` (17 tests) green
  with `member_only` passed as a function arg; full suite + differential +
  single-path oracle green.

### B7 — `cc_explicit_read` thread-local (coroutineContext redirect) — REMOVED (item-6 close-out)

- **Status:** REMOVED. The flag is now a `suppress_cc_redirect: bool`
  parameter on `getFieldInner` (the public `getField` forwards `false`); the
  `$coroutineContext$explicit` sentinel arm calls the inner fn with `true`,
  and the flag is threaded through the fallback ladder's own recursion
  (including `withFieldResolvePair`) so the dynamic extent of one explicit
  read matches the old TLS window without being able to leak into a
  dispatched getter body.
- **Removal test (passing):** `parity_coroutines_realistic` /
  `parity_suspend_shapes` green with the flag threaded as a parameter.

### B8 — `field_resolve_stack` re-entrancy bound

- **Location:** `src/interp_ir/vm/host_fields.zig:67` (TLS), `withFieldResolvePair`
  `:95-117`, consumed at `:726,758`.
- **What it does:** `(instance id, field name)` stack bounding the heuristic
  `get_field` enclosing-receiver recursion. TLS, leakable across suspend.
- **Class:** B (TLS) — but the recursion it bounds only exists *because* field
  resolution falls back through the enclosing-`this` chain (B1).
- **Deletable?** Deletable once the enclosing chain is a frame field and field
  resolution no longer recurses through TLS-held receivers; the bound becomes
  unnecessary or a local set.
- **Removes via:** §6 item **6** (and the §4.3 single resolver removing the ad-hoc
  fallback ladder).
- **Removal test:** `parity_properties_accessors` + `parity_inner_classes` green
  with the stack removed; differential identical.

### B9 — `field_outer_active` re-entrancy flag

- **Location:** `src/interp_ir/vm/host_fields.zig:70` (TLS), used `:765-767`.
- **What it does:** prevents the inner-class outer-chain *field* fallback from
  recursing.
- **Class:** B (TLS) / other-correctness (loop prevention).
- **Deletable?** **Needs-verification.** Part guard-for-B1's-fallback, part genuine
  re-entrancy protection. Once the outer chain is structural (§4.2) the fallback
  it guards may vanish; but a loop-prevention flag for a legitimately recursive
  walk could remain necessary — confirm by removing it and checking the cyclic
  outer/companion fixtures (`parity_inner_classes`).
- **Removes via:** §6 item **6**.
- **Removal test:** `parity_inner_classes` + companion-with-cyclic-outer fixtures
  green after removal; if they loop, it is a keep (loop-prevention) reclassified
  toward C-style guards.

### B10 — `inner_outer_hint` thread-local — REMOVED (item-6 close-out)

- **Status:** REMOVED, and its replacement also fixed a live bug. The hint is
  now an `outer_hint: ?*const Value` parameter on `newInstanceNamed`,
  threaded through `newInstance` → `dispatchSecondaryCtor`/`superDelegation`
  (the same hint flows through nested shell constructions) →
  `primaryCtorPath` → `materializeInstance`; the `NewInstance` arm passes
  the frame's own `this` directly and the push/pop helpers, the `VmHost`
  aliases, and the NullHost stubs are deleted. `selectInnerOuter`
  (`host_instances.zig`) picks the outer by the inner class's lexically
  enclosing class (`registry.enclosing_class`), walking the receivers in
  scope at the construction site innermost-first the way kotlinc resolves
  the inner constructor's dispatch receiver: the hint itself, then the
  hint's class-nesting tower (`hint.outer`, `hint.outer.outer`, … — a
  member of `Inner` constructing a sibling `Inner()` reaches `this@Outer`
  through its own outer link, never through a receiver inherited from a
  caller frame), then the enclosing-receiver chain innermost-first where
  each dispatch-receiver entry carries its own tower but a `with`/`run`
  subject contributes only itself. Chain entries are tagged at the push
  site (`ir.eval.EnclosingEntry.is_subject`; the three receiver-lambda
  dispatch sites push the subject via `pushEnclosingSubject`/
  `pushOuterSubject`/`pushAccessEnclosingSubject` and the displaced prior
  `this` as a plain receiver), and the hint's tower walk is skipped when
  the hint IS the innermost subject (a displaced receiver-lambda `this`
  slot — its outers are not in scope; the lambda's lexical tower continues
  with the displaced entry on the chain). On the build side a lambda body
  lowering a bare `Inner()` to `NewInstance` records a `this` capture
  (kotlinc's `this$0`), keyed on `ir.Class.is_inner` — stamped both by
  `lowerClassWithExtras` and on the `reserveClass` stub so the rule is
  declaration-order independent — and the `NewInstance` arm sources the
  hint via `callerThisValue` (param or capture). This fixed
  `with(other) { Inner().show() }` inside an Outer member (previously
  ``Vm::get_field `tag` on `<instance>``: no lambda-side construction path
  stamped `outer`, and the getField rescue consults only the chain top),
  the same-named-subject shadowing variants, inner instances escaping HOF
  lambdas, user-HOF lambdas, two-level `inner` nesting, sibling `Inner()`
  construction from a member of Inner under a polluted caller chain, and
  forward-referenced sibling inner classes constructed from lambdas.
- **Removal test (passing):** `parity_inner_classes`
  (`inner_class_captures_outer_this`, `inner_class_constructed_inside_with_lambda`,
  `inner_class_constructed_inside_map_lambda`, `inner_class_escapes_lambda_with_outer`,
  `sibling_inner_construction_ignores_caller_receivers`,
  `later_declared_sibling_inner_class_from_lambda`,
  `with_subject_of_enclosing_class_supplies_outer`,
  `with_subject_outer_links_not_in_scope`,
  `with_unrelated_subject_in_inner_member_reaches_outer`)
  plus the suspend pins `inner_class_constructed_after_park` /
  `inner_class_in_receiver_lambda_after_park` /
  `sibling_inner_constructed_after_park` and `examples/inner_class_suspend.kt`.
  The sibling/`with`-subject expectations are confirmed against
  kotlinc-native 2.3.10 (the suspend variants via their sync shapes).

### B11 — Inline-receiver bound as a scope local `"this"`

- **Location:** `src/ir/lower/inline_call.zig:459-463`: an `inline fun` with a
  receiver binds the receiver as a builder scope local named `"this"` (a register),
  not a param named `"this"`.
- **What it does:** after inlining, the caller frame's `this` is a register, so the
  runtime `frameThisParam` scan (`eval.zig:1847-1852`) cannot see it and nested-
  receiver references fall back to `outer_this` (B1) — the inline variant of Class
  B (§2 Class B "Inline variant").
- **Class:** B.
- **Deletable?** Deletable. The inline splice should set the frame's receiver slot
  for the spliced region (§4.2 / §4.4-item-6), making inline-body resolution use
  the normal method-body path.
- **Removes via:** §6 item **10** (inline splice sets frame receiver slot).
- **Removal test:** differential over the builder-DSL/kotlinx itests (the gate §4.4
  requires for item 10) byte-identical; `parity_dsl_operators` green.

### B12 — `isLambdaBody()` forces `this`-capture in lambda bodies

- **Location:** `src/ir/lower/lambda_body.zig:66-72` (forward `this` through the
  lambda's own capture slot when `isLambdaBody()`), `src/ir/lower/expr.zig:1846`,
  `:1859`, `:2147`, `:2335` (`knowsOuter("this") or b.isLambdaBody()` →
  `recordCapture("this")`), `:2670` (`isLambdaBody()` → `CallMemberOrGlobal` with a
  captured `this_idx`).
- **What it does:** because a lambda's implicit `this` arrives via the closure's
  capture slot rather than a scope binding, lowering special-cases lambda bodies to
  capture `this` positionally. Pairs with the runtime `this`-capture readers.
- **Class:** B (receiver origin) — also a Class-C aggravator where the *same*
  `isLambdaBody()` predicate forks FQN resolution (see C11).
- **Deletable?** Deletable as a *special case* for `this`: with the frame receiver
  context (§4.2) a lambda body resolves `this` through the frame slot like any
  body, no positional-capture fork.
- **Removes via:** §6 item **6** (and **10** for the FQN-resolution facet, C11).
- **Removal test:** fuzzer (nested lambdas capturing receivers) + the full closures
  itests green with `this` resolved via the frame context.

### B13 — `callerThisValue` `.Instance`-only restriction

- **Location:** `src/ir/eval.zig:1856-1870` (and the same `== .Instance` gate at
  `:1858,1864`).
- **What it does:** recovers the frame receiver from a `this`-param or `this`-capture
  but **only when it is `.Instance`**, so primitive/`String` receivers in
  `with`/`apply` cannot thread through this path (§2 Class B).
- **Class:** B (a *correctness gap*, not a fallback that masks — but it is the
  point-restriction the structural fix removes).
- **Deletable?** **Needs-verification** as a deletion vs a *fix*. §4.2 explicitly
  says "Drop the `== .Instance` restriction so primitive/`String` receivers thread
  identically" — but dropping it standalone (without the frame receiver context)
  may change resolution for cases currently handled elsewhere; verify against a
  `with(5) { … }` / `"x".apply { … }`-style differential.
- **Removes via:** §6 item **6**.
- **Removal test:** a `with(primitive){}` / `String.apply{}` differential
  (`runWithPacks` vs `runWithKtc`) identical once the `.Instance` gate is gone and
  the receiver travels on the frame.

### B14 — `coroutine_time_mode_tls`

- **Location:** `src/interp_ir/interp_ir.zig:323` (TLS), setter/getter `:327,332`.
- **What it does:** holds the coroutine timing policy (Wall/Virtual) in a process-
  wide TLS, mutated as a side effect of driver setup; never reset between programs
  in a multi-program test binary (§2 Class B companion list).
- **Class:** B (TLS anti-pattern).
- **Deletable?** Deletable as a *thread-local* — carry the time mode on the
  coroutine driver/scope, not TLS.
- **Removes via:** §6 item **6** (companion TLS) + §5.2 reset asserts as interim.
- **Removal test:** §5.2 "TLS empty/reset between runs" debug assert holds across
  the coroutine itests run back-to-back; `parity_coroutines_realistic` green.

---

## Class C — Pack-vs-direct resolution divergence

Root mechanism (`execution-architecture.md` §2 Class C): every resolution table is
keyed by **bare simple name** and tie-broken by **declaration order**; packs are
the only thing that both add same-simple-name competitors from other packages and
get a fixed insertion position.

### C1 — `funcId` `first_user orelse first_body orelse first` tie-break — REMOVED as a resolution input (item 8 steps 2+3)

- **Status:** `isShippedFqn` is deleted; `funcId` ranks over the per-decl
  `Func.package` and survives only as the order-stable FALLBACK for shapes
  the symbol index defers on (extensions, overload sets). Resolution policy
  is the (package+imports)→FQN index (`resolveBareCallIndexed` /
  `resolveBareRefIndexed`), with a unique pick emitted as an exact
  `FuncId` on the instruction (`LoadGlobal.func`, `Call.func`) — no
  simple-name re-resolution at runtime. Out-of-scope (tier-5) index
  verdicts are now an unresolved-reference lowering error matching kotlinc.
  The stale-name-index rungs are deleted (item 8 close-out): `funcIdLegacy`
  and the `hasFuncNamed` `func_index` walk were proven unreachable — every
  build pipeline pairs each `func_index` append with a name-index push and
  the pack format never serializes a `Module`, and the instrumented sweep
  (`legacy_funcid`/`legacy_hasfunc` audit lines) logged 0 hits over the
  corpus + fixtures — so the name index is the single authority.
- **Was at:** `src/ir/ir.zig` (`funcId`/`funcIdLegacy`, `isShippedFqn`).
- **Class:** C.
- **Verified by:** `KLIO_RESOLVE_AUDIT`/`KLIO_RESOLVE_STRICT` sweeps (0
  unexplained divergences), both-orders cross-package itests in
  `itests/resolve_ambiguity.zig`, and the differential harness.

### C2 — `classId` first-by-simple-name — SUPERSEDED as a resolution input (item 8 steps 2+3)

- **Status:** bare construction and `::Ctor` reference sites resolve through
  `classIdIndexed` (caller package + imports) and carry the resolved
  `ClassId` end-to-end: `NewInstance` materializes by the IR class FQN
  against the FQN-keyed runtime class registry (authoritative FQN entries;
  first-wins user-over-shipped simple-name aliases), `addClass` no longer
  collapses a root-package class onto a packaged twin's slot, and the
  per-class side tables (ctor args, init blocks, secondary ctors, defaults,
  body-prop inits, delegates) are dual-keyed by FQN and read through the
  resolved identity. The simple-name `classId` remains only as the legacy
  fallback for synthesized shapes with no resolved id.
- **Class:** C.
- **Verified by:** both-orders cross-package class itests in
  `itests/resolve_ambiguity.zig` (ctor, `::Ctor`, `copy`, named-arg,
  data-class arity) + `itest-parity_inner_classes` green.

### C3 — Nested-type collision mangling (`Outer$Name`)

- **Location:** `src/interp_ir/build/lift.zig:240-241` (object), `:314-320` (nested
  class), keyed on `top_level_type_names` membership. Resolved on read by the
  mangled-singleton/class probes in `host_fields.zig:877-906`
  (`classReceiverField`).
- **What it does:** the **landed** point-fix for the "load-order bug" (§2 Class C
  "One instance of this class is fixed"): a nested `object`/`class` lifted to its
  bare top-level name would overwrite a same-named true top-level type; this mangles
  the colliding nested type to `Outer$Name`.
- **Class:** C.
- **Deletable?** Deletable — this is the archetypal point-fix that masks *one* family
  of collisions. The general FQN-keyed index (§4.4) makes the mangling unnecessary.
- **Removes via:** §6 item **8**.
- **Removal test:** with FQN-keyed resolution, delete the mangling;
  `nested_name_collision.kt` (top-level `Application.who()=="top-level"` vs
  `Holder.Application.who()=="nested"`) passes **unmodified** under the differential
  harness — the §2 root-cause-only requirement.

### C4 — VM bare-global `kotlin.*` prefix-probe ladder — REMOVED (item 8 steps 2+3)

- **Status:** REMOVED. The per-call prefix probe is replaced by the
  link-settled `ProgramImage.default_import_globals` map (one name→FQN edge,
  first package in `bare_probe_packages` order wins a cross-package
  collision — rank semantics unit-pinned, including the `StringBuilder`
  production collision and a synthetic two-package collision that fails on
  rank inversion).
- **Was at:** `src/interp_ir/vm/host_globals.zig` (the prefix list in
  `lookupGlobal`).
- **Class:** C.
- **Verified by:** the map unit tests in `interp_ir.zig` + differential
  byte-identical across modes.

### C5 — VM bare-global `installed_bindings` suffix scan — REMOVED (item 8 steps 2+3)

- **Status:** REMOVED. The hash-order `endsWith` scan is replaced by the
  link-settled `ProgramImage.pack_bare_aliases` map: package-level binding
  keys only (receiver-qualified member keys like
  `kotlinx.coroutines.Job.join` are excluded — a bare name can never mean
  one), lexicographically smallest FQN wins a collision, so the alias is
  hash-order independent. Both properties are unit-pinned.
- **Was at:** `src/interp_ir/vm/host_globals.zig` (the `installed_bindings`
  suffix scan in `lookupGlobal`).
- **Class:** C.
- **Verified by:** the alias unit tests in `interp_ir.zig` + differential
  `SourcePacks` vs `CompiledPacks` byte-identical.

### C6 — `callFunc` pack-binding FQN short-circuit — REMOVED (item 9)

- **Status:** REMOVED in §6 item **9**. The per-call branch that matched `f.fqn`
  against `installed_bindings` and `dispatchIntrinsic`'d instead of running the
  lowered body is deleted. `callFunc` now consults the link-time-resolved form
  (`host_call_func.resolvedNativeForm(self, func)` against the `resolved_native`
  table populated once by `ProgramImage.linkResolvedForms`) — native-binding vs
  lowered-body is no longer decided per call site, so the call no longer forks on
  pack-install state. The "two executable forms" of §2 Class C are collapsed to
  one form per symbol, settled at link time independent of load order.
- **Was at:** `src/interp_ir/vm/host_call_func.zig` (the "Pack-installed binding fast path" block).
- **Class:** C.
- **Verified by:** `KLIO_LINK_AUDIT=1` (the link form equals the per-call probe's
  pick — 0 divergences over the full suite + all 82 examples + the differential
  corpus), differential across modes byte-identical for a pack-shimmed function,
  `zig build test` green, corpus 82/82.

### C7 — `callFunc` mis-bound type-specialized-overload fallback

- **Location:** `src/interp_ir/vm/host_call_func.zig:468-491`: when the resolved
  body's concrete primitive param types mismatch the runtime args and a same-FQN
  intrinsic exists, dispatch the intrinsic.
- **What it does:** patches the case where a bare call lowered to a single FuncId
  bound the wrong type-specialized overload — a symptom of order-based resolution
  (C1) plus the lack of arg-type info at lower time.
- **Class:** C.
- **Deletable?** Deletable. With FQN/import-resolved calls and the §4.3 single
  resolver carrying arg types, the wrong overload is never bound.
- **Removes via:** §6 item **7** + **8**.
- **Removal test:** `parity_operator_edge_cases`/`parity_type_system_shapes` green
  without the fallback; differential identical.

### C8 — `callFunc` bodyless-`expect` sibling redirect + prefix probe

- **Location:** `src/interp_ir/vm/host_call_func.zig:493-533`: a bodyless `expect`
  decl redirects to a same-name same-arity body sibling, else probes the declared
  FQN, else the `kotlin.*` prefix list by simple name.
- **What it does:** resolves `expect`/`actual` and bodyless stdlib decls by simple
  name + order + prefix ladder.
- **Class:** C.
- **Deletable?** Deletable — the prefix-ladder portion folds into the FQN index
  (§4.4). The expect→actual link should be a build-time binding, not a runtime
  sibling scan.
- **Removes via:** §6 item **8**.
- **Removal test:** `parity_type_system_shapes` + multiplatform-shim examples green;
  differential identical.

### C9 — `irMethodWalk` dual-key (FQN then simple-name) class resolution

- **Location:** `src/interp_ir/vm/host_call_member.zig:3363-3380`: resolve the
  receiver's IR class by FQN for its own class (`first`), else fall back to a linear
  simple-name scan of `mod.classes`.
- **What it does:** the simple-name scan is what makes pack-mangled classes layout-
  sensitive (§3.4): a same-simple-name class from another pack can be hit by the
  scan.
- **Class:** C.
- **Deletable?** Deletable as the *simple-name scan* — keep the FQN resolution. The
  supertype walk should also resolve supertypes by FQN once the registry is
  FQN-keyed.
- **Removes via:** §6 item **8**.
- **Removal test:** differential over a program with same-simple-name classes in two
  packages; `parity_inheritance_dispatch` green.

### C10 — `instanceMethodWalkNamed` / `companion`* simple-name scans

- **Location:** `src/interp_ir/vm/host_call_member.zig:4247-4258`
  (`instanceMethodWalkNamed` linear `c.name`==cur scan), and the companion walks
  `classCompanionForward` `:3903-3929` / `instanceCompanionFallback` `:3931-3976`
  keyed on simple class name via `companion_singletons.get`.
- **What it does:** named-arg method resolution and companion forwarding both walk
  by bare class name.
- **Class:** C.
- **Deletable?** Deletable as resolution-by-simple-name (fold into the FQN-keyed
  registry). The walk *structure* (supertype traversal) is legitimate; the *key* is
  the guard.
- **Removes via:** §6 item **8**.
- **Removal test:** `parity_named_args_defaults` + `parity_properties_accessors`
  green; differential identical.

### C11 — `isLambdaBody()` forks FQN-head resolution — REMOVED (item 10)

- **Location (was):** `src/ir/lower/expr.zig` four sites, each a
  `(isPkgRoot(head) or !b.isLambdaBody())` gate on whether a dotted head lowers to a
  `LoadGlobal`-of-FQN vs a member/`this` walk.
- **What it did:** the same dotted path lowered differently inside a lambda; since
  pack/DSL code is consumed almost entirely through builder lambdas, this was a
  primary Class-C aggravator (§2 Class C "Aggravating factors").
- **Class:** C.
- **Removed (item 10).** `isLambdaBody()` is gone from all four resolution sites.
  Package-head vs receiver-member is now decided by the one principled predicate
  `headIsPackage(b, head)` (`expr.zig`): a head is a package head when it is a real
  package root (`isPkgRoot`) or names a package the program contributes a top-level
  symbol to (`Module.packageHeadDeclared` — `head.<rest>` is a declared FQN prefix
  over the complete phase-1 header set). A captured/local name or an enclosing-class
  member shadows a package head (the sites filter those with
  `resolve`/`knowsOuter`/`hasEnclosingMember`/`classId` guards). The same head
  resolves the same way regardless of lambda nesting — independent of declaration
  order and load mode. The inline splice already binds the inline body's receiver as
  a scope local named `"this"` (`inline_call.zig`), so inline-body dotted heads
  resolve through the same predicate without a lambda axis (no new frame-receiver
  slot needed at the splice).
- **Removal test:** the builder-DSL differential — `examples/dsl_dotted_head.kt`
  (package head + receiver-member dotted heads inside `@DslMarker` / `apply` / `with`
  receiver lambdas) and `tests/fixtures/coroutine_smoke/cs8_dotted_in_builder.kt`
  (`kotlin.math.*` dotted heads inside `flow`/`launch`/`coroutineScope` builders) —
  byte-identical across EmbeddedOnly / SourcePacks / CompiledPacks, plus the
  unmodified `parity_extension_resolution` / `parity_dsl_operators` /
  `parity_suspend_shapes` / `parity_inner_classes` / `parity_functional_patterns` /
  `parity_lambdas_and_dispatch` itests and `KLIO_RESOLVE_AUDIT`/`KLIO_LINK_AUDIT` =
  0 over the corpus.

### C12 — Inline-fn table keyed by bare simple name — FOLDED into the symbol index (item 8d)

- **Status:** bare-call inline resolution is index-first. The build driver
  registers every top-level `inline fun`'s AST under its phase-1 header
  stub's `FuncId` (`inline_state.registerInlineFnId`, called from the stub
  loop), and `inlineTargetForBareCall` (`src/ir/lower/expr.zig`) resolves the
  bare name through `resolveBareCallIndexed` FIRST: an inline winner splices
  exactly the resolved declaration (`tryInlineCallWithTypeArgs` now takes the
  resolved target), a non-inline winner suppresses the splice so the normal
  call path binds it, and a receiver-matched extension pick keeps the
  narrowing's choice (mirroring `preferredBareTarget`). The simple-name
  shape/receiver narrowing (`inlineFnAstFor*`) survives only as the
  tie-break for shapes the index defers on: extension forms, overload sets,
  default/vararg/trailing-lambda shapes, class/object member inline fns (no
  stub, never index-resolved), and class-method bodies lowered before the
  phase-1 headers exist. `shadowed_inline_names` no longer has its own
  construction: its name domain comes from `stdlib.noteBareNameMapping` —
  the same constructor behind the link-time `default_import_globals` /
  `any_member_globals` maps — over `IMPLICITLY_IMPORTED_PACKAGES`.
- **Location:** `src/ir/lower/inline_state.zig` (`inline_fn_asts` simple-name
  candidates, `inline_fn_ids` FuncId-keyed ASTs, `shadowed_inline_names`),
  `src/ir/lower/expr.zig` (`inlineTargetForBareCall`).
- **Class:** C (resolved).
- **Verified by:** the KLIO_RESOLVE_AUDIT `inline` records — one line per
  bare inline-candidate call comparing the old simple-name-first pick to the
  index-first pick on the splice that would actually occur, each divergence
  graded as a shape correction (the simple-name pick matches less exactly:
  vararg at ANY parameter position, a default, an arity mismatch) or a tier
  correction (the index pick ranks in a strictly better scope tier — e.g. a
  named import outranking a same-package reified inline namesake, a program
  property pinned strict-mode-on in `itests/resolve_ambiguity.zig`). Corpus +
  fixture sweep: 517,022 records, 0 unexplained divergences; 48 graded shape
  corrections, all at one root site (the four deprecated `combineLatest`
  bodies in kotlinx-coroutines `Migration.kt`, where the simple-name table —
  which only ever holds the inline overloads — spliced the reified vararg
  `combine` for calls whose exact-arity match is the non-inline
  `combine(flow, flow2, transform)`; the index pick is the kotlinc-correct
  binding, pinned fold-sensitively by the equal-arity vararg-vs-exact test
  in `itests/resolve_ambiguity.zig`, which fails under a name-first
  mutation). The surviving narrowing is receiver-aware in class methods:
  the enclosing class (falling back from the enclosing extension's
  receiver) matches candidate receivers through the transitive supertype
  chain (`registry.class_super_names` / `Module.classIsOrExtends`),
  nearest first, with the same subtype-aware receiver veto in the splice
  gate — `A.label`/`B.label` twins splice per enclosing class in either
  declaration order, a base-class extension accepts a subclass method's
  receiver, and the subclass's own extension outranks the base one
  (`itests/parity_extension_resolution.zig`). `KLIO_RESOLVE_STRICT`
  hard-fails an unexplained inline divergence. Differential (93 programs,
  all modes), `parity_advanced_idioms`, `parity_suspend_shapes`, coroutine
  smoke green.

---

## Other-correctness / re-entrancy (NOT primarily a guard — mostly keep)

These branches bound legitimate recursion or implement genuine protocol. They are
catalogued so nobody mistakes them for Class-A/B/C point-fixes; most are **keep**.

### O1 — `map_fallback_active` / `iterable_fallback_active`

- **Location:** `src/interp_ir/vm/host_call_member.zig:57,60`; used
  `:1821-1836,1839-1857`.
- **What it does:** prevents the user-`Map`/`Iterable` → builtin materialization
  fallback from re-entering itself while it drains the user collection (which calls
  back into `callMember`).
- **Class:** other-correctness (re-entrancy bound). It is *also* a TLS, so it shares
  Class B's "not reset between runs" hazard.
- **Deletable?** **Keep** the protection, but the TLS *mechanism* is deletable —
  pass the in-progress flag as a parameter of the drain call (§4.2 "guards become
  params"). Standalone deletion would infinitely recurse on a user Map/Iterable.
- **Hardened (item-6 close-out):** the set/clear windows are now
  `defer`-cleared blocks (a Zig error from the drain can no longer leak the
  flag), and `host_call_member.resetReceiverTls` Debug-asserts both flags
  false at every run boundary (wired into
  `vmhost.resetReceiverThreadLocals`) — previously the only TLS-holding VM
  module with no run-boundary assert.
- **Removes via:** a per-activation frame context (the drain recursion
  crosses the host→eval→host boundary, so the flag needs a carrier riding
  the activation, not a parameter of one call) — tracked with finding 12 in
  `deferred-findings.md`. §6 item 7 (the single resolver) is done and did
  not absorb it; not a resolution-class fix.
- **Removal test:** `parity_collections_intensive`/`parity_maps_intensive` with a
  user-defined `Map`/`Iterable`; must stay green (a regression would hang).

### O2 — `call_outer_active`

- **Location:** `src/interp_ir/vm/host_call_member.zig:3982-3987`.
- **What it does:** re-entrancy flag so a companion whose `outer` is its class (whose
  member lookup forwards back to the companion) cannot loop.
- **Class:** other-correctness.
- **Deletable?** **Keep** (loop prevention). The TLS→param conversion needs
  a per-activation frame context (§6 item 7 is done and did not absorb it;
  tracked with finding 12 in `deferred-findings.md`). Now asserted false at
  run boundaries via `host_call_member.resetReceiverTls` (item-6 close-out).
- **Removal test:** companion-outer cyclic fixtures in `parity_inner_classes` stay
  green.

### O3 — `ctor_guard` (was defined twice) — duplication REMOVED (item-6 close-out)

- **Status:** collapsed to ONE guard. The `host_globals.zig` copy had **no
  writer anywhere** (the shell pushes wrote `host_instances.zig`'s distinct
  threadlocal), so the deferred-`object` gate read in `lookupGlobal` was
  provably always false — a silently broken port of Rust's single shared
  `EXEC` thread-local. `host_instances.ctorGuardContains` is now `pub` and
  `host_globals.lookupGlobal` consults it, restoring the intended
  cross-file semantics; the dead copy, its reset lines, and its private
  `contains` are deleted.
- **Location:** `src/interp_ir/vm/host_instances.zig` (the one guard:
  push/pop around secondary-ctor shell construction, read as
  `shell_guarded` and by `host_globals.lookupGlobal`).
- **What it does:** a deferred `object` is only driven on-access when its own ctor is
  not already running; the same stack guards secondary-ctor shell dispatch.
- **Class:** other-correctness. The guard itself stays.
- **Removal test (passing):** `parity_properties_accessors` (object init
  order, incl. `object_self_reference_during_init`) green with one
  `ctor_guard`.

### O4 — `top_level_init_depth`

- **Location:** `src/interp_ir/vm/host_globals.zig:55-60`.
- **What it does:** a forward reference during startup re-drives the real top-level
  initializer rather than observing the `Null` placeholder.
- **Class:** other-correctness.
- **Deletable?** **Keep** (genuine init-order semantics); TLS→explicit driver state
  under §6 item 6.
- **Removal test:** startup forward-reference fixtures green.

### O5 — coroutine driver TLS (`coro_stack`, `active_scope_stack`, `persisted_parked`)

- **Location:** `src/interp_ir/vm/coroutines.zig:514,520,527`.
- **What it does:** the coroutine interceptor stack, active-scope stack, and
  indefinitely-parked continuation map — the real coroutine machinery.
- **Class:** other (genuine runtime state) — but per §2 Class B companion list it is
  the same "TLS, never reset between runs" hazard.
- **Deletable?** **Keep** the state; it should be owned by the driver and asserted
  empty between runs (§5.2), not deleted.
- **Removes via:** §5.2 reset asserts (interim) + §6 item 6 (own it on the driver).
- **Removal test:** §5.2 "TLS empty between runs" assert; `parity_coroutine_smoke`
  green run back-to-back.

### O6 — `materializeUserMap` / `drainIterableToList` fallbacks

- **Location:** `host_call_member.zig:611-658` / `:833-869`, the 1,000,000-iteration
  drain bound `:841`.
- **What it does:** materialize a user collection into a builtin so stdlib intrinsics
  apply. Legitimate protocol bridging (gated by O1).
- **Class:** other-correctness (legitimate-not-a-guard).
- **Deletable?** **Keep.** This is real interop behavior, not a masking fallback.

### O7 — `extensionFnFallback` `param[0]=="this"` admission + `member_ext_owner_class` gate

- **Location:** `src/interp_ir/vm/host_call_member.zig:3692-3711` (admit funcs whose
  first param is `"this"`, gate by `member_ext_owner_class`), the gate's twin in
  `userMemberExtShadows` `:3604-3621` and `resolveExtOverloadLocal` `:4197-4221`;
  the registry field `ir.zig:985`, populated `decl.zig:592`.
- **What it does:** the member-extension dispatch surface. `param[0]=="this"` admits
  both synthesized method receivers and synthesized extension receivers (the ktor
  double-`execute` root cause, §3.4); the `member_ext_owner_class` gate is what makes
  member-extension visibility work.
- **Class:** other / dispatch-taxonomy. This is the §4.3 "Caution": it is NOT a pure
  point-fix — collapsing "is in `class.methods`" ⇒ "not an extension" would drop the
  member-extension dispatch ktor relies on.
- **Deletable?** **Keep the behavior.** The member-extension *recognition* heuristic
  is now backed by a first-class registry kind (item 7): `Func.kind ==
  .member_extension` is authoritative via `isMemberExt`, and the five owner-gated
  dispatch sites route through `memberExtVisible`/`isMemberExt` in
  `host_call_member.zig` instead of probing `member_ext_owner_class` directly. The
  `param[0]=="this"` admission in `extensionFnFallback`/`resolveExtOverloadLocal`
  stays as the *candidate-shape* filter (it still admits top-level extensions and
  synthesized method receivers, which also lead with `"this"`); the kind only
  disambiguates which of those candidates are owner-gated member extensions. The
  `member_ext_owner_class` gate is preserved exactly — the side table is kept as
  the owner-class data source.
- **Removes via:** §6 item **7** (registry func-kind) — PARTIAL: kind landed and is
  authoritative for recognition + gating; the gate semantics are preserved, not
  removed.
- **Removal test:** `parity_extension_resolution` (17/17), `parity_inner_classes`
  (member-extension on outer / on `String`), `parity_dsl_operators`,
  `parity_functional_patterns` green under the kind-based scorer; differential
  identical across modes.

---

## Keep list (load-bearing — do NOT delete as "point-fixes")

These are branches that an over-eager guard-removal pass might mistake for
point-fixes. They implement real semantics or bound real recursion. The
structural roadmap *relocates* most (TLS→frame field / TLS→param / heuristic→
registry-kind) rather than deleting the behavior.

1. **`scoped_env` write-back (A1) / `StoreGlobal`-for-capture (A2)** — REMOVED in
   §6 item 4b (4a's precise captured-`var` carrier landed first, then 4b deleted
   both). No longer a keep entry; see the A1/A2 entries above.
2. **`map_fallback_active` / `iterable_fallback_active` (O1)** — the *flag* is a TLS
   to relocate, but the re-entrancy protection it provides is mandatory (infinite
   recursion otherwise).
3. **`call_outer_active` (O2)** — companion/outer cycle loop-prevention.
4. **`ctor_guard` (O3)** — object/secondary-ctor init guard; the duplicate is now
   collapsed (item-6 close-out), keep the one guard.
5. **`top_level_init_depth` (O4)** — forward-reference init-order semantics.
6. **Coroutine driver TLS (O5)** — genuine suspend/resume machinery; own-on-driver +
   reset-assert, do not delete.
7. **`materializeUserMap` / `drainIterableToList` (O6)** — real collection interop.
8. **`extensionFnFallback` member-extension gate (O7)** — the `member_ext_owner_class`
   gate is the load-bearing member-extension visibility mechanism (§4.3 caution);
   replace the `param[0]=="this"` heuristic with a registry kind, never drop the
   gate.
9. **`classIdByFqn` unambiguous-only resolution (`ir.zig:879-889`)** — already the
   *correct* FQN-keyed path (returns `null` on residual collision rather than
   binding the wrong class); it is the *destination* of the Class-C fix, not a
   guard. Keep and extend.

---

## Cross-cutting notes

- **The dead duplicate Host is already gone.** `execution-architecture.md`
  §3.3/§4.5/§6-item-0a calls for deleting `src/ir/eval/host.zig`; that file and the
  `src/ir/eval/` directory **do not exist** in the live tree (verified:
  `find src/ir/eval` → no such directory; the only `host.zig` files are
  `src/runtime/host.zig` and the VM host modules). §6 item 0a is therefore already
  satisfied — no guard to catalogue, but the roadmap entry should be marked done.

- **Detection scaffolding does not exist yet.** None of `src/itests/differential.zig`,
  `src/itests/fuzz_closures_suspend.zig`, or the `KLIO_TRACE_PATH`/
  `assert_single_path.py` tooling is present, and `nested_name_collision.kt` is not
  in `itests_files` (`build.zig:48-62`). The "removal test" column above is
  therefore mostly *prospective*: §6 items 1–3 must build these detectors before
  most guards can be proven safe to remove. The guards covered by an *existing*
  default-target itest today are B6 (`parity_extension_resolution`), B10
  (`parity_inner_classes`), O1 (`parity_maps_intensive`/`collections_intensive`),
  and the A1/A2 keep-condition (`parity_closures_advanced`/`closures_deep`).

- **TLS reset is the cheapest interim signal.** Per §5.2, a Debug-only "all of
  `outer_this` / `coro_stack` / `active_scope_stack` / `field_resolve_stack` /
  `ctor_guard` empty between runs" assert + `clearRetainingCapacity` would make the
  Class-B TLS leak a loud failure and make every differential result trustworthy —
  it is a prerequisite for trusting the removal tests of B1–B14, O1–O5.
