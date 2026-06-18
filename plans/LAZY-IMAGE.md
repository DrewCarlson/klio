# Lazy / position-independent stdlib image

## Goal

Stop materialising the whole stdlib AST forest at process start. A simple
program executes almost none of the ~6000 baked decls; the unused ones should
stay file-backed in the mmap and never become resident. Target: cut the ~24.8 MB
eager `image.decode` toward Python-level (~15 MB) for simple/stdlib programs,
with ktor and the full suite staying green.

Starting point (committed): hello-world ~43 MB gc / 48 MB arena. `image.decode`
22 MB, of which the AST forest skeleton (`lifted_decls`) is ~12 MB and the IR
module ~4 MB; `baseFromRoot` 4 MB. No leaks; the contained node-size + lazy-body
tiers are exhausted.

## The coupling that makes this hard

`ImageRoot.lifted_decls` is encoded **first** so its traversal defines the
watched-node registry (by traversal order). `module` and `built` are encoded
after and **backref into that registry**: `MethodDef.decl: *const ast.Function`,
`PropertyDef.init/getter/setter/delegate`, `ClassDef.parent_ctor_args`,
`init_blocks`, `secondary_ctors`, `Inst.BuildObject.ast`, and the inline-fn
registry (`inline_ids`) all hold pointers *into the forest*. So the forest must
be decoded before `built`/`module` can resolve those pointers — that is what
forces full materialisation at load.

Three load-time traversals additionally walk the whole forest every run
(`build.zig`):
- **1143 `file_classes`** — map every base `Class` decl by simple name (for user
  class hierarchy walks / inline splicing through base supertypes).
- **1260 `collectInline`** — collect every base `inline fn` overload by name.
- **1305 `top_props`** — collect every base top-level `Property` name + scope.

All three only need names/flags, not the full node trees.

## Design

Decouple `built`/`module` from the forest registry and decode each forest decl
lazily on first touch, from a self-contained section (own registry — the proven
deferred-`FunctionBody` pattern, generalised to a whole top-level decl).

1. **Per-decl self-contained sections.** Bake each top-level `lifted_decls[i]`
   into its own encoding (fresh registry, shared nodes duplicated) appended to a
   `lifted_decl_section`, with a parallel `[]u32` offset table. Decode of decl
   `i` reads `decodeOneDecl(section, offsets[i])` standalone, memoised.

2. **Lazy decl references replace forest backrefs.** Every `*const ast.X` in
   `built`/`module` that points into the forest becomes a `DeclRef` = the
   owning top-level decl index plus a path to the node within it (or, where the
   whole function/expr is the unit, just the decl index). At load these stay
   unresolved; the first runtime access (`methodDef.decl(base)`,
   `buildObject.ast(base)`, inline splice) decodes the owning decl and resolves.

3. **Baked indices replace the eager traversals.** Bake
   `class_name -> decl_index`, `inline_name -> []decl_index` (overloads in
   order), and `top_prop -> {name, scope}` so 1143/1260/1305 install indices
   without walking the forest. A class/inline-fn lookup decodes its specific
   decl on demand.

4. **Memoised decode arena.** Decoded decls live in the base's process-lifetime
   arena, decoded at most once (a `?*ast.Decl` slot per index). Touching a decl
   makes its mmap pages + its decoded heap resident; untouched decls cost only
   the offset-table entry.

## Increments (each ends green: full suite + corpus + ktor + bake determinism)

- **I1 — bake additively.** Emit the per-decl sections + offset table + the
  three indices alongside the existing eager `lifted_decls`. Load still uses the
  eager forest. Bump `FORMAT_VERSION`. Verifies the new bake data round-trips.
- **I2 — lazy built/module refs.** Convert forest backrefs to `DeclRef`s;
  resolve on access. Drop the eager forest decode for `built`/`module`.
- **I3 — lazy load traversals.** Replace 1143/1260/1305 with the baked indices.
- **I4 — drop eager `lifted_decls`.** Forest decodes purely on demand. Measure.

## Invariants / risks

- Codec: one registration per watched node (see MEMORY-RECLAMATION.md). A
  desync corrupts backrefs; only ktor itests reliably catch it — run them every
  increment.
- Identity: a forest node reached two ways (e.g. an inline fn's decl via the
  name map and via `inline_ids`) must decode to the **same** memoised pointer,
  or `==` identity checks and double-splices break.
- Determinism: per-decl sections must bake byte-reproducibly (sort any map
  iteration; the `ClassSeed` sort is the precedent).
