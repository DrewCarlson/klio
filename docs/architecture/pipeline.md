# Pipeline overview

Every `klio run` invocation walks one or more `.kt` source files
through six discrete crates:

```
.kt bytes
    │
    ▼
┌──────────────┐    ┌───────────────┐    ┌───────────────┐
│  klio-lexer  │ ─▶ │  klio-parser  │ ─▶ │ klio-resolver │
└──────────────┘    └───────────────┘    └───────────────┘
                                                │
                                                ▼
┌──────────────┐    ┌───────────────┐    ┌───────────────┐
│  klio-interp │ ◀─ │   klio-cfa    │ ◀─ │ klio-typeck   │
└──────────────┘    └───────────────┘    └───────────────┘
```

| Crate          | Responsibility                                                                                  |
|----------------|-------------------------------------------------------------------------------------------------|
| `klio-span`    | Source map, file ids, byte and (line, column) positions used by every diagnostic.               |
| `klio-lexer`   | UTF-8 source → token stream. Handles raw strings, string templates, regex-like escapes.         |
| `klio-parser`  | Tokens → `klio_ast::KotlinFile`. Recovers from syntax errors and emits `P00xx` diagnostics.     |
| `klio-resolver`| Name binding, import expansion, package recognition, `R00xx` diagnostics.                       |
| `klio-typeck`  | Kotlin type system, smart-casts, intersection types, constraint solving, `T00xx` diagnostics.   |
| `klio-cfa`     | Spec §12 control- and data-flow analyses: VIA, reachability, smart-cast narrowing, contracts.   |
| `klio-interp`  | Tree-walking interpreter. Reads typed AST + CFA tables, executes the program.                   |

Two supporting crates carry shared types:

- `klio-ast` — the AST nodes the parser produces and every later
  pass reads.
- `klio-types` — Kotlin `Type` IR, intersection variant, variance,
  inference constraint kinds.

## Stdlib and packs

A bundled `stdlib.klio-pack` ships inside the `klio-stdlib-pack`
crate as `&[u8]`. At startup the interpreter:

1. Decodes the embedded pack.
2. Registers every binding listed in the pack against
   `klio-stdlib`'s `HostBindings`.
3. Walks `~/.klio/packs/` and `$KLIO_PACKS`, installs every cached
   pack in topological dependency order, and runs each pack's
   Kotlin sources through `register_pack_sources` so its top-level
   declarations land in the same globals the user program sees.

See [Pack Format](../packs/format.md) for the on-disk layout.

## Diagnostics

Every pass emits diagnostics through `klio-diagnostics::DiagnosticSink`,
which renders to plain text, JSON, or SARIF. Diagnostic codes are
prefixed by the originating pass — `T0050`, `R0003`, `P0044`, etc.
The full table lives at [`plans/DIAGNOSTICS.md`](https://github.com/DrewCarlson/kt-exp/blob/main/plans/DIAGNOSTICS.md).

## Testing

- Unit tests live alongside each crate.
- `crates/klio-parity/` walks every `.kt` in the corpus and in
  `examples/`, compiles each through `kotlinc-native 2.3.21` and
  through klio, and diffs stdout. A green parity sweep is the
  primary correctness gate.
- Negative tests under `crates/klio-typeck/tests/negative/` lock
  every diagnostic against its expected wording and code.
