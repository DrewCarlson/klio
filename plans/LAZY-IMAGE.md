# Lazy / position-independent stdlib image

## Goal

Stop materialising the whole stdlib AST forest at process start. A simple program executes almost none of the ~6000 baked decls; the unused ones stay file-backed in the mmap and never become resident. Target: cut the ~24.8 MB eager `image.decode` toward Python-level (~15 MB) for simple/stdlib programs, with ktor and the full suite green. Starting point (before the work): hello-world ~43 MB gc / 48 MB arena; the AST forest skeleton (`lifted_decls`) was ~12 MB of that. Phase B target: ~31 MB gc.

## Completed

- **Forest resolver** — `src/runtime/forest.zig`: `ForestRef` (`{decl, ord}`), `ForestField(T)` = `union(enum) { ptr, ref }` with `.get()` (build/runtime-class/tests set `.ptr`, image load sets `.ref`), `reserveSlot`/`slotBase`/`fillSlot`/`setSection`, and `resolve{Node,Expr,Function,Accessor,Block,SecondaryCtor}` over a memoised, mutex-guarded per-decl decode.
- **Per-decl image sections** — each top-level `lifted_decls[i]` is baked into its own self-contained encoding (fresh registry) appended to `ImageRoot.lifted_decl_section`, with the parallel `lifted_decl_offsets` table (`src/interp_ir/image.zig:1035-1061`). Decl `i` decodes standalone via `decodeOneDecl(section, offsets[i])`, memoised.
- **Baked indices as ForestRefs** — `inline_by_name`, `file_classes`, and `top_props` (`image.zig:1063-1116`) install the load-time inline/class/top-prop maps as `ForestRef`s, replacing the three whole-forest load traversals (`collectInline` / `file_classes` / `top_props`).
- **Lazy `.ref` decode at load** — built/module fields that used to backref the forest registry (`MethodDef.decl`, `PropertyDef.init/getter/setter/delegate`, `ClassDef.parent_ctor_args/init_blocks/secondary_ctors`, `inline_ids`, `BuildObject.ast`) encode as `ForestRef` via the bake-time `addr -> ForestRef` map and resolve through the forest resolver on first access.
- **The flip landed.** Bake drops the eager forest from the payload — `image.zig:1123` sets `root.lifted_decls = &.{}` before encoding — so the on-disk image no longer carries the ~12 MB forest skeleton, and the load path reconstructs `base.lifted_decls` as the empty slice (`image.zig:1865`). The full AST forest no longer materialises at startup; an untouched decl costs only its offset-table entry.

## Remaining

- **Confirm the RSS win.** Measure hello-world and simple-stdlib gc + arena against the ~31 MB gc target (and toward the ~15 MB stretch), with ktor and the full suite green. The goal is a measured flip; this measurement has not been recorded.
- **Stale comment.** `lifted_decls: []ast.Decl` (`image.zig:773`) is retained as a struct field but now bakes empty. The comment at `image.zig:1039` ("the eager `lifted_decls` stay in the payload until the lazy path is the default; the loader picks one") predates the unconditional drop at `:1123` and should be removed.

## Invariants / risks

- **Codec.** One registration per watched node. A desync corrupts backrefs; only ktor itests reliably catch it — run them every increment.
- **Identity.** A forest node reached two ways (e.g. an inline fn's decl via the name map and via `inline_ids`) must decode to the **same** memoised pointer, or `==` identity checks and double-splices break.
- **Determinism.** Per-decl sections must bake byte-reproducibly (sort any map iteration; the `ClassSeed` sort is the precedent).
