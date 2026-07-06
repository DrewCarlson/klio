# LoadGlobal member-fallback audit

## Background

`LoadGlobal` loads a module-level binding by name (or by a lowering-resolved
func/class id): top-level functions, top-level properties, bare-name class/object
references, and registered host intrinsics. It is **not** dynamic dispatch — it is
emitted only where no implicit receiver can shadow the name, so a runtime miss is a
hard `unresolved global` error.

## The trap

Bare-name call lowering must classify the callee: local, member-on-`this`, inline,
or top-level. Several lowering paths end with `else → LoadGlobal` as the last
resort. When a path **fails to recognize that the name is an own (incl. inherited)
member**, it falls to `LoadGlobal` and produces `unresolved global <name>` at
runtime — even though the correct lowering is `CallMember` on `this`. The
structural cause is **duplicate/parallel call-lowering paths that do not all share
the member-resolution logic.**

## Completed

The main bare-call path is unified: `lowerImplicitThisCall` and the general
bare-call route now go through the shared `Module.resolveCall` engine
(`src/ir/lower/expr.zig`), so member-vs-global for the common path is decided in
one place. The confirmed writeback-path instance is fixed:
`lowerCallWithWritebackPath` (the path taken when a trailing lambda mutates a
captured local) carries the `hasOwnMember` + `this`-in-scope → `CallMember` guard
before its `LoadGlobal` fallback (`src/ir/lower/expr.zig`, ~`:3216`), so an
inherited inline member whose lambda mutates a captured `var` (e.g.
`forEachSlotLocked` in kotlinx.coroutines `SharedFlow`) no longer falls to an
unresolved global.

## Open

`lowerCallWithWritebackPath` is still a **separate parallel path that does not
route through `resolveCall`** — it hand-rolls its own member guard. The structural
risk the audit named (duplicate call-lowering paths that do not share the
member-resolution logic) therefore still exists for the writeback path, and its
other callee-as-global fallback sites have not been re-audited since the file was
refactored.

To close:

- Route `lowerCallWithWritebackPath` through the shared `resolveCall` engine (the
  single `local → member → inline → top-level` classifier), or confirm every
  `LoadGlobal` fallback it still reaches for a bare member/inline name is guarded
  by `hasOwnMember` (own + inherited, receiver in scope) first.
- Add a regression test per remaining fallback site: an inherited member fn called
  bare under the shape that selects that path.
