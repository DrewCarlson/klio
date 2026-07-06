# Pipeline overview

klio has two entry paths through the front end: **execution**
(`klio run`) and **diagnostics** (`klio check`). They share the
lexer and parser; they diverge after the AST.

## Execution path (`klio run`)

```
.kt bytes
   │
   ▼  lexer            UTF-8 source → tokens
   ▼  parser           tokens → ast.KotlinFile
   ▼  (pack loading)   merge installed pack ASTs into the module
   ▼  ir               AST → register IR (lowering)
   ▼  interp_ir        build the IR module, then Vm.run
   ▼
program output
```

The Vm executes the lowered IR directly. There is no AST evaluator
and no bytecode VM — `ir` lowers every supported construct
(classes, lambdas, suspend state machines, reflection, delegates) to
structured IR instructions, and the Vm dispatches on them. Under the
default `fast` profile, hot loops and functions additionally compile
to native code through the tiered JIT; see
[Performance](performance.md).

With `KLIO_EAGER=1` the run path also executes the resolver and type
checker ahead of lowering, and lowering consumes their answers
(call targets, receiver types) instead of deferring those decisions
to runtime; files the checker cannot finish fall back to the lazy
path.

| Module       | Responsibility                                                              |
|--------------|------------------------------------------------------------------------------|
| `span`       | Source map, file ids, byte and (line, column) positions.                     |
| `lexer`      | UTF-8 source → tokens. Raw strings, templates, escapes; `L00xx` diagnostics. |
| `parser`     | Tokens → `ast.KotlinFile`. Error recovery; `P00xx` diagnostics.              |
| `ir`         | Lowers the AST to the register IR (`Module`, `Func`, `Inst`).                |
| `interp_ir`  | Builds the IR module from one or more files and runs it on the Vm.           |
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

Type-checking does not gate execution: a program that type-checks
clean and a program that merely parses both run through the same Vm
(under `KLIO_EAGER=1` the checker runs on the run path too, but as
an accuracy upgrade for lowering, never as a gate).

## Stdlib and packs

The standard library ships as `stdlib.klio-pack`, embedded into the
binary by `stdlib_pack` as a byte slice. At startup the loader:

1. Decodes the embedded stdlib pack and registers its native
   bindings against `stdlib`'s `HostBindings`.
2. Enumerates `~/.klio/packs/` and `$KLIO_PACKS`, topologically
   sorts packs by their declared dependencies, and merges each
   pack's parsed AST into the IR module so its top-level
   declarations become part of the program.
3. Hands the resolved binding table to the Vm via
   `set_installed_bindings`.

See [Pack Format](../packs/format.md) for the on-disk layout.

To avoid re-lowering the stdlib (and selected packs) on every run, the
CLI bakes the lowered dependency base — the IR module, its registry
side tables, the runtime `ClassDef` graph, and the post-lift AST the
extend path consumes — to a content-addressed image under
`~/.klio/cache` and extends it with just the user program's
declarations on later runs (`src/interp_ir/image.zig`,
`src/cli/stdlib_image.zig`). The image's wire format is the pack
codec's postcard style plus a shared-graph protocol (slice and AST-node
define/backref registries) so cross-references like
`ClassDef.methods[].decl` and inline-function ASTs decode pointing into
the same decoded tree they did in memory.

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
