# Architecture

## Pipeline

```
source text
  │
  ▼  klio-span      (SourceMap, FileId, Span)
  ▼  klio-lexer     (Token stream)
  ▼  klio-parser    (AST + diagnostics)
  ▼  klio-ast       (typed nodes)
  ▼  [future] klio-resolver / klio-types
  ▼  klio-interp    (tree-walking evaluator)
  ▼  klio-cli       (binary: lex / parse / run / repl)
```

## Crate responsibilities

### klio-span
Source storage and positions. Owns `SourceMap`, `SourceFile`, `FileId`, and `Span`. No dependencies on other workspace crates. Provides line/column mapping for diagnostics.

### klio-diagnostics
The `Diagnostic` model: severity, code, primary label, secondary labels, notes. `DiagnosticSink` accumulates diagnostics during a pass. Rendering today is plain text; the `ariadne` dep is reserved for richer terminal output once the lexer/parser emit real spans.

### klio-lexer
Pure tokenizer. Input: `&str` + `FileId`. Output: `Vec<Token>` terminated by `Eof`. Trivia (whitespace, newlines, comments) is preserved as tokens so the parser can consult newlines for Kotlin's semicolon-insertion rules.

### klio-ast
Plain data structs/enums for AST nodes. No methods that touch I/O. Every node carries a `Span`. The parser is the only producer; the interpreter and (eventually) resolver are consumers.

### klio-parser
Hand-written recursive-descent. Single forward token cursor with bounded lookahead. Errors are reported as diagnostics; the parser attempts local recovery so a single file emits as many useful errors as possible.

### klio-interp
Tree-walking evaluator. `Value` enum covers primitives + `Unit` + `Null`. `Env` is a flat name→value map for now; lexical scopes will become a parent-pointer chain when blocks land. Runtime errors flow back through `RuntimeError`.

### klio-cli
The `klio` binary. Subcommands: `lex`, `parse`, `run`, `repl`. Owns the `SourceMap` for a single invocation and prints diagnostics rendered against it.

## Design choices

- **Workspace, not one crate.** Lets adversarial agents iterate on lexer/parser/interp independently and keeps compile times low as the project grows.
- **`Span` over `Range`.** Encodes file identity so diagnostics never confuse two files.
- **Diagnostics-first.** Even the skeleton parser threads a `DiagnosticSink` through, so error reporting is never bolted on later.
- **No `unsafe`.** Forbid at workspace level. Anything performance-sensitive can opt in per-crate if/when measured.
- **Edition 2024, resolver 3.** Latest stable toolchain pinned via `rust-toolchain.toml`.

## Future crates (not yet scaffolded)

- `klio-resolver` — name resolution, scope tree, import handling.
- `klio-types` — type system + inference per Kotlin spec.
- `klio-stdlib` — Kotlin stdlib surface backed by Rust (see below).
- `klio-stdlib-gen` — codegen binary that reads `kotlin/libraries/stdlib/` and produces registration tables + per-function stubs into `klio-stdlib`.
- `klio-diagnostics-gen` — codegen binary that mines `kotlin/compiler/.../FirErrors.kt` etc. for canonical diagnostic factory IDs and message templates, emitting them as constants into `klio-diagnostics`. See [`docs/DIAGNOSTICS.md`](DIAGNOSTICS.md).
- `klio-lsp` — Language Server Protocol implementation. Binary speaks LSP over stdio; backed by `klio-lexer` + `klio-parser` + `klio-resolver` + `klio-types` + `klio-stdlib`. See [`docs/DIAGNOSTICS.md`](DIAGNOSTICS.md).
- `klio-fmt` / `klio-bench` — optional tooling.

## Reference checkouts

Two sibling directories live next to the workspace and are gitignored:

- `kotlin-language-spec/` — spec PDFs by section.
- `kotlin/` — JetBrains/kotlin at tag **v2.3.21**, our target language version.

### Target Kotlin version

Everything we implement targets **Kotlin 2.3.21**. When the spec PDFs and the `kotlin/` source disagree, the source wins, because that is what real Kotlin code is compiled against today.

### Using the `kotlin/` checkout

- `kotlin/compiler/` is a cross-reference for tokenization, parsing, and resolution behavior — useful when the spec is ambiguous.
- `kotlin/libraries/stdlib/` is the **source of truth for the Kotlin standard library** that we will ship inside the interpreter. The `common/` subtree (and `common-non-jvm/` where applicable) describes the surface we are committing to support. Platform-specialized trees (`jvm/`, `js/`, `native-wasm/`, `wasm/`) are read only for understanding intrinsics; we will not ship platform-specific stdlib variants.

### Stdlib strategy

The `klio-stdlib` crate exposes the Kotlin stdlib to the interpreter. Headline decisions:

- **Native, not interpreted.** Every stdlib function is implemented in **Rust**, like CPython implements its standard library in C. The interpreter dispatches `kotlin.*` calls directly to Rust intrinsics; we do not interpret upstream Kotlin source at runtime.
- **Auto-generated API surface.** A companion binary, `klio-stdlib-gen`, reads `kotlin/libraries/stdlib/` and emits the registration tables, signature descriptors, and per-function stubs under `crates/klio-stdlib/src/generated/`. Humans then replace the stubs with hand-written Rust implementations. This keeps the surface aligned with Kotlin 2.3.21 mechanically rather than by hand.
- **`kotlin/` is input, never linked.** We consume the upstream tree as source for codegen and as a semantics reference. We do not call into JVM / JS / Native runtimes.

Full details: see [`docs/STDLIB.md`](STDLIB.md).

### Scope: stdlib, not third-party libraries

Near-term scope is the Kotlin language plus a full built-in implementation of the Kotlin stdlib. Loading or interoperating with third-party Kotlin/JVM libraries (Maven artifacts, `.jar` / `.klib` consumption, classpath scanning, etc.) is explicitly **out of scope** for the foreseeable future. A program run by `klio` may depend only on the language and the bundled stdlib. Anything outside the stdlib surface should fail to resolve with a clear diagnostic, not silently succeed.
