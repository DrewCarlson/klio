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
runtime — even though the correct lowering is `CallMember` on `this`.

The structural cause is **duplicate/parallel call-lowering paths that do not all
share the member-resolution logic.** The main implicit-`this` path
(`lowerImplicitThisCall`) guards with `hasOwnMember → CallMember`; sibling paths
that don't are bugs waiting to fire.

### Confirmed instance (fixed)

`lowerCallWithWritebackPath` (the path taken when a trailing lambda mutates a
captured local) resolved the callee only through the global func index. An
inherited inline member (`forEachSlotLocked` in kotlinx.coroutines `SharedFlow`,
whose lambda mutates a captured `var`) is never in that index, so the call fell to
`LoadGlobal`. Fixed in `interp: writeback call path dispatches an enclosing-class
member on this` (78dc2988) by adding the `hasOwnMember + this-in-scope → CallMember`
guard before the `LoadGlobal` fallback.

## To audit

Other callee-as-global fallback sites in `src/ir/lower/expr.zig` that load the
callee via `LoadGlobal` after resolution "fails", to confirm each has a
`hasOwnMember` (own + inherited member, with a receiver in scope) guard first:

- `expr.zig:3698`
- `expr.zig:4789`
- `expr.zig:4812`
- `expr.zig:4836`

For each: determine whether the path is reachable for a bare member/inline name
(member-on-`this`); if so, route to `CallMember` before the `LoadGlobal` fallback,
matching `lowerImplicitThisCall`. Add a regression test per site (inherited member
fn called bare under the shape that selects that path).

Longer term: factor the `local → member → inline → top-level` classification into a
single shared helper so the sibling paths can't drift.
