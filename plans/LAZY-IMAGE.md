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

## Refined design (decl,ordinal ForestRef + global resolver)

Member-index navigation is fragile (synthesized methods, ordering), so resolve
forest refs **generically** by node ordinal:

- **Bake.** While emitting each per-decl self-contained section (Step 1, landed),
  capture `encoder.nodes` after each decl: `global_addr -> ForestRef{decl: u32,
  ord: u32}` (`ord` = the node's index in that decl's fresh registry). Then when
  encoding `built`/`module`, every field that currently backrefs the forest
  registry instead stores its `ForestRef` (looked up by pointer address). The
  eager `lifted_decls` is then dropped from the payload.
- **`ForestRef = struct { decl: u32, ord: u32 }`** — two varints; the generic
  struct codec already handles it. Image structs (`ClassDefImage`,
  `MethodImage`, `PropertyDefImage`, `inline_ids`, `BuildObject`) use `ForestRef`
  in place of `*const ast.X` for forest-pointing fields.
- **Global resolver (runtime, injected decode fn — mirrors `inline_state`'s
  `deferred_decode`).** `setForestSection(section, offsets, arena, decodeFn)`;
  `resolveNode(ref) usize` decodes `offsets[ref.decl]` once (memoised
  `[]?{decl, registry}`), returns `registry[ref.ord]`. `decodeLiftedDeclWithRegistry`
  returns the decoded decl plus its `Decoder.nodes` array (the ordinal table).
  Decl decode order in the decoder matches the bake encoder exactly, so
  `ord` is stable.
- **Runtime structs** (`MethodDef`, `PropertyDef`, `ClassDef`) hold `ForestRef`s
  + memoised `?*const ast.X`; accessors resolve via the global on first read.

## Reader surface (verified — every site that must route through the resolver)

`MethodDef.decl` (~6, all field-reads, NO identity compares):
- `class.zig:504,536,551` (findMethodWalk/findMethodForArgWalk/firstParamTypeMatches: `.body`, `.params`)
- `value.zig:1345,1597` (`.name`, `.params.len`); `host_call_member.zig:1049` (`.params.len`)

`PropertyDef.init/getter/setter/delegate` + `ClassDef.parent_ctor_args/init_blocks/secondary_ctors` runtime reads:
- `host_instances.zig` (instantiation): init reads at 2376, 2812, 3018; getter 2778; init_blocks AST walk 2836; init_block_property_positions 804
- `host_call_value.zig:186-190` (init/getter/delegate/primitive_zero for default values)
- `host_fields.zig:1548` (getter/delegate null checks)
- `host_classes.zig:463-469` (copies PropertyDef AST pointers when registering a runtime class)
- `parentCtorArgThunks`/`secondaryCtors`/init-block lookups read side-tables keyed by FuncId, NOT the AST pointers — those are safe.

Bake-time only (NOT per-run-load — no resolver needed): `prune.zig:136-149`,
`qualified_refs.zig:238-272`, and all of `build.zig` (constructs from AST at
bake). `Inst.BuildObject.ast`/`RegisterClass.class` point into KEPT
(object-bearing / non-deferred) function bodies — those functions can't be
body-deferred, but their owning decls are still in the lazy forest, so the
ref must become a `ForestRef` too.

Three load traversals to replace with baked indices: `file_classes` (class
name -> decl idx), `collectInline` (inline name -> ordered decl idxs),
`top_props` (name + scope).

## Eager vs lazy duality (verified) → `union { ptr, ref }`

`buildClassDef` sets `methods = &.{}`; `MethodDef.decl` is populated only by the
image load (`methodsFromImage`, a forest pointer) and by unit-test helpers (a
real `*ast.Function`). But `PropertyDef.init/getter/setter/delegate` and
`ClassDef.parent_ctor_args/init_blocks/secondary_ctors` are set by **both** the
build path (real pointers into the live, un-sectioned `lifted_decls` — the
image-disabled fallback) **and** the image load (forest backref). So a forest
field must hold either form:

```
ForestField(T) = union(enum) { ptr: *const T, ref: forest.ForestRef };
fn get(self) *const T { return switch (self) { .ptr => |p| p, .ref => |r| forest.resolve…(r).? }; }
```

Build / runtime-class / tests set `.ptr` (eager); image load sets `.ref` (lazy).
Readers call `.get()`. The forest resolver memoises per-decl decode, so repeated
`.get()` on a `.ref` is O(1) after first touch — no per-field memo needed.

## Flip plan — split into a safe mechanical phase + a focused behavioral flip

- **Phase A (mechanical, behavior-preserving, green):** change each forest field
  to `ForestField`, route the verified readers through `.get()`, and have
  `methodsFromImage`/`classDefFromImage` set `.ptr` (still resolving the forest
  backref eagerly, as today). No RSS change; validates the union + accessor
  plumbing across the whole surface. Do this one field at a time (vertical
  slices), each green.
- **Phase B (behavioral flip, the RSS win):** bake the `addr -> ForestRef` map
  during the per-decl section loop; `*ToImage` emit `ForestRef`; image load sets
  `.ref` (not `.ptr`); stop encoding the eager `lifted_decls` in the payload;
  replace the three load traversals (`file_classes`/`collectInline`/`top_props`)
  with baked indices. Measure (~31 MB gc target).

## Status

- **Step 1 (per-decl sections) — landed** (`b43476d9`).
- **Forest resolver — landed** (`3481bccc`): `runtime.forest` (ForestRef,
  setSection, resolve{Node,Expr,Function,Accessor,Block,SecondaryCtor},
  memoised per-decl decode + mutex), `decodeLiftedDeclReg`, installed at load
  (inert until the flip), round-trip test.
- **Design + verified reader surface — landed** (`428efb7a`, this section).
- Next: Phase A (union+accessors, per-field vertical slices), then Phase B.

## Invariants / risks

- Codec: one registration per watched node (see MEMORY-RECLAMATION.md). A
  desync corrupts backrefs; only ktor itests reliably catch it — run them every
  increment.
- Identity: a forest node reached two ways (e.g. an inline fn's decl via the
  name map and via `inline_ids`) must decode to the **same** memoised pointer,
  or `==` identity checks and double-splices break.
- Determinism: per-decl sections must bake byte-reproducibly (sort any map
  iteration; the `ClassSeed` sort is the precedent).
