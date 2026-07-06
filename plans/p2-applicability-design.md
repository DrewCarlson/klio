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

---

## Remaining: delete `overloadScoreArg`

The legacy per-arg `overloadScoreArg` was meant to be removed once the flip landed, but
it is still live at the binder sites. Fold each remaining call into the shared `ArgShape`
scoring in `applicable()` and delete the function.

Live sites:

- `src/interp_ir/vm/host_instances.zig:504` — `overloadScoreArg` definition.
- `src/interp_ir/vm/host_instances.zig:1441`, `:1736`, `:1914` — the three binder call
  sites that still score per-arg through it.
- `src/interp_ir/vm/host_call_member.zig:1793` (definition) and `:7565` (call) — the
  `extensionFnFallback` pre-filter copy.

Dead site to remove with the same change:

- `src/interp_ir/vm/host_call_func.zig:488` — stray leftover `overloadScoreArg`
  definition, unreferenced after the global scorer was flipped.
