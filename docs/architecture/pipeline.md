# Pipeline overview

klio has two entry paths through the front end: **execution**
(`klio run`) and **diagnostics** (`klio check`). They share the
lexer and parser; they diverge after the AST.

## Execution path (`klio run`, `klio test`)

```
.kt bytes
   │
   ▼  lexer            UTF-8 source → tokens
   ▼  parser           tokens → ast.KotlinFile
   ▼  (pack loading)   the stdlib and the program's declared packs, as sources
   ▼  @Serializable    the serialization plugin splices its members into the files
   ▼  sema             symbols, headers and bodies: every name bound to a symbol
   ▼  bridge           sema's symbols → IR ids (classes, functions, fields, slots)
   ▼  lower            sema's records → register IR (`ir/lower/sema`, with @Composable)
   ▼  interp_ir        the Vm runs the lowered module
   ▼
program output
```

The Vm executes the lowered IR directly. There is no AST evaluator
and no bytecode VM — `ir/lower/sema` lowers every supported construct
(classes, lambdas, suspend state machines, reflection, delegates) to
IR instructions that name their targets by id, and the Vm dispatches on
them. Under the
default `fast` profile, hot loops and functions additionally compile
to native code through the tiered JIT; see
[Performance](performance.md).

Every node sema will record a fact on carries an `ast.NodeId`: each
expression, block, assignment, destructuring declaration, catch clause,
declaration, parameter and `$name` template part. The parser numbers a
file's nodes in source order from 1 (a node before its children) and
leaves the next free id in `KotlinFile.node_count`; 0 is `none`, the id of
a node a later pass built. The `@Serializable` pass parses each snippet it
splices into a file with ids continuing from that file's count. In Debug
builds `ast.checkIds` runs after the parse and after that pass and panics
on an id held by two nodes, which is what a pass copying an `Expr` leaves.

A pack file's class typealiases are expanded in its function signatures
and constructor parameters as it loads (`ast.expandFileClassAliases`);
every other alias is resolved by sema.

| Module       | Responsibility                                                              |
|--------------|------------------------------------------------------------------------------|
| `span`       | Source map, file ids, byte and (line, column) positions.                     |
| `lexer`      | UTF-8 source → tokens. Raw strings, templates, escapes; `L00xx` diagnostics. |
| `parser`     | Tokens → `ast.KotlinFile`. Error recovery; `P00xx` diagnostics.              |
| `sema`       | Symbols, declaration headers and body analysis; the records lowering reads.  |
| `ir`         | The register IR (`Module`, `Func`, `Inst`), the bridge and the lowering.     |
| `lower_driver` | Drives sema, the bridge and lowering over a base and a program.            |
| `interp_ir`  | The Vm that runs the lowered module.                                         |
| `runtime`    | Runtime `Value`, instance data, and the `Output` sink.                       |

## Diagnostics path (`klio check`)

```
.kt bytes → lexer → parser → resolver → typeck
                                          │
                                          ▼
                        plain / json / sarif diagnostics
```

`klio check` does not run the program. It resolves names and
type-checks for diagnostics only, then renders them and exits
non-zero on any error.

| Module      | Responsibility                                                                |
|-------------|-------------------------------------------------------------------------------|
| `resolver`  | Name binding, import expansion, package recognition; `R00xx` diagnostics.     |
| `typeck`    | Type system, smart casts, intersection types, inference; `T00xx` / `W00xx`.   |
| `cfa`       | Control- and data-flow analyses (definite assignment, reachability) used by type checking. |
| `types`     | Kotlin `Type` model, variance, inference constraint kinds.                    |

`klio run` does not run the resolver or the type checker; sema reports
the errors that stop a program from running.

## Stdlib and packs

The standard library ships as `stdlib.klio-pack`, embedded into the
binary by `stdlib_pack` as a byte slice. At startup the loader:

1. Decodes the embedded stdlib pack and registers its native
   bindings against `stdlib`'s `HostBindings`.
2. Enumerates `~/.klio/packs/` and `$KLIO_PACKS`, topologically
   sorts packs by their declared dependencies, and adds each pack's
   parsed sources to the base the program is analyzed over.

See [Pack Format](../packs/format.md) for the on-disk layout.

To avoid analyzing and lowering the stdlib (and selected packs) on every
run, the CLI bakes the base's bridge and lowered bodies to a
content-addressed image, `$KLIO_HOME/.klio/cache/sema-base-<key>.klio-sema`
(`src/lower_driver/base_image.zig`, `src/cli/sema_base_cache.zig`), and
later runs analyze and lower only the program over it. The image is
written in the value codec of `src/interp_ir/codec.zig`: the pack
codec's postcard style plus a shared-graph protocol (slice and AST-node
define/backref registries), so cross-references decode pointing into the
same decoded tree they did in memory. `klio bake-image` and `klio bundle`
write a self-contained image (`src/cli/sema_image.zig`) that carries the
base image with the sources it was baked from.

## Diagnostics model

Every front-end pass emits through `diagnostics.DiagnosticSink`,
which renders to plain text, JSON, or SARIF. Codes are prefixed by
the originating pass — `L0001`, `P0044`, `R0003`, `T0050`. See
[Diagnostics](diagnostics.md).

## Testing

- Unit tests live alongside each module as `test {}` blocks.
- The `parity` module runs every `.kt` under
  `tests/fixtures/parity_corpus/` and `examples/` through both
  `kotlinc` and klio and diffs stdout. A green parity sweep is a
  primary correctness gate.
- The upstream stdlib's own `commonTest` suite runs directly under
  the interpreter (`src/itests/stdlib_commontest.zig`, driven ad hoc
  by `scripts/commontest-sweep.py`).
- Negative tests in `src/itests/typeck_negative.zig` lock diagnostic
  wording and codes.

See [Testing and verification](../development/testing.md) for the
full workflow.
