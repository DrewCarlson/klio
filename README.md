# kt-exp

Experimental Kotlin interpreter written in Rust.

The binary is `ktc`. Pipeline: `ktc-lexer` → `ktc-parser` (→ `ktc-ast`) → `ktc-interp`, with shared `ktc-span` and `ktc-diagnostics` crates.

## Layout

```
crates/
  ktc-span         Source files, file ids, byte spans, line/col mapping.
  ktc-diagnostics  Error/warning model with labels, notes, and rendering.
  ktc-lexer        Tokenizer for Kotlin source.
  ktc-ast          AST node definitions.
  ktc-parser       Recursive-descent parser producing AST + diagnostics.
  ktc-interp       Tree-walking interpreter over the AST.
  ktc-cli          `ktc` binary: lex/parse/run/repl commands.
```

## Build & run

```
cargo build
cargo run -p ktc-cli -- lex path/to/file.kt
cargo run -p ktc-cli -- parse path/to/file.kt
cargo run -p ktc-cli -- run path/to/file.kt
cargo run -p ktc-cli -- repl
```

Try the bundled example, which exercises every piece of functionality currently wired through the interpreter:

```
cargo run -p ktc-cli -- run examples/showcase.kt
```

More runnable programs (and the policy for adding new ones as features land) live in [`examples/README.md`](examples/README.md).

## Status

Scaffolding only. See [`docs/PLAN.md`](docs/PLAN.md) for the running plan and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the crate-level design.

## Reference sources

Two trees under this repo are used as references and are gitignored:

- `kotlin-language-spec/` — official Kotlin language spec PDFs, consulted for tricky internal details.
- `kotlin/` — checkout of [JetBrains/kotlin](https://github.com/JetBrains/kotlin) at tag **v2.3.21**, our target language version. We read it for compiler/spec cross-reference and, importantly, take `libraries/stdlib/` as the source of truth for the Kotlin standard library we will build into the interpreter.

### Scope: stdlib, not third-party libraries

Near-term scope is the Kotlin language plus a full built-in implementation of the Kotlin stdlib. Loading or interoperating with third-party Kotlin/JVM libraries (Maven artifacts, `.jar`/`.klib` consumption, etc.) is explicitly **out of scope** for the foreseeable future. A program targeting `ktc` may only depend on the language and the bundled stdlib.

The stdlib will be implemented natively in Rust (CPython-style) for performance, with its API surface auto-generated from `kotlin/libraries/stdlib/`. See [`docs/STDLIB.md`](docs/STDLIB.md) for the strategy and [`docs/PLAN.md`](docs/PLAN.md) milestones 5, 6, 9, and 10 for the rollout.

### Compiler parity

We commit to zero deliberate divergence from `kotlinc`. Every example must produce byte-identical output to the real Kotlin compiler. Parity is enforced by a `ktc-parity` test harness that runs each program under both `kotlinc-native` (currently pinned to 2.3.21) and `ktc`, diffing the result. Tracked in M7 of [`docs/PLAN.md`](docs/PLAN.md).

### IDE / tooling integration

`ktc` is on track to be a drop-in source of truth for Kotlin diagnostics in any IDE: kotlinc-compatible plain output, JSON + SARIF for static-analysis tooling, and a Language Server (`ktc-lsp`) speaking LSP over stdio. Diagnostic factory IDs (`UNRESOLVED_REFERENCE`, `TYPE_MISMATCH`, etc.) are mined from the upstream Kotlin compiler so existing IDE infrastructure works without translation. Strategy: [`docs/DIAGNOSTICS.md`](docs/DIAGNOSTICS.md). Milestone: M8 in [`docs/PLAN.md`](docs/PLAN.md).

## License

MIT OR Apache-2.0.
