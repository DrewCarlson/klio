# Diagnostics & tooling integration

Long-term goal: **`klio` is a drop-in source of truth for Kotlin diagnostics that any IDE can consume.** Open a `.kt` file in VS Code, IntelliJ, Neovim, Helix, or Zed and get the same red squigglies, the same hover types, and the same completions an IDE would get from `kotlinc` itself. Run `klio check` from CI and emit SARIF for GitHub Code Scanning. Stream a Language Server over stdio for editor integration.

## Completed

- The `Diagnostic` model + factories: each diagnostic carries a stable kotlinc-canonical factory name (`UNRESOLVED_REFERENCE`, `TYPE_MISMATCH`, …), severity, a primary label, secondary labels, notes, and fix-it suggestions. `Severity` aligns with `kotlinc`'s `CompilerMessageSeverity` (`Error`, `Warning`, `StrongWarning`, `Info`, `Hint`).
- The `T00xx` diagnostic codes, emitted from the typeck checkers (`src/typeck/check.zig` and `src/typeck/check/*`), each attached to its kotlinc-canonical factory name.
- The renderers `plain` (kotlinc-compatible text), `json` (NDJSON, one object per line), and `sarif` (SARIF 2.1.0) under `src/diagnostics/render/`. Each consumes `&[Diagnostic]` + a `SourceMap`; adding a format never touches the checkers.
- `klio check <files…> --format=plain|json|sarif` in `src/cli/commands.zig`, exiting non-zero when any error-severity entry is emitted.

## Principles

1. **Match Kotlin's identifiers.** Every diagnostic that has a counterpart in the real Kotlin compiler uses the **same factory name**. IDEs that already know how to deduplicate / quick-fix those IDs work with us for free. Our internal codes are a secondary, non-stable representation.
2. **Mine the canonical IDs from `kotlin/`.** The factory list lives in the upstream compiler under `compiler/fir/checkers/.../FirErrors.kt`, `Errors.kt`, etc. We do not invent IDs; we mine them, the same way the stdlib surface is mined.
3. **One model, multiple renderers.** Every diagnostic is the same `Diagnostic`. Renderers turn it into plain-text, JSON, SARIF, or LSP `Diagnostic`. Adding a new format never requires changing checkers.
4. **Rich diagnostics, not just messages.** Each diagnostic carries stable ID, severity, primary range, labeled secondary ranges, notes, related information, and fix-it suggestions — the minimum needed for IDEs to do anything useful.
5. **Pull, not push.** The LSP server re-runs analysis on document changes and serves results on demand. Incremental re-parse where cheap; whole-file re-analyze when not. We do not maintain a stale cache.

## The `render::lsp` renderer (unbuilt)

Not built. `src/diagnostics/render/` exports only `plain`/`json`/`sarif` today. `render::lsp` turns the same `Diagnostic` model into an LSP `Diagnostic` — ranges, related information, code actions for fix-its — consumed by the `klio-lsp` binary and by the `--diag-format=lsp` CLI value. `Severity` maps onto the LSP severity enum the same way it already aligns with `CompilerMessageSeverity`.

## The `klio-lsp` binary (unbuilt)

Not built — no `*lsp*` files exist in the tree. A standalone binary, `klio-lsp`, speaking LSP over stdio. It owns per-document state (source text + cached lex/parse/resolve output) and re-runs the pipeline on each `didChange`. Re-parses are fast enough at our scale that incremental parsing is a follow-up optimization, not a launch requirement.

### Supported requests

Initial scope, in priority order:

| Request                              | Backed by                              | Status   |
| ------------------------------------ | -------------------------------------- | -------- |
| `initialize` / `shutdown`            | server boilerplate                     | required |
| `textDocument/didOpen/didChange/…`   | re-lex + re-parse on edit              | required |
| `textDocument/publishDiagnostics`    | full pipeline (lex → parse → resolver) | required |
| `textDocument/hover`                 | resolver + types                       | high     |
| `textDocument/definition`            | resolver (decl span of a use)          | high     |
| `textDocument/references`            | reverse-index over resolver `uses`     | high     |
| `textDocument/completion`            | scope + stdlib FQN catalog             | high     |
| `textDocument/documentSymbol`        | AST outline                            | medium   |
| `textDocument/semanticTokens`        | token stream                           | medium   |
| `textDocument/codeAction`            | fix-its from diagnostics               | medium   |
| `textDocument/signatureHelp`         | callee signature from resolver         | later    |
| `textDocument/rename`                | references + edits                     | later    |
| `textDocument/formatting`            | formatter (future)                     | later    |

### Architecture

```
editor  <-- LSP/stdio -->  klio-lsp  -->  lexer / parser / resolver / types / stdlib
```

The diagnostic model goes through `render::lsp` directly into `publishDiagnostics`. Completion items come from a `CompletionProvider` interface that the resolver and the stdlib registry both implement.

### Performance budget

Editor responsiveness target: **< 50 ms** from keystroke to refreshed diagnostics for files under 10k lines. This is loose enough that the naive "lex + parse + resolve on every change" approach lands well inside it. Measure and optimize only when there is evidence it is needed.

## CLI surface

The shipped flag is `--format=plain|json|sarif` (see Completed). The unbuilt surface is the `lsp` value (`--format=lsp`, the plan's `--diag-format=lsp`), feeding `render::lsp` for editor integration.

## Where the upstream IDs live

`kotlin/compiler/fir/checkers/src/.../FirErrors.kt`, plus related files under `kotlin/compiler/frontend.common/`, `kotlin/compiler/diagnostics/`, and `kotlin/compiler/frontend/`. The same mine → emit generator pattern the stdlib surface uses applies: read the upstream factory list and emit the `DiagnosticFactory` constants checkers reference.

## What we are *not* doing

- Reusing any of Kotlin's actual checker code. We compute diagnostics ourselves; we only borrow the **factory IDs and message templates**.
- Implementing the full IntelliJ inspection set. We map the compiler diagnostics first; community inspections come later if at all.
- A persistent index / build cache. Each LSP session reanalyzes files on open. A cross-file index is a follow-up once multi-file resolution is in place.
