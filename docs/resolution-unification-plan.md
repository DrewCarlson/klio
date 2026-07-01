# Resolved IR — Static Representation, One Engine, Tiered Execution

## North star

KLIO should turn scripts into **as static a representation as possible without
eliminating the runtime's dynamic nature.** Concretely:

- Loading a script produces a **resolved IR**: every call, variable access, field
  access, and type test carries direct, fully-qualified information (a `FuncId`, a
  method slot, a declaring-class + field slot, a `ClassId`) wherever that can be
  determined statically — not a name to be re-looked-up at runtime.
- Type checking / validation is an **optional** pass that (a) powers tooling
  (syntax/type/resolution diagnostics, go-to-definition, hover types) and (b) feeds
  its results back into lowering so *more* of the IR resolves statically.
- What genuinely cannot be resolved statically (runtime-polymorphic receivers,
  unknown scope-function receiver types) stays dynamic — but as a resolved
  *candidate set* or a *virtual slot*, never a bare name probe.

Stdlib code is ordinary code from the stdlib pack and resolves exactly like user
code; native intrinsics exist only as the backing implementation of a resolved
stdlib declaration, never as a parallel resolution path or a name-list shortcut.

This document supersedes the earlier RC-1..RC-5 sketch. Every root cause below was
confirmed against the current code with a live reproduction.

## The completeness invariant — no escape hatches

The purpose of this work is to **retire the entire accumulation of highly-specific
branches** that patch individual execution / stdlib / resolution-ordering issues.
Every one of those was added only because resolution was incomplete (RC-A), type-blind
(RC-B), or decided by a program-wide name set instead of the receiver type (RC-C). A
principled engine makes them unnecessary; their **deletion is the acceptance test** —
if a hatch cannot be deleted, the engine is not yet correct there.

Two things must be distinguished so this stays precise:

- **Legitimate** — a native intrinsic as the *backing implementation* of a resolved
  stdlib declaration, reached through the normal resolved symbol. These stay. The
  declaration is registered once; the engine routes to it by type.
- **A hatch (must die)** — any name-list, FQN pattern, or per-method special-case
  branch used as a *resolution shortcut* or a *dispatch fixup* that papers over the
  index / applicability / receiver-type resolver being incomplete. These go.

The catalog to delete (grown by the stdlib grind, not only the RC-H lists):
`isAliasName`, the two duplicate builtin-supertype tables, the three Throwable lists,
`class_member_names`, `prefer_member`, `concreteSibling`, `tailrec_fn_names` as a
gate, `shadowed_inline_names`, `isPrimitiveConv`, `CONTROL_INTRINSICS`,
`isKnownPackage`/`shippedFqnHead` discriminators, the broad-`kotlin.text.X` vs
`kotlin.text.StringBuilder.<m>`-specific registration split (dispatch by type removes
the need to register per-overload), the `.names` argument-name tables used to force a
binding the resolver should compute, and the assorted per-method dispatch fixups in
`host_call_member.zig` (the inline `.Range` `contains`, unsigned-array synth cases,
etc.). Each deletion is gated on `KLIO_RESOLVE_AUDIT` zero-disagreement + the full
sweep; a hatch that *can't* be removed pins the next fix.

The structural invariant this enforces: **resolution is a pure function of (call site,
sig index, receiver type)** — zero name-list lookups remain in the dispatch/resolution
path, and any two run-modes (lazy lowering, eager typeck, runtime) pick the same target
for every non-runtime-polymorphic call.

## The three-tier static/dynamic boundary

Every call and access lowers to exactly one tier. The tiers *are* the boundary
between "static as possible" and "still dynamic where it must be":

1. **exact** — a direct target. `Call(FuncId)`, `GetField(class_id, slot)`,
   `Is(ClassId)`. Fully static: top-level funcs, final/non-virtual members, resolved
   extensions, locals, resolved property backing fields.
2. **virtual** — the *slot* is static, the *leaf* is runtime. `CallVirtual(recv,
   slot)` where `slot` is a method key on a known declaring type; the concrete
   override is chosen at runtime. This is how **dynamic dispatch is preserved while
   still carrying full type/signature/slot information** — open classes, interfaces.
3. **deferred** — the genuine escape valve. `CallMemberOrGlobal(candidate_set)` when
   the receiver's type is unknown at lowering (e.g. a `with(x){ … }` scope-function
   body). Carries the *resolved candidate set*, not a bare name. This tier shrinks
   toward zero as the eager engine (typeck) runs.

"Static as possible" = the engine collapses tier 3 → tier 1/2 wherever it can prove
the type. "Dynamic preserved" = tiers 2 and 3 still exist by design.

## One engine, two modes

There are **not** two systems (a resolver and a type-checker). There is **one
inference/resolution engine** run in two modes:

- **lazy mode** — the lowering default (`klio run`/`test`). Run the engine locally,
  keep what resolves, tolerate gaps. Literals, `val x = Ctor()`, declared params,
  direct member chains → tier 1/2. The genuinely-hard residual (scope-function
  receiver types, generic instantiation across lambdas, smart-cast-dependent
  dispatch) stays tier 3. Reaches ~90% static **without running typeck at all** —
  the runtime is tolerant of the residual.
- **eager mode** — the type-check / validation pass (`klio check`, LSP, a strict
  mode). Run the *same* engine over the whole tree, compute every expression's type,
  record `Span→Type` + `Span→FuncId`, emit diagnostics. Collapses the residual
  tier-3 into tier 1/2 and is the **only** source of tooling diagnostics.

Consequences:

- Typeck is the **amplifier**, not the foundation. The index + applicability is the
  foundation (a mostly-resolved runnable IR needs no typeck run); typeck resolves the
  hard last ~10% and produces diagnostics.
- The error/reporting infrastructure already built becomes the **diagnostics layer of
  the eager mode** — reused, not discarded, not an independent type system.
- Because both modes are the *same* engine, `run` and `check` cannot disagree on a
  resolution. This is what makes RC-G real and kills the three-drifting-oracle
  problem below.

## Execution engine — resolved IR → bytecode → JIT

The resolved IR is the single source every execution tier consumes.

- **Today:** the IR is already register-based and block-structured; all references
  are `enum(u32)` integer indices (`Reg`/`FuncId`/`ClassId`/`ConstId`/`BlockId`,
  `ir.zig`), and blocks already have a byte-encoded serialized form (the lazy-IR
  `deferred_func_section`). Execution walks `[]Block` of `[]Inst` (a `union(enum)`),
  dispatching per instruction. This is in-memory bytecode in all but the dispatch
  loop.
- **Flat bytecode (optional, post-resolution):** linearize the resolved IR into a
  flat instruction stream with a switch / computed-goto (direct-threaded) dispatch
  loop and superinstruction fusion. Payoff is bounded and specific: tighter dispatch
  (~1.3–2× on dispatch-bound non-loop code), compactness, and **encoding unification**
  — the flat stream is simultaneously executed *and* serialized. Its value is
  proportional to how resolved the operands are: tier-1 becomes a direct indexed
  dispatch, tier-2 a vtable-slot op, tier-3 the (now-rare) probe. Linearizing before
  resolving only encodes slow probes compactly, so this phase follows resolution and
  is gated on a measurement that the baseline dispatch loop is a real bottleneck (our
  measurements show the interpreter is largely compute-bound; the transformational
  perf already came from the loop JIT at 60–79× and the structural method-dispatch
  fixes at 10–12×).
- **JIT (exists):** `src/ir/jit_loop.zig` compiles hot loops/functions from the same
  resolved IR. Bytecode baseline and JIT coexist — JIT owns hot regions, the baseline
  owns the rest.

**The bytecode stream and the serialized artifact are the same object** (see
Serialization). So "flat bytecode" and "separate serializable artifact" are one
decision with one answer.

## Serialization (pack sections already reserved)

The pack format already reserves the sections this needs — `sources`, `ast`,
`resolved`, `typeck`, `symbols`, `bindings` — and the schema already has a
`TypeckBundle` of sorted `(Span, Type)` pairs (`src/pack/schema.zig`,
`src/pack/format.zig`). They are **empty today**: no `resolved` bundle is emitted,
`write.zig` doesn't populate them, and typeck never runs to fill `typeck`.

Serialization is therefore a **later optimization, decoupled from the in-memory
resolved-IR work**, justified only by startup speed (skip re-lowering the stdlib per
run) and RSS (compact on-disk form). It is **not on the correctness path**. When we
want it, we populate the reserved sections — the linearized resolved bytecode becomes
the `resolved` section, typeck's `Span→Type`/`Span→FuncId` maps become `typeck`, the
sig index becomes `symbols`. No new format is invented.

## Root causes (the means)

- **RC-A — no canonical index.** No single signature index over all provenances
  populated before any body lowers. `func_name_index` is built in the wrong order and
  consulted while incomplete: class bodies lower (`interp_ir/build.zig:1470`) before
  the phase-1 header loop (`:1489-1561`), so `funcsBySimpleName`/`funcId`/
  `decl_user_arity` are empty for user top-level funcs when any class method (incl. a
  `@Test` method) lowers. The `klio run` extend path pre-seeds the index via
  `cloneForExtend` (`ir.zig:1142-1150`), masking the bug; `klio test` goes straight to
  `buildModuleFiles` with no pre-seed, exposing it. Members and inline members get no
  arity-queryable entry at all. The index is consulted as a refiner, not a primary.
  *This is the true root of run-vs-test divergence.* Evidence: `factRun`.

- **RC-B — no shared, type-aware applicability.** Applicability/overload matching is
  reimplemented at least three times (lowering ladder, runtime global scorer, runtime
  member scorer) with no shared core, and the lowering ladder is arity-only and
  type-blind. `shadowedByClass` + `findCand`/`arityMatch` (`expr.zig:4324-4364`) bind
  `Box(5)` to `fun Box(String)`; only `overload_match.zig:124` `builtinKindMismatch`
  rejects it at runtime, and only when the call deferred. The runtime re-rank
  (`pickOverloadCached`, `host_call_func.zig:1266`) is a safety net bypassed by exact
  casts (`eval.zig:2586`), `TailCallFunc`, and any lowering-only decision.
  `src/ir/applicability.zig` does not exist. Evidence: `factRun`.

- **RC-C — member-vs-global by a program-wide name set.** The decision uses
  `class_member_names` (a union over ALL pack+user classes) plus `inReceiverContext`,
  not the enclosing receiver TYPE's members. Six gate sites
  (`expr.zig:1099,3804,3961,4521,4931,4979`). `inReceiverContext` is true for any
  method body, false for top-level `main`, so identical bodies lower to different IR
  under run vs test. Evidence: `crossmember.kt`. This is the root of the null/broad
  receiver static-dispatch cluster (`orEmpty`, `minus`, local-ext-shadows-stdlib).

- **RC-D — name-keyed field storage.** `InstanceData.fields` is a flat
  `ArrayList(Field{name,value})` keyed by name only (`class.zig:318-353`); `define`
  overwrites. A subclass field with a parent's name aliases the parent's cell. Kotlin
  needs two distinct cells keyed by (declaring class, name) for a shadow, one shared
  cell for an override. A value-layer root cause below the dispatch layer; reproduces
  byte-identically run-vs-test. Evidence: `c_shadow` prints 2/2/2/2, expected 1/2/1/1.

- **RC-E — non-final vararg on the positional path.** The positional binders pack
  varargs only when the vararg is LAST (`host_call_func.zig:93`, member twin
  `host_call_member.zig:374`). A non-final vararg before a defaulted param crashes on
  a purely-positional call. The named binder handles it. Evidence: `e_vararg`.
  *(Landed — see below.)*

- **RC-F — reified inference is return-type-only.** `inferReifiedTypeArgs`
  (`inline_call.zig:276-313`) unifies only `f.return_type`, so a reified `T` inferable
  only from a lambda parameter annotation stays unbound and `x is T` is always-true.
  Evidence: `j2`. *(Landed — see below.)*

- **RC-G — typeck resolution discarded.** Typeck resolves overloads internally
  (`checkOverloadedCall`) but records nothing; `TypeCheck` exposes no `Span→FuncId`
  map (`check.zig:72-88`), and `klio run`/`test` never invoke typeck. Three overload
  oracles share no resolved-symbol channel. **The one-engine-two-modes design is the
  fix:** typeck is the eager mode of the same engine, so there is one oracle recorded
  once.

- **RC-H — hatch name-lists.** `isAliasName` (41 names), two near-duplicate
  builtin-supertype tables, three Throwable lists, `concreteSibling`, `tailrec_fn_names`,
  `shadowed_inline_names`, `isPrimitiveConv`, `CONTROL_INTRINSICS`. These exist only
  because the index is incomplete and applicability isn't shared/type-aware. Deleting
  them is the proof those fixes are complete.

## Target architecture

1. **One canonical signature index (RC-A).** A per-`FuncId` `DeclSig` in `ir.zig`
   (subsuming `decl_user_arity`/`decl_user_sig`/`decl_user_params`): `{ fqn, package,
   simple_name, kind, enclosing_class, receiver_ty, params: []ParamSig{name, ty,
   has_default, is_vararg, is_function_typed}, type_params, is_inline, is_suspend }`.
   A new **phase 0** in `buildModuleWithOverrides` registers a `DeclSig` for every
   declaration — top-level funcs, constructors (keyed by class simple name), member
   methods, inline funcs — BEFORE class-lowering and phase-1. Three phases: (0) sig
   registration over all decls, (1) class body lowering, (2) top-level body lowering.
   `runTestFiles` routed through the same extend/image assembly as `run`.

2. **One type-aware applicability function (RC-B, RC-E).** New
   `src/ir/applicability.zig`: `pub fn applicable(sig, args: []const ArgShape, scope)
   ?Score`. `ArgShape = { ty: ?TypeRef, is_lambda, lambda_arity, lambda_param_types,
   is_named, is_spread }`, populated from lowering (lowered expr type / literal kind),
   runtime (value class name), or the eager engine (checked Type lowered to TypeRef).
   Folds in one place: named-arg-to-param, default padding, vararg packing at ANY
   position, trailing-lambda binding, per-arg type scoring. The two builtin-supertype
   tables merge into one relation derived from the hierarchy. Three callers, one
   function: lowering's `resolveCall`, runtime `pickOverload`/`pickMethodOverload`,
   eager `checkOverloadedCall`.

3. **`Module.resolveCall` — one resolver, index primary (RC-A, RC-B).** Tiers
   candidates by Kotlin scope, ranks the best non-empty tier by `applicable`, returns
   `Resolution{ target: FuncId, confidence: {exact, virtual, deferred},
   candidate_set }` — the three tiers above. A unique best → resolved `Call`/
   `CallVirtual`. A tie or runtime-only receiver → `CallMemberOrGlobal` carrying the
   candidate set. The heuristic ladder, `preferredBareTarget`,
   `resolveBareCallIndexed`-as-refiner, and the inline-vs-noninline split collapse into
   this. Constructors are ordinary candidates.

4. **Member-vs-global by enclosing-receiver type (RC-C).** Delete `class_member_names`
   and the `inReceiverContext` discriminator. A bare call inside a method queries the
   enclosing receiver type's member set via the sig index (walking the supertype
   closure by `ClassId`). Member-shadowable iff THIS receiver type (or a supertype) has
   an applicable member of that name+shape. Pure function of (call-site receiver type,
   sig index); independent of main-vs-`@Test`.

5. **Distinct-keyed inherited fields (RC-D) → the exact/virtual field tiers.** Change
   `InstanceData.Field` key from name to `(declaring_class: ClassId, name)`, exposed as
   a resolved `slot`. An override writes one cell (most-derived); a shadow writes a
   separate cell. A bare `x` in a method of class C resolves to the C-or-nearest-
   supertype cell; `super.x` reads the parent's; `(b as Base).x` reads via static type.
   Also fix `firstSupertypeName` to skip interfaces (`host_call_member.zig:6901`) and
   FQN-qualify the method walk after the first hop.

6. **Position-agnostic vararg packing (RC-E).** Unify the positional and named binders
   onto `applicability.zig`'s position-agnostic bind step. *(Landed.)*

7. **Reified inference from parameter positions (RC-F).** *(Landed.)*

8. **Eager mode records + reuses resolution (RC-G).** `TypeCheck.resolved_calls:
   Span→FuncId` + `Span→Type`. The eager engine calls the shared `resolveCall`/
   `applicable`. Lowering consumes `resolved_calls` when present (typeck-informed
   fidelity) and runs the same engine lazily when absent. Records feed the pack
   `typeck` section.

9. **Delete the hatches (RC-H) — the completeness proof.** After 1-5 land: delete
   `isAliasName`, the merged-away duplicate builtin table, `class_member_names`,
   `prefer_member`, `CONTROL_INTRINSICS`, `tailrec_fn_names` as an overload gate, the
   `concreteSibling` redirect (abstract instantiation → diagnostic), `isPrimitiveConv`,
   and the Throwable lists. Each deletion gated on `KLIO_RESOLVE_AUDIT`
   zero-disagreement + the full sweep.

10. **(Optional, post-resolution) flat bytecode + serialization.** Linearize the
    resolved IR into a flat threaded-dispatch stream; the same stream populates the
    pack `resolved` section. Gated on a dispatch-bottleneck measurement; unifies the
    in-memory `Inst` union with the lazy-IR byte section into one canonical stream.

## Working rule for this plan

Per CLAUDE.md ("Scope and regressions") and the user's directive: these are **big
coupled changes**, not green-preserving slivers. RC-A and RC-C must land **together**
(completing the index during class-body lowering flips member-vs-global decisions, so
the reorder is only safe once member-vs-global is receiver-type-aware — a P1-alone
attempt regressed −16, documented below). The canonical count is expected to dip for
several commits before climbing past the old baseline. Land the big change, then drive
it green. Root-causing still holds: never hide a failure; only the stay-green-every-
commit constraint is relaxed.

## Phases (big coupled changes, not shipped as unused abstractions)

- **P0 — Parity harness + unblock `klio test` resolution.** *(Landed.)* Each fixture
  emitted twice (`fun main` and `@Test`), byte-identical stdout. `kotlin.test` resolves
  under `klio test`.
- **P1+P4 (coupled) — canonical index (RC-A) + member-vs-global by receiver type
  (RC-C).** Build the phase-0 `DeclSig` index; switch member-vs-global to receiver-type
  membership; delete `class_member_names`. Expect a mid-flight dip. Verify: `factRun`
  5/5 and `crossmember.kt` no downgrade under run AND test; run-vs-test parity harness
  byte-identical.
- **P2 — `applicability.zig` (RC-B, RC-E).** One shared type-aware scorer +
  position-agnostic bind; merge the two builtin tables. Runtime callers switch first.
  Verify: `e_vararg` under run AND test; overload-by-type cluster (sumOf,
  compareToIgnoreCase, minus, NaN minOf/maxOf) resolves.
- **P3 — `Module.resolveCall`, switch bare-call emission (RC-A, RC-B).** Shadow behind
  `KLIO_RESOLVE_AUDIT` to zero disagreement, then switch. Verify: `factRun` 5/5.
- **P5 — Distinct-keyed inherited fields (RC-D) + super/method-walk fixes.** Verify:
  `c_shadow` 1/2/1/1; override still correct; `super.method` interface-skip correct.
- **P6 — Reified inference from parameter positions (RC-F).** *(Landed.)*
- **P7 — Eager mode records + reuses resolution (RC-G).** Typeck runs the shared
  engine, records `Span→FuncId`/`Span→Type`, emits diagnostics; lowering consumes them.
  Verify: typeck-vs-lowering zero disagreement; `klio check` diagnostics wired.
- **P8 — Delete the hatch name-lists (RC-H).** Each deletion audit-gated + full sweep.
- **P9 — (Optional) flat bytecode + pack `resolved`/`typeck`/`symbols` serialization.**
  Gated on a dispatch-bottleneck measurement and a startup/RSS justification.

## Verification

- **Ratchet:** stdlib commonTest baseline (`stdlib_commontest.zig`). Risky phases run
  the FULL sweep; the baseline is raised only after a real fix. A phase may *temporarily*
  drop the count (big coupled changes) but must climb past the prior baseline before the
  phase is called done.
- **`KLIO_RESOLVE_AUDIT` zero-disagreement** before switching any resolution path and
  before each hatch deletion; extended to flag type-blind agreement (index+heuristic
  agreeing on a wrong pick — the `factRun` blind spot).
- **Run-vs-test parity harness** (P0, required from P1+P4): each fixture emitted twice,
  byte-identical stdout.
- **Repro ratchet:** `factRun` → 5/5; `e_vararg` → `T4 [6,7,8] end`; `c_shadow` →
  1/2/1/1; `j2` → is/no. Each under BOTH run and test, each failing if its fix reverts.
- **Structural invariants:** (a) every bare-call resolution is a pure function of (call
  site, sig index); (b) `funcsBySimpleName` at file=0 == at any later file; (c) zero
  name-list lookups in the dispatch path; (d) runtime pick == lowering pick == eager pick
  for every non-runtime-polymorphic call.
- **Negative tests:** abstract instantiation diagnoses; a user class named
  `Error`/`Exception`/`Random` constructs via its own declaration; named args on a
  function-typed value diagnose rather than silently drop.

## P1+P4 investigation (findings that constrain the real fix)

A full attempt landed and was reverted. Findings:

- **The lowerer is largely untyped**, so a scope-function receiver's type
  (`with(x){ memberOfX() }`) is unknown at the call site — which is *why* the runtime
  probe exists and why the eager mode (typeck) is the amplifier that removes it. A naive
  `class_member_names` → `hasOwnMember` swap regresses scope-receiver member calls
  (`with(Box()){ greet() }` bound the top-level `greet`).
- **A workable signal exists:** `receiverRebindActive()` on the FuncBuilder —
  `capturesThisSlot() or isParamThunk()` OR the in-scope `this` resolving at a scope
  depth other than the function's own-`this` scope (`own_this_scope`). It narrows the
  member-shadowable gate safely in plain method bodies while keeping the
  over-approximation where a non-enclosing receiver is in scope.
- **P1 and P4 are coupled.** Completing the index during class-body lowering flips
  member-vs-global decisions because the lowering still decides by the heuristic. The
  reorder alone regressed a stdlib inner-class outer-member call
  (`AbstractMutableList.IteratorImpl` reaching the list's `get`). P1+P4 must land
  together with EVERY member-preference site made receiver-type-aware. Reproduced as the
  nested-`it` −16 in the grind campaign: the reorder makes method-body bare calls resolve
  statically (`emitBareFuncCall`→global) instead of via runtime `CallMemberOrGlobal`
  (member-first), changing overload resolution for ~16 tests. That −16 is the coupling,
  not a bug in the reorder.

Resume by reinstating `receiverRebindActive`/`own_this_scope`, the gate + `prefer_member`
changes, and the index reorder together, driving the inner-class outer-member site (and
any the full sweep surfaces) to green — accepting a mid-flight dip.

## Landed slices

- **RC-F (reified inference from parameter positions).** `inferReifiedTypeArgs` now
  unifies each declared value-parameter type (recursing into function-typed params'
  parameter lists) against actual argument / lambda-parameter-annotation types before
  the return-type fallback. Locked by `examples/reified_param_inference.kt`.
- **RC-B slice (type-aware class-vs-factory).** `shadowedByClass` consults the candidate
  factory's declared parameter types against the literal argument kinds; a factory whose
  parameter type cannot accept a literal argument is not applicable, so `Box(5)`
  constructs the class. Locked by `examples/class_factory_overload.kt`.
- **RC-E (non-final vararg).** The binders are vararg-position-aware: `callFuncNamed`
  enters its reorder-aware binder on a non-final vararg; `pickMethodOverload` binds the
  prefix positionally, the vararg consumes the remaining positional args, post-vararg
  params take defaults; `invokeMethodFuncId` routes a non-final-vararg member call
  through the reorder-aware binder. Locked by `examples/vararg_nonfinal.kt`.
- **RC-A slices.** Cross-package class-name collision (`reserveClassFqn` FQN-keyed
  reservation + FQN-aware stub reuse; `shadowedByClass` resolves through
  `classIdIndexed`). Locked by `tests/fixtures/dispatch/class_name_collision.kt`.
  Step 4 (`fea12203`) removed the `intrinsic_owns_all` hatch. Arity-aware
  member-vs-global (`de327622`, `collectMemberArities` + `own_member_arity` mask): a
  0-arg member no longer shadows a 1-arg top-level fn. The old plan's base→extend
  `func_index` drop attribution was wrong: `cloneForExtend` carries `func_index`; the
  real root is intra-build phase ordering (RC-A) plus `klio test` not routing through
  the extend assembly.
