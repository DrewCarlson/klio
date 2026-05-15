# Pipeline overview

klio has two entry paths through the front end: **execution**
(`klio run`) and **diagnostics** (`klio check`). They share the
lexer and parser; they diverge after the AST.

## Execution path (`klio run`)

```
.kt bytes
   │
   ▼  klio-lexer       UTF-8 source → tokens
   ▼  klio-parser      tokens → klio_ast::KotlinFile
   ▼  (pack loading)   merge installed pack ASTs into the module
   ▼  klio-ir          AST → register IR (lowering)
   ▼  klio-interp-ir   build the IR module, then Vm::run
   ▼
program output
```

The Vm executes the lowered IR directly. There is no AST evaluator
and no bytecode VM — `klio-ir` lowers every supported construct
(classes, lambdas, suspend state machines, reflection, delegates) to
structured IR instructions, and the Vm dispatches on them.

| Crate            | Responsibility                                                              |
|------------------|------------------------------------------------------------------------------|
| `klio-span`      | Source map, file ids, byte and (line, column) positions.                     |
| `klio-lexer`     | UTF-8 source → tokens. Raw strings, templates, escapes; `L00xx` diagnostics. |
| `klio-parser`    | Tokens → `klio_ast::KotlinFile`. Error recovery; `P00xx` diagnostics.        |
| `klio-ir`        | Lowers the AST to the register IR (`Module`, `Func`, `Inst`).                |
| `klio-interp-ir` | Builds the IR module from one or more files and runs it on the Vm.           |
| `klio-runtime`   | Runtime `Value`, instance data, and the `Output` sink.                       |

## Diagnostics path (`klio check`)

```
.kt bytes → klio-lexer → klio-parser → klio-resolver → klio-typeck
                                                           │
                                                           ▼
                                         plain / json / sarif diagnostics
```

`klio check` does not run the program. It resolves names and
type-checks for diagnostics only, then renders them and exits
non-zero on any error.

| Crate           | Responsibility                                                                |
|-----------------|-------------------------------------------------------------------------------|
| `klio-resolver` | Name binding, import expansion, package recognition; `R00xx` diagnostics.     |
| `klio-typeck`   | Type system, smart casts, intersection types, inference; `T00xx` / `W00xx`.   |
| `klio-cfa`      | Control- and data-flow analyses (definite assignment, reachability) used by type checking. |
| `klio-types`    | Kotlin `Type` model, variance, inference constraint kinds.                    |

Type-checking is not on the execution path today: a program that
type-checks clean and a program that merely parses both run through
the same Vm.

## Stdlib and packs

The standard library ships as `stdlib.klio-pack`, embedded into the
binary by `klio-stdlib-pack` as `&[u8]`. At startup the loader:

1. Decodes the embedded stdlib pack and registers its native
   bindings against `klio-stdlib`'s `HostBindings`.
2. Enumerates `~/.klio/packs/` and `$KLIO_PACKS`, topologically
   sorts packs by their declared dependencies, and merges each
   pack's parsed AST into the IR module so its top-level
   declarations become part of the program.
3. Hands the resolved binding table to the Vm via
   `set_installed_bindings`.

See [Pack Format](../packs/format.md) for the on-disk layout.

## Diagnostics model

Every front-end pass emits through `klio_diagnostics::DiagnosticSink`,
which renders to plain text, JSON, or SARIF. Codes are prefixed by
the originating pass — `L0001`, `P0044`, `R0003`, `T0050`. See
[Diagnostics](diagnostics.md).

## Testing

- Unit tests live alongside each crate.
- `crates/klio-parity/` runs every `.kt` under
  `crates/klio-parity/tests/corpus/` and `examples/` through both
  `kotlinc` and klio and diffs stdout. A green parity sweep is the
  primary correctness gate.
- Negative tests under `crates/klio-typeck/tests/` lock diagnostic
  wording and codes.
