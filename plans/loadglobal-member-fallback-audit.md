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

The separate writeback member/path lowerers are deleted. Lambda arguments that
mutate captured variables use the ordinary call pipeline and boxed capture cells,
so local, inherited member, extension, and top-level classification has one path.
`captured_write_shared_resolution.kt` covers an inherited member call, a top-level
call, an implicit receiver extension, a receiver-function property, and
receiver-sensitive infix chaining while each lambda mutates a captured variable.
It also keeps an implicit-receiver vararg extension ahead of a same-name exact
global, so unsupported static shapes cannot become false inapplicability proofs.
