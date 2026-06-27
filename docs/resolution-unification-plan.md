# Dispatch & Name-Resolution Unification

Goal: one source of truth for "what does this name resolve to" and one execution
path, regardless of run-vs-test, pack-vs-source-vs-stdlib, or inline-vs-regular.
Stdlib code is functional from the stdlib pack and resolves exactly like user code;
native intrinsics exist only as the backing implementation of a stdlib declaration
reached through the normal resolved symbol, never as a parallel resolution path or a
name-list shortcut. No escape hatches for stdlib in the interpreter.

This plan supersedes the earlier RC-1..RC-5 sketch. Every root cause below was
confirmed against the current code with a live reproduction (the repro names are the
verification ratchet in the phase plan).

## Root causes

- **RC-A — no canonical index.** There is no single signature index over all
  provenances populated before any body lowers. `func_name_index` is built in the
  wrong order and consulted while incomplete. Within a single build, class bodies
  lower (`interp_ir/build.zig:1470`) before the phase-1 header loop (`:1489-1561`),
  so `funcsBySimpleName`/`funcId`/`decl_user_arity` are empty for user top-level
  funcs when any class method (including a `@Test` method) lowers. The `klio run`
  extend path pre-seeds the index via `cloneForExtend` (which *does* carry
  `func_index`, `ir.zig:1142-1150`), masking the bug for stdlib names; `klio test`
  goes straight to `buildModuleFiles` with no pre-seed, exposing it for everything.
  Members and inline members get no arity-queryable index entry at all. The index is
  consulted as a refiner, not a primary, so even when complete it cannot bind a
  target the heuristic ladder declined. *This is the true root of run-vs-test
  divergence — not the base->extend handoff the old plan blamed.*
  Evidence: `factRun`; measured 5 `func_index` entries during user-body lowering.

- **RC-B — no shared, type-aware applicability.** Applicability/overload matching is
  reimplemented at least three times (lowering ladder, runtime global scorer, runtime
  member scorer) with no shared core, and the lowering ladder is **arity-only and
  type-blind**. `shadowedByClass` + `findCand`/`arityMatch` (`expr.zig:4324-4364`)
  bind `Box(5)` to `fun Box(String)`; only `overload_match.zig:124`
  `builtinKindMismatch` rejects it at runtime, and only when the call deferred (empty
  index). The runtime re-rank (`pickOverloadCached`, `host_call_func.zig:1266`) is a
  safety net, not a fix: bypassed by exact casts (`eval.zig:2586`), `TailCallFunc`
  (no re-pick), and any lowering-only decision (class-vs-factory). `src/ir/applicability.zig`
  does not exist. Evidence: `factRun` (crashes under run, passes under test).

- **RC-C — member-vs-global by a program-wide name set.** The decision uses
  `class_member_names` (a union over ALL pack+user classes) plus `inReceiverContext`,
  not the enclosing receiver TYPE's actual members. Six gate sites
  (`expr.zig:1099,3804,3961,4521,4931,4979`). `inReceiverContext` is true for any
  method body, false for top-level `main`, so identical bodies lower to different IR
  under run vs test. `emitBareFuncCall` deliberately discards a statically-resolved
  FuncId and defers to runtime, so run==test output only because the runtime probe
  re-derives the answer. The `de327622` arity-aware `prefer_member` fix closed the
  0-arg-member-shadows-1-arg-global case but not the structural over-broadness.
  Evidence: `crossmember.kt`.

- **RC-D — name-keyed field storage.** `InstanceData.fields` is a flat
  `ArrayList(Field{name,value})` keyed by name only (`class.zig:318-353`);
  `define` overwrites. A subclass field with a parent's name destroys/aliases the
  parent's backing cell (`materializeInstance` writes bottom-up,
  `host_instances.zig:2378-2422`). Kotlin needs two distinct backing fields keyed by
  (declaring class, name) for a shadow, but one shared cell for an override. The
  current model cannot represent the distinction. This is a value-layer root cause
  below the dispatch layer; it reproduces byte-identically run-vs-test. Evidence:
  `c_shadow` prints 2/2/2/2, expected 1/2/1/1.

- **RC-E — non-final vararg on the positional path.** The positional dispatch path
  packs varargs only when the vararg is the LAST parameter (`packVarargArgs`,
  `host_call_func.zig:93`; member twin `host_call_member.zig:374`). A non-final
  vararg followed by a defaulted param crashes on a purely-positional call (pads the
  trailing default first, then the packer no-ops, leaving an unpacked Int in the
  vararg slot). The named binder `callFuncNamed` handles mid-list varargs correctly;
  the two binders disagree on a Kotlin-legal shape. Evidence: `e_vararg`
  (`report("T4",6,7,8)` crashes; adding any named arg fixes it).

- **RC-F — reified inference is return-type-only.** `inferReifiedTypeArgs`
  (`inline_call.zig:276-313`) unifies only `f.return_type` against the expected type,
  never value-parameter types, so a reified `T` inferable only from a lambda
  parameter annotation stays unbound and `x is T` degenerates to always-true.
  Evidence: `j2` (`classify(7){ s: String -> s }` prints `is`, expected `no`).

- **RC-G — typeck resolution discarded.** Typeck resolves overloads internally
  (`checkOverloadedCall` picks a `*const FnSig`) but never records the target;
  `TypeCheck` exposes no `Span->FuncId` map (`check.zig:72-88`), and `klio run`/`test`
  never invoke typecheck. Three overload oracles (typeck Type-based, lowering
  arity+tier, runtime value-class) share no resolved-symbol channel; a call can be
  type-checked against one overload and executed against another with no diagnostic.

- **RC-H — hatch name-lists.** A web of hardcoded name-lists papers over the seams
  left by RC-A and RC-B: `isAliasName` (41 names, 4 gate sites), two near-duplicate
  inconsistent builtin-supertype tables (`builtinSupersFor` vs `builtinHeadAccepts`),
  three inconsistent Throwable lists, the `concreteSibling` same-simple-name abstract
  redirect, `tailrec_fn_names`, `shadowed_inline_names`, `isPrimitiveConv`,
  `CONTROL_INTRINSICS`. These are CLAUDE.md-forbidden symptom-hiding. They exist only
  because the index is incomplete and applicability is not shared/type-aware; deleting
  them is the proof those fixes are complete.

## Target architecture

1. **One canonical signature index (RC-A).** A per-FuncId `DeclSig` in `ir.zig`
   (subsuming `decl_user_arity`/`decl_user_sig`/`decl_user_params`): `{ fqn, package,
   simple_name, kind: {top_level,member,ctor,factory,extension}, enclosing_class,
   receiver_ty, params: []ParamSig{name, ty, has_default, is_vararg, is_function_typed},
   type_params: []{name, is_reified}, is_inline, is_suspend, low_priority }`.
   `ParamSig.ty` rendered by the same `loweredTypeRef` phase-1 already uses. A new
   **phase 0** in `buildModuleWithOverrides` registers a `DeclSig` for every
   declaration — top-level funcs, constructors (keyed by class simple name), member
   methods (signatures only), inline funcs (top-level and member) — BEFORE the
   class-lowering loop and phase-1. Three phases: (0) sig registration over all decls,
   (1) class body lowering, (2) top-level body lowering. Member+ctor sigs baked into
   the image. `runTestFiles` routed through the same extend/image assembly as `run`.
   After this, `funcsBySimpleName` returns the full source+pack+stdlib+inline+member+ctor
   candidate set in every entry point, order-independent.

2. **One type-aware applicability function (RC-B, RC-E).** New `src/ir/applicability.zig`:
   `pub fn applicable(sig, args: []const ArgShape, scope) ?Score`. `ArgShape = { ty:
   ?TypeRef, is_lambda, lambda_arity, lambda_param_types, is_named: ?[]const u8,
   is_spread }`, populated from lowering (lowered expr type / literal kind), runtime
   (value class name), or typeck (checked Type lowered to TypeRef). `applicable` folds
   in one place: named-arg-to-distinct-param, default padding, vararg packing at ANY
   position, trailing-lambda-out-of-sequence binding to the last function-typed param,
   and per-arg type scoring (lifting `overloadScoreArg` + `builtinKindMismatch`).
   The two builtin-supertype tables merge into one canonical relation derived from the
   class hierarchy where possible. Three callers, one function: lowering's
   `resolveCall`, runtime `pickOverload`/`pickMethodOverload`, typeck `checkOverloadedCall`.

3. **`Module.resolveCall` — one resolver, index primary (RC-A, RC-B).** Replaces the
   two-oracle asymmetry. Tiers candidates by Kotlin scope (`bareCallTier`), ranks the
   best non-empty tier by `applicable`, returns `Resolution{ target: FuncId,
   confidence: {exact, runtime_polymorphic}, candidate_set }`. A unique best -> resolved
   `Call`. A genuine tie or runtime-only receiver -> `CallMemberOrGlobal` carrying the
   candidate set (not a name probe). The heuristic ladder, `preferredBareTarget`,
   `resolveBareCallIndexed`-as-refiner, and the inline-vs-noninline split all collapse
   into this. Constructors are ordinary candidates, so class-vs-factory is a normal
   overload set, not a `shadowedByClass` branch.

4. **Member-vs-global by enclosing-receiver type (RC-C).** Delete `class_member_names`
   (registry field + 6 gate sites) and the `inReceiverContext` switch as the
   discriminator. A bare call inside a method queries the enclosing receiver type's
   member set via the sig index (`kind==member && enclosing_class==this_class`, walking
   the receiver's supertype closure by ClassId). Member-shadowable iff THIS receiver
   type (or a supertype) has an applicable member of that name+shape. Pure function of
   (call-site receiver type, sig index); independent of main-vs-`@Test`.
   `emitBareFuncCall`'s downgrade is deleted. `CallMemberOrGlobal` survives only for
   genuinely runtime-polymorphic receivers.

5. **Distinct-keyed inherited fields + super/method-walk fixes (RC-D).** Change
   `InstanceData.Field` key from name to `(declaring_class: ClassId, name)`. `get/set/
   define` take an optional declaring-class qualifier. An override writes under the
   most-derived class only (one cell — preserves override semantics); a shadow writes a
   separate cell keyed by its own declaring class (override-vs-shadow detected at
   construction via the `override` modifier). A bare `x` in a method of class C resolves
   to the C-or-nearest-supertype-that-declares-stored-`x` cell; `super.x` reads the
   parent's cell; external `(b as Base).x` reads via the static type. Also fix
   `firstSupertypeName` to skip interfaces (`host_call_member.zig:6901`, the
   `super.method` bug) and FQN-qualify the method walk after the first hop.

6. **Position-agnostic vararg packing (RC-E).** Unify the positional and named binders
   onto `applicability.zig`'s position-agnostic bind step; `internArgNames` stops
   collapsing all-positional to empty for a non-final-vararg sig. Deletes the
   positional/named divergence.

7. **Reified inference from parameter positions (RC-F).** Extend `inferReifiedTypeArgs`
   to unify each declared value-parameter type (recursing into function-typed params'
   parameter lists) against actual argument / lambda-parameter-annotation types before
   the return-type fallback. Reuse `unifyTypeParam`.

8. **Typeck records + reuses resolution (RC-G).** Add `TypeCheck.resolved_calls:
   Span->FuncId`. `checkOverloadedCall` calls the shared `resolveCall`/`applicable`
   over the assembled sig index. Minimum: audit-assert typeck pick == lowering pick.
   Full: lowering consumes `resolved_calls`. The dead TYPECK pack section is wired or
   deleted.

9. **Delete the hatches (RC-H) — the completeness proof.** After 1-5 land: delete
   `isAliasName`, the merged-away duplicate builtin table, `class_member_names`,
   `prefer_member`, `contract_with_msg`/`CONTROL_INTRINSICS`, `tailrec_fn_names` as an
   overload gate (TailCallFunc re-picks via `applicable`), the `concreteSibling` redirect
   (abstract instantiation becomes a diagnostic), `isPrimitiveConv`, and the Throwable
   lists (route via `resolvedNativeForm`/FQN). Each deletion gated on
   `KLIO_RESOLVE_AUDIT` zero-disagreement + the full sweep.

## Phases (each independently shippable; hatches removed only after subsumed)

- **P0 — Unblock the run-vs-test parity harness.** Root-cause why `assertEquals`/etc do
  not resolve under `klio test` (likely RC-A surfacing for pack top-level funcs). Make
  `tests/fixtures/test_runner/sample_test.kt` pass. Files: `cli/commands.zig`,
  `cli/stdlib_image.zig`, `stdlib_pack/*`, `interp_ir/build.zig`.
- **P1 — DeclSig + sig phase 0 (RC-A).** Additive; `resolveCall` not yet switched.
  Verify: `KLIO_RESOLVE_AUDIT` shows tier_count>0 for user top-level funcs called from
  methods under `klio test`; image round-trip; full sweep unchanged.
- **P2 — `applicability.zig` (RC-B, RC-E).** Lift the type-aware scorer + position-agnostic
  bind; merge the two builtin tables. Runtime callers switch first. Verify: `e_vararg`
  passes under run AND test; named-arg corpus unchanged.
- **P3 — `Module.resolveCall`, switch bare-call emission (RC-A, RC-B).** Shadow behind
  `KLIO_RESOLVE_AUDIT` to zero disagreement, then switch. Verify: `factRun` prints 5/5
  under run AND test.
- **P4 — Member-vs-global by receiver-type membership (RC-C); delete `class_member_names`.**
  Verify: run-vs-test parity harness byte-identical; `crossmember.kt` no longer downgrades.
- **P5 — Distinct-keyed inherited fields (RC-D) + super/method-walk fixes.** Verify:
  `c_shadow` 1/2/1/1; override still woof/4; `super.method` interface-skip correct.
- **P6 — Reified inference from parameter positions (RC-F).** Verify: `j2`/`j4` correct;
  controls stay correct.
- **P7 — Typeck records + reuses resolution (RC-G).** Verify: typeck-vs-lowering zero
  disagreement on the corpus; `klio check` diagnostics unchanged.
- **P8 — Delete the hatch name-lists (RC-H).** Each deletion audit-gated + full sweep;
  user class named `Error`/`Random` constructs correctly; abstract instantiation
  diagnoses.

## Verification

- **Ratchet:** stdlib commonTest baseline (`stdlib_commontest.zig`, currently >=1455).
  Risky phases run the FULL sweep; raise the baseline only after a real fix; a phase that
  drops the count is rejected, not accommodated.
- **`KLIO_RESOLVE_AUDIT` zero-disagreement** before switching any resolution path and
  before each hatch deletion. Extend it to flag type-blind agreement (index and heuristic
  agreeing on a wrong pick — the `factRun` blind spot) via an applicability-confidence field.
- **Run-vs-test parity harness** (built in P0, required from P4): each fixture body emitted
  twice — `fun main(){...}` and `class T{ @Test fun t(){...} }` — asserting byte-identical
  stdout. Throw-on-mismatch `@Test` bodies as a fallback if assert resolution is partial.
- **Repro ratchet:** the four headline crashes locked as corpus tests that currently FAIL
  and must pass post-fix, each under BOTH run and test, each failing if its fix is reverted:
  `factRun` -> 5/5; `e_vararg` -> `T4 [6,7,8] end`; `c_shadow` -> 1/2/1/1; `j2` -> is/no.
- **Structural invariants** after the design lands: (a) every bare-call resolution is a pure
  function of (call site, sig index); (b) `funcsBySimpleName` at file=0 == at any later file;
  (c) zero name-list lookups remain in the dispatch path; (d) runtime pick == lowering pick
  for every non-runtime-polymorphic call.
- **Negative tests:** abstract instantiation emits a diagnostic (not a `concreteSibling`
  redirect); a user class named `Error`/`Exception`/`Random` constructs via its own
  declaration; named args on a function-typed value diagnose rather than silently drop.

## Landed RC-B slice (type-aware class-vs-factory)

A same-name factory function and a constructor of the SAME arity were
disambiguated arity-only, so `Box(5)` (ctor `Box(Int)`) bound the factory
`fun Box(s: String)` type-blind and crashed on `s.length`. `shadowedByClass`
now consults the candidate factory's declared parameter types
(`decl_user_sig`) against the literal argument kinds: a factory whose parameter
type definitely cannot accept a literal argument (an `Int` literal against a
`String` parameter) is not applicable, so the call constructs the class.
Conservative — only a literal-vs-builtin kind mismatch flips the decision; an
unknown argument or parameter type never disproves. Locked by
`examples/class_factory_overload.kt`. The full RC-B/RC-A consolidation
(`Module.resolveCall` with constructors as first-class index candidates and one
shared type-aware applicability over lowering+runtime+member) remains the bulk
of P3.

## Landed RC-E fix (non-final vararg)

A `vararg` parameter before a trailing defaulted parameter, called positionally,
crashed: the binders only collapsed a vararg in the LAST parameter, so the middle
positional args were never packed (`report("T4", 6, 7, 8)` left an `Int` in the
`items: Array` slot). Fixed by making the binders vararg-position-aware:
- `callFuncNamed` enters its reorder-aware binder when the callee has a non-final
  vararg (not only when an argument is named); `hasNonFinalVararg` gates it.
- `pickMethodOverload`'s single-candidate applicability binds the prefix
  positionally, the vararg consumes the remaining positional args, and the
  post-vararg params take defaults — instead of type-checking a vararg-bound arg
  against a post-vararg parameter.
- `invokeMethodFuncId` routes a non-final-vararg member call through the
  reorder-aware func binder rather than the trailing-collapse fast path.
Locked by `examples/vararg_nonfinal.kt`. The broader RC-B consolidation (one
shared `applicability.zig` over the lowering/runtime/member scorers + merging the
two builtin-supertype tables) folds into P3, co-designed with `resolveCall`'s
needs rather than shipped as an unused abstraction.

## Landed RC-A fixes

- **Cross-package class-name collision** — `reserveClass` deduped class stubs by SIMPLE
  name, so two classes sharing a simple name across packages (`kotlinx.io.Segment` public
  + concrete vs `kotlinx.coroutines.internal.Segment` internal + abstract) collapsed onto
  one slot; whichever pack reserved first won, and the loser's own `Name(args)`
  construction sites misresolved to the winner (here: to the abstract twin's companion
  `invoke`). Fixed with `reserveClassFqn` (FQN-keyed reservation) + FQN-aware stub reuse
  in `addClass`, plus `shadowedByClass` now resolving through the scope-tiered
  `classIdIndexed` rather than the simple-name-global `classId`. This surfaced as a
  `kotlinx.io` ByteChannel failure/deadlock under co-loaded `kotlinx.coroutines` and is
  locked by `tests/fixtures/dispatch/class_name_collision.kt`.

## Sequencing note: P1 must land WITH P4

The intra-build reorder (register top-level headers before class bodies lower) is NOT
safely additive: completing the index during class-body lowering changes member-vs-global
decisions, because the lowering still decides member-vs-global by the heuristic
(`class_member_names` global set + `prefer_member`), not by the receiver type. The reorder
alone regressed a stdlib inner-class call (`AbstractMutableList.IteratorImpl` resolving a
bare `get` to the wrong target). So P1 (the reorder) is folded into P4: the index is made
complete during class lowering only once member-vs-global is decided by the enclosing
receiver type (RC-C). Until then the build keeps the original order (class bodies before
top-level headers).

## Prior progress (carried from the RC-1..RC-5 sketch)

- Step 4 (commit `fea12203`) — removed the `intrinsic_owns_all`/`intrinsicOwnsBareName`
  hatch; `compareValues`/`compareValuesBy` resolve as ordinary symbols.
- Arity-aware member-vs-global (commit `de327622`) — `collectMemberArities` +
  `own_member_arity` mask; a 0-arg member no longer shadows a 1-arg top-level fn. Fixes
  `requireNotNull`/`checkNotNull`. This is RC-C's arity core; the structural name-set gate
  remains (addressed by P4).
- The old plan's RC-4 attribution (base->extend `func_index` drop) was wrong:
  `cloneForExtend` already carries `func_index`. The real root is intra-build phase
  ordering (RC-A) plus `klio test` not routing through the extend assembly.
