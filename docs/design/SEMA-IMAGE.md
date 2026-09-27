# The sema image

A run analyzes and lowers only its program. What it knows about the base (the
stdlib, klio's actuals and the program's packs) comes from the base image: the
bridge and the lowered module, and sema's own state for the base. A run over a
cached image reads no base source and builds no base AST.

## What the image carries

The image (`src/lower_driver/base_image.zig`) is one file in three parts.

- **The front** (`base_image.Front`), readable alone: each base file's path
  and where its lines start, and the baking driver's own record of the base
  (for `klio run`, the packs' meta-serializable annotation names). A run
  registers the files in its source map before its program's, with no text,
  so the base's spans name the same files and a frame in a base function still
  names its line.
- **Sema** (`src/lower_driver/base_sema.zig`): every symbol of the bake with
  its per-kind info, headers resolved and return and property types inferred;
  the member and package indexes; the type store; the names; the function
  classes, SAM constructors and builtins. A symbol from the image has no AST:
  its `Decl` keeps the kind of declaration and points nowhere.
- **The bridge and the module**, as before: ids, layouts, dispatch tables and
  the lowered bodies, a body decoding on its first call.

What a program's analysis, the bridge and lowering ask about a base
declaration beyond its header is in sema's tables, filled from the AST when
the declaration is collected or asked about, and asked of every base
declaration before the bake encodes (`base_sema.complete`):

| Fact | Where |
|------|-------|
| Annotation classes, by site: the declaration, a property's getter or setter, a parameter's written type | `Sema.annotation_classes` |
| Deprecation level and message | `Sema.deprecations` |
| Contract effects, as conditions over parameter indexes and resolved types | `Sema.contracts` |
| What a property writes: a getter, a setter, an initializer, an explicit backing field | `PropertyInfo.written` |
| A body that is `{}` | `FunctionInfo.empty_body` |
| `sealed` on an interface | `ClassInfo.sealed` |
| `@IntrinsicConstEvaluation` | `Flags.intrinsic_const` |

A read of a declaration's AST either answers from these tables or unwraps the
pointer where only a declaration this build analyzes from source can arrive
(its own body, its lazily resolved header), so a gap fails at the read.

Member indexes iterate in the order names were declared, and the image
rebuilds them in that order, so walking one walks the same members the same
way over the image as over source. Growable lists (`codec.Growable`) decode
with room to append, so the program's symbols extend the base's tables in
place.

## A run

1. The program's files parse.
2. The base is named before any of it parses (`sema_base_cache.Key`): the
   binary's stamp, the image layout's version, the stdlib's and the actuals'
   paths and texts, and each selected pack's content hash and active
   features in load order. Packs are selected from their manifests and import
   sections, parsing none.
3. With a cached image of that name, the image's front registers the base's
   files and the program joins the source map after them
   (`sema_cmd.loadSources`, `LoadOptions.image`); `pipeline.buildOnImage`
   decodes the base's sema, bridge and module and analyzes, bridges and lowers
   the program over them.
4. With none, the base parses, is analyzed and lowered, and is baked under
   that name; the run continues from the bytes it baked, as step 3 does.

A program the serialization pass rewrites (one writing `@Serializable`, or
using a pack's meta-serializable annotation, which the front names) still
parses its base: the pass generates its serializers from the packs'
declarations as written. Its analysis runs over the image's sema all the same.

## Verifying

- Baking a base twice with one binary gives the same bytes; so does
  re-encoding an image read back, its bodies decoded
  (`src/lower_driver/tests/image.zig`).
- Every lowering test runs its program over the whole base, over a baked
  base, and over a base read from its image alone (`expectOutputOver`).
- The corpus, the stdlib commontest sweep, the e2e suite and the gate.
