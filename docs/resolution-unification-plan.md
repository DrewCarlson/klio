# Name-Resolution & Execution Unification

Goal: one source of truth for "what does this name resolve to" and one execution
path, regardless of run-vs-test, pack-vs-source, or inline-vs-regular. Stdlib code
is functional from the stdlib pack and resolves exactly like user code; native
intrinsics exist only as the backing implementation of a stdlib declaration that
requires native support, reached through the normal resolved symbol — never as a
parallel resolution path or a name-list shortcut. No escape hatches for stdlib in
the interpreter.

## Root causes

- **RC-1** Two arity oracles disagree: `Module.resolveBareCallIndexed` (ir.zig)
  uses `decl_user_arity`; the heuristic ladder in `lowerPathCall` (expr.zig) re-ranks
  the same candidates but gates on `f.hasBody()` and the hardcoded `isAliasName` list.
  When they disagree, `bare_func_id` is null → inline/stdlib escapes.
- **RC-2** Inline funcs are body-stripped and live in `inline_state`, a different
  table than the index the bare-call emitter trusts → inline never resolves as a
  bare global.
- **RC-3** `prefer_member` is arity-unaware: any same-named enclosing member
  suppresses global resolution even when arity can't match.
- **RC-4** Member-vs-global gated on `class_member_names` (a global set over ALL
  pack+user classes) + `inReceiverContext` differing top-level vs `@Test` method →
  same source lowers to different IR under `run` vs `test`.
- **RC-5** Name-lists papering the seams: `isAliasName`, `intrinsic_owns_all` /
  `intrinsicOwnsBareName`, `contract_with_msg`, `CONTROL_INTRINSICS`.

## Target architecture

- (A) One canonical index: `DeclSig` per FuncId for every top-level func (user, pack,
  baked, inline). Supersedes `decl_user_arity` + ad-hoc body-param inspection.
- (B) One resolver `Module.resolveCall(name, arg_shapes, scope) -> Resolution`,
  folding the heuristic ladder + indexed resolver, ranking all candidates with one
  shared `applicable(DeclSig, arg_shapes)` (the runtime `memberApplicableForWalk`
  logic, lifted to a shared module so compile- and run-time agree).
- (C) One global lookup; emit resolved `Call`/`CallMember`. `CallMemberOrGlobal`
  survives only for genuinely runtime-polymorphic receivers, carrying the candidate
  set (not a name probe).
- (D) Member-vs-global by applicability against the enclosing-`this` TYPE's members
  (not a global name set). Kills RC-4 + run-vs-test divergence structurally.
- (E) Intrinsics attach via `resolvedNativeForm(FuncId)` only. Delete
  `intrinsicOwnsBareName`/`intrinsic_owns_all`.
- (F) Inline selected after `resolveCall` yields a FuncId for which `isInline` is
  true; `inline_state` becomes a body-source keyed by FuncId.

## Steps (each independently testable; hatches removed only after subsumed)

1. **DeclSig + sig_index**, additive, populate for every func incl inline. (no behavior change)
2. Lift `memberApplicableForWalk` arity core into `src/ir/applicability.zig`; runtime calls it.
3. Add `Module.resolveCall`; run in SHADOW/audit mode behind `KLIO_RESOLVE_AUDIT`, log disagreements.
4. Move intrinsics fully onto `resolvedNativeForm`; delete `intrinsicOwnsBareName`/`intrinsic_owns_all`.
5. Switch top-level (non-member-shadowed) bare-call emission to `resolveCall`.
6. Make member-vs-global applicability-aware; remove `prefer_member` + `contract_with_msg`.
7. Replace `class_member_names` global gate with enclosing-receiver-type member query; remove the field.
8. Route inline selection through the resolver.
9. Delete residual hatches (`isAliasName`, `decl_user_arity`, control-intrinsic name lists).
10. Collapse `execCallMemberOrGlobal` to the ambiguous-only case.

## Verification

- Ratchet gate: `stdlib commonTest` ≥ 1452 (stdlib_commontest.zig). Risky steps
  (3,5,6,7,8,10) run the FULL sweep. Raise baseline after real fixes.
- requireNotNull/checkNotNull repro: 1-arg and 2-arg(trailing-lambda) overloads, at
  top level AND inside a method whose class has a same-named member.
- run-vs-test parity: a fixed `.kt` body wrapped in `fun main()` and `@Test fun t()`
  must produce byte-identical output (guard for RC-4, required from Step 7).
- `KLIO_RESOLVE_AUDIT` zero-disagreement invariant before each hatch removal.

## Progress

- Step 1 (DeclSig) — largely PRE-EXISTING: `decl_user_arity` + `decl_user_sig` are
  already recorded for every top-level func (incl. inline) at phase-1 header
  registration (interp_ir/build.zig:1493-1513). The gap was that CLASS MEMBERS were
  not in any arity-queryable index, so member-vs-global couldn't be arity-aware.
- [x] Step 4 (commit fea12203) — removed the `intrinsic_owns_all` /
  `intrinsicOwnsBareName` hatch; `compareValues`/`compareValuesBy` resolve as
  ordinary symbols, native form attached via `resolvedNativeForm`. Verified 1452.
- [x] Arity-aware member-vs-global (commit de327622) — `collectMemberArities` records
  per-member arity masks threaded to the FuncBuilder (`own_member_arity` +
  `ownMemberApplicable`); gates both `prefer_member` and `lowerImplicitThisCall`. A
  0-arg member no longer shadows a 1-arg top-level fn. Fixes PreconditionsTest
  (requireNotNull/checkNotNull) — the recurring "test-vs-run divergence" bug — with
  NO name list. Verified 1455 (+3), no regression. This is plan Step 6's core (RC-3).

### Next (each full-sweep-verified before commit)
- Remove `contract_with_msg` (require/check/checkNotNull name-list, RC-5) — likely
  subsumed by arity-aware resolution now; test require/check-with-message cases.
- Remove `isAliasName` (RC-5) — once the implicit-`this` global fallback no longer
  needs the name list (inline stdlib funcs should be reachable via the index/runtime
  global lookup; verify the `funcsBySimpleName` membership of inline funcs first).
- RC-4: replace the global `class_member_names` gate with an enclosing-receiver-type
  member query (the broader run-vs-test divergence; the requireNotNull instance is
  fixed, but the structural gate remains). Add the run-vs-test parity harness.
- `applicability.zig`: lift `memberApplicableForWalk` so compile- and run-time share
  one applicability check (the arity-mask is a first step toward this).
