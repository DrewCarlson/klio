# P2 — Shared Overload-Resolution Applicability Engine

## Completed

- The shared applicability engine is live in `src/ir/applicability.zig`: `ArgShape`,
  `Score`, `Binding`, `ApplicabilityScope`, and the pure per-candidate `applicable()`
  fold named-arg binding, default padding, vararg packing at any position,
  out-of-sequence trailing-lambda binding, and per-arg type scoring in one place.
- All four scoring callers were flipped onto `applicable()`: the lowering `resolveCall`
  path, the runtime global `pickOverload`, the runtime member `pickMethodOverload` +
  `scoreExtCandidates`, and the eager `checkOverloadedCall`.
- The three per-caller `ArgShape` builders (AST literal kinds, runtime Value class,
  eager checked type) are the only phase-specific code; everything downstream is shared.
- `builtinSupersOf` in `applicability.zig` is the single merged builtin-assignability
  table, replacing the three divergent per-caller tables (`builtinSupersFor`,
  `builtinSupers`, `builtinHeadAccepts`) and restoring the previously-missing
  `Collection` / `StringBuilder` / range-and-progression rows.
- Construction factories, primary-constructor compatibility, extension fallback,
  and named-member ranking also consume `applicable()`. The three legacy
  per-argument scorer implementations and every call site have been removed.
