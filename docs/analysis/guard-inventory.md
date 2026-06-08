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
| A — closure execution / lambda variable access | 9 | 7 | 1 | 1 | 2 (A1, A2 via 4b) |
| B — receiver/`this` across suspend/inline | 14 | 11 | 1 | 2 | 0 |
| C — pack-vs-direct resolution | 12 | 10 | 1 | 1 | 0 |
| Other-correctness / re-entrancy | 7 | 1 | 6 | 0 | 0 |
| **Total** | **42** | **29** | **9** | **4** | **2** |

(A guard counted "needs-verification" is also counted in exactly one of
deletable/keep per its best-current assessment; the four NV rows are A4, B9,
B13, C12. A1 and A2 are now REMOVED via §6 item 4b — see their entries.)

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

### A5 — Pack-binding short-circuit inside `callValue` for a closure body

- **Location:** `src/interp_ir/vm/host_call_value.zig:274-282`: before running an
  `IrClosure` body, probe `installed_bindings.resolve(func.fqn)` and
  `dispatchIntrinsic` instead of the lowered body.
- **What it does:** a closure wrapping a pack top-level fn (`kotlinx.datetime.__kxdt_*`)
  runs the native binding rather than the shim body.
- **Class:** C primarily (two-executable-forms, `execution-architecture.md` §2
  Class C "Two executable forms"), surfacing inside the Class-A closure engine.
- **Deletable?** Deletable. §4.4-item-5 binds each symbol to one executable form at
  link time, so no per-call FQN short-circuit is needed.
- **Removes via:** §6 item **9** (one executable form per symbol).
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
- **What it does:** vestigial vtable seams for a closure-shape protocol that was
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

### B1 — `outer_this` thread-local stack + two push helpers

- **Location:** `src/interp_ir/vm/host_call_member.zig:65-73` (the TLS + lazy
  page-allocator init), push/pop helpers `:893-916` (`pushAccessEnclosing`/
  `popAccessEnclosing`/`pushOuterThis`/`popOuterThis`), readers
  `enclosingThis`/`enclosingThisChain` `:875-891`.
- **What it does:** the entire enclosing-`this` mechanism — one backing store, two
  push helpers (VmHost-handle vs allocator-only), read by every implicit-receiver
  fallback. Not in `FrameSnapshot`.
- **Class:** B (the root carrier).
- **Deletable?** Deletable. Replaced by a `ReceiverContext` field on `Frame` and
  `FrameSnapshot` (§4.2).
- **Removes via:** §6 item **6**.
- **Removal test:** the closures+suspend fuzzer (§5.4) — a `this@Outer` needed only
  via `outer_this` across a real `delay`/park resolves identically pre- and
  post-suspend; differential `runWithPacks` vs `runWithKtc` identical.

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

### B6 — `member_only_probe` thread-local

- **Location:** `src/interp_ir/vm/host_call_member.zig:54` (TLS),
  captured-and-cleared at `:1303-1304`, set/restored in `callMemberOnly`
  `:4054-4057`, consumed by `irMethodWalk`/`extensionFnFallback`
  (`:1490,1663,1704`).
- **What it does:** a hidden boolean channel implementing Kotlin's
  member-vs-extension precedence (member-only resolution defers a SAM-lambda
  member to an extension). Leakable across a re-entrant dispatch / suspend like
  any TLS.
- **Class:** B (TLS anti-pattern) / A-B dispatch order.
- **Deletable?** Deletable as a *thread-local* — becomes an explicit parameter on
  the resolver (§4.2 "guards become params", §4.3 one resolver).
- **Removes via:** §6 item **7** (single resolver) + **6**.
- **Removal test:** `parity_extension_resolution` green with `member_only` passed as
  a function arg; single-path tracer shows deterministic member-vs-ext choice.

### B7 — `cc_explicit_read` thread-local (coroutineContext redirect)

- **Location:** `src/interp_ir/vm/host_fields.zig:62` (TLS), set/cleared
  `:296-299`, consumed `:322`.
- **What it does:** suppresses the suspend-implicit `coroutineContext` redirect for
  one explicit `recv.coroutineContext` read. Transient resolution state in TLS.
- **Class:** B.
- **Deletable?** Deletable as a TLS — pass an explicit-read flag down the field-read
  call, or lower the explicit form to a distinct instruction that needs no flag.
- **Removes via:** §6 item **6** (guards → params).
- **Removal test:** `parity_coroutines_realistic` / `parity_suspend_shapes` green
  with the flag threaded as a parameter.

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

### B10 — `inner_outer_hint` thread-local

- **Location:** `src/interp_ir/vm/host_instances.zig:62` (TLS), push/pop/read
  `:79-91`, consumed when stamping a new inner instance's `outer` `:1827-1831`;
  wired into the eval vtable `vmhost.zig:289-290`, `eval.zig:2543-2544,2781-2785`.
- **What it does:** a separate TLS carrying the outer receiver for inner-class
  construction — a *fourth* receiver origin alongside the three in §3.5.
- **Class:** B.
- **Deletable?** Deletable. Folds into the one `ReceiverContext` (§4.2 "Eliminate
  the `outer_this` and `inner_outer_hint` thread-locals").
- **Removes via:** §6 item **6**.
- **Removal test:** `parity_inner_classes` (`inner_class_captures_outer_this`,
  already in tree) green with the hint sourced from the frame receiver context.

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

### C1 — `funcId` `first_user orelse first_body orelse first` tie-break

- **Location:** `src/ir/ir.zig:779-802` (and the legacy twin `funcIdLegacy`
  `:804-816`), keyed on `isShippedFqn` (`:936-943`).
- **What it does:** resolves a bare function name by declaration order, preferring
  the first non-shipped FQN. A pack outside `kotlin.`/`kotlinx.`/`java.` counts as
  "user" and, concatenated first, wins over the user's same-named function.
- **Class:** C (the core order-sensitive resolver).
- **Deletable?** Deletable as resolution policy — replaced by the
  (package+imports)→FQN index (§4.4). `isShippedFqn` is dropped only after the
  uniqueness proof (§4.4-item-3); do **not** tighten early or currently-passing
  programs become ambiguity errors (the §4.4 caution).
- **Removes via:** §6 item **8**.
- **Removal test:** differential harness over every `examples/*.kt` byte-identical
  across modes *and* each bare call proven to resolve to a unique FQN target before
  `isShippedFqn` is removed.

### C2 — `classId` first-by-simple-name

- **Location:** `src/ir/ir.zig:748-753`.
- **What it does:** returns the FIRST `class_index` entry matching a simple name;
  same-simple-name/different-FQN classes are stored distinctly (`addClass`
  `:842-867`) but unreachable from a bare reference.
- **Class:** C.
- **Deletable?** Deletable as the *bare-name* path — superseded by FQN-keyed
  resolution (`classIdByFqn` already exists, `:879-889`). The simple-name `classId`
  stays only as a last-resort until §4.4 uniqueness holds.
- **Removes via:** §6 item **8**.
- **Removal test:** `nested_name_collision.kt` (must move into `itests_files` via the
  differential harness, §5.1) + differential green.

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

### C4 — VM bare-global `kotlin.*` prefix-probe ladder

- **Location:** `src/interp_ir/vm/host_globals.zig:436-467`: a fixed list of
  `kotlin.*` prefixes probed in order to resolve a bare name to an intrinsic.
- **What it does:** hard-codes resolution order for stdlib top-level functions/
  consts (`min`→`kotlin.math.min`) — order-sensitive, package-agnostic.
- **Class:** C.
- **Deletable?** Deletable. §4.4-item-4: exact `funcIdByFqn`/`installed_bindings.resolve(fqn)`
  with NO prefix ladder once lowering emits FQN-qualified loads.
- **Removes via:** §6 item **8**.
- **Removal test:** differential identical; `parity_strings_numbers`/
  `parity_ranges_arrays` green with FQN-qualified `LoadGlobal`.

### C5 — VM bare-global `installed_bindings` suffix scan

- **Location:** `src/interp_ir/vm/host_globals.zig:469-486`: scan every
  `installed_bindings` key for one ending in `.{name}`, returning the first
  hash-map hit (iteration-order nondeterministic).
- **What it does:** resolves a bare name against any pack binding whose FQN ends in
  the name — the most order/iteration-sensitive resolver in the tree (§2 Class C).
- **Class:** C.
- **Deletable?** Deletable (same as C4).
- **Removes via:** §6 item **8**.
- **Removal test:** differential `SourcePacks` vs `CompiledPacks` byte-identical (a
  HashMap-iteration-order divergence would show here first).

### C6 — `callFunc` pack-binding FQN short-circuit

- **Location:** `src/interp_ir/vm/host_call_func.zig:456-466`: if `f.fqn` matches an
  `installed_bindings` entry, `dispatchIntrinsic` instead of running the lowered
  body (the "two executable forms" of §2 Class C).
- **What it does:** picks native-binding-vs-lowered-body per call site based on
  pack-install state.
- **Class:** C.
- **Deletable?** Deletable. §4.4-item-5: bind one executable form per symbol at link
  time; remove the per-call short-circuit.
- **Removes via:** §6 item **9**.
- **Removal test:** differential across modes identical for a pack-shimmed function
  (the form is fixed at link, so the call site no longer forks).

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

### C11 — `isLambdaBody()` forks FQN-head resolution

- **Location:** `src/ir/lower/expr.zig:867`, `:1058`, `:2897`, `:2956` (each a
  `(isPkgRoot(head) or !b.isLambdaBody())` gate on whether a dotted head lowers to a
  `LoadGlobal`-of-FQN vs a member/`this` walk).
- **What it does:** the same dotted path lowers differently inside a lambda; since
  pack/DSL code is consumed almost entirely through builder lambdas, this is a
  primary Class-C aggravator (§2 Class C "Aggravating factors").
- **Class:** C (with the B facet at B12 for the `this` capture).
- **Deletable?** Deletable as a *resolution axis* — package-head vs receiver-member
  is decided by resolving the head against caller imports/package + lexical capture
  set (§4.4-item-6), one predicate, no lambda special case. **Broad behavioral
  change**, must be gated behind a builder-DSL differential pass (§4.4 caution; §6
  item 10 risk).
- **Removes via:** §6 item **10**.
- **Removal test:** builder-DSL-heavy differential (kotlinx/ktor builder itests +
  examples) byte-identical with `isLambdaBody` removed from these four sites.

### C12 — Inline-fn table keyed by bare simple name

- **Location:** `src/ir/lower/inline_state.zig:31` (`inline_fn_asts` StringHashMap),
  `:38` (`shadowed_inline_names`), candidate lookup `:90-99`.
- **What it does:** a process-global inline-fn table keyed by bare simple name,
  merged across packs + user; a pack `inline fun foo` and a user `inline fun foo`
  share one bucket, tie-broken by shape/order (§2 Class C). `shadowed_inline_names`
  is itself a point-fix preventing inline expansion from shadowing default-import
  resolution.
- **Class:** C.
- **Deletable?** **Needs-verification.** The simple-name keying is a Class-C guard
  that should fold into the §4.4 FQN index (§4.4-item-4 "Fold inline-fn resolution
  into the same entry point"). But these are *also* build-scoped thread-locals
  (a B-style anti-pattern) and the suspend-inline machinery has real constraints
  (`inline_state.zig:25-30`); verify the FQN-keyed inline resolution preserves
  suspend-inline correctness before deleting `shadowed_inline_names`.
- **Removes via:** §6 item **8** (+ **7** for one resolver).
- **Removal test:** differential over a program with same-simple-name `inline fun`s
  in two packages; `parity_advanced_idioms` (inline idioms) green.

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
- **Removes via:** §6 item **6** (TLS→param), not a resolution-class fix.
- **Removal test:** `parity_collections_intensive`/`parity_maps_intensive` with a
  user-defined `Map`/`Iterable`; must stay green (a regression would hang).

### O2 — `call_outer_active`

- **Location:** `src/interp_ir/vm/host_call_member.zig:3982-3987`.
- **What it does:** re-entrancy flag so a companion whose `outer` is its class (whose
  member lookup forwards back to the companion) cannot loop.
- **Class:** other-correctness.
- **Deletable?** **Keep** (loop prevention); TLS→param under §6 item 6.
- **Removal test:** companion-outer cyclic fixtures in `parity_inner_classes` stay
  green.

### O3 — `ctor_guard` (defined twice)

- **Location:** `src/interp_ir/vm/host_globals.zig:54` AND
  `src/interp_ir/vm/host_instances.zig:61` — two independent TLS stacks of the same
  name; consumed `host_instances.zig:1020` (`shell_guarded`) and
  `host_globals.zig:63-68`.
- **What it does:** a deferred `object` is only driven on-access when its own ctor is
  not already running; the instances copy guards secondary-ctor dispatch.
- **Class:** other-correctness — but the **duplication** is a defect (§4.2 "Collapse
  the duplicate `ctor_guard`").
- **Deletable?** **Keep** the guard; **delete the duplication** (collapse to one).
- **Removes via:** §6 item **6**.
- **Removal test:** `parity_properties_accessors` (object init order) green with one
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
- **Deletable?** **Keep the behavior**; replace the *heuristic* (`param[0]=="this"`)
  with an explicit registry func-kind where `member-extension` is a first-class
  category (§4.3). Do not delete the `member_ext_owner_class` gate without the kind
  field.
- **Removes via:** §6 item **7** (registry func-kind), preserving the gate semantics.
- **Removal test:** the ktor builder itests (member-extension `with(a){ memberExtFn() }`)
  green under the kind-based scorer; differential identical.

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
4. **`ctor_guard` (O3)** — object/secondary-ctor init guard; *collapse the duplicate*
   but keep the guard.
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
