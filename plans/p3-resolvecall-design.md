# P3 — `Module.resolveCall`: the single index-primary, type-aware, 3-tier bare-call resolver

## Completed

- `Module.resolveCall` is the live bare-call resolver (`src/ir/lower/expr.zig:5128`),
  index-primary with the shared `applicability.applicable()` ranking the best non-empty
  tier and returning a `Resolution{ target, confidence, emit_form, candidate_set }`.
- `Confidence`/`EmitForm`/`Resolution`/`ResolveCtx`, the `sigViewForApplicability` adapter,
  and the `paramHasDefault` null-`defaults` fallback are in place; the three-tier boundary
  (exact `Call` / virtual `CallMember`+`CallMemberOrGlobal` / deferred `CallValue`) is
  derived once and consumed by the pure emitters `emitCall` / `emitCallMember` /
  `emitMemberOrGlobal` / `emitValueCall`.
- The old ad-hoc lowering helpers are gone: `findCand`, `arityMatch`, `arityMatchTl`,
  `fallbackByDeclArity`, and `matchesRecv`.
- The residual-bug clusters are closed: FloorDivMod (named-arg routing for `IrClosure`
  callees + the `shadowed_by_local` this-prepend gate), NaN-minOf (static overload
  identity + the `linkResolvedForms` body-bearing guard), DeepRecursive (the VM SAM
  dispatch guard on a `CallMemberOrGlobal` callable receiver), and TestTimeSource
  (splice-before-writeback + class-identity type-arg bind). commonTest is 100% per-file.

---

## Remaining: delete the retired heuristic ladder (slice 11)

The inexact-heuristic ladder that `resolveCall` was meant to replace is still live in
`src/ir/lower/expr.zig`. Delete these three symbols and their call sites, then re-ratchet
the canonical run (`resolve_audit_sweep.py` clean, `zig build itest-stdlib_commontest`
holding, run-vs-test parity byte-identical).

- `preferredBareTarget` — definition `expr.zig:5295`, called at `expr.zig:3128` and
  `expr.zig:5466`.
- `HeurRung` enum — declared `expr.zig:5831`, used at `expr.zig:5456`.
- `heurPickInexact` — definition `expr.zig:5549`, called at `expr.zig:5499` (produces the
  `.shape_correction` rung).
