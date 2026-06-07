# Diagnostics & tooling integration

Long-term goal: **`klio` is a drop-in source of truth for Kotlin diagnostics that any IDE can consume.** Open a `.kt` file in VS Code, IntelliJ, Neovim, Helix, or Zed and get the same red squigglies, the same hover types, and the same completions an IDE would get from `kotlinc` itself. Run `klio check` from CI and emit SARIF for GitHub Code Scanning. Stream a Language Server over stdio for editor integration.

This document is the design. Implementation milestones live in [`PLAN.md`](PLAN.md) (M7).

## Why now

We are about to add many more diagnostics (stdlib type errors, exception checking, smart-cast analysis, unused warnings). Each one we cement before the model is right is one we have to retrofit later. The infrastructure should harden **once**, then every new check is a single factory entry plus an emission site.

## Principles

1. **Match Kotlin's identifiers.** Every diagnostic we emit that has a counterpart in the real Kotlin compiler uses the **same factory name** (`UNRESOLVED_REFERENCE`, `TYPE_MISMATCH`, `VAL_REASSIGNMENT`, …). IDEs that already know how to deduplicate / quick-fix those IDs work with us for free. Our internal `E0001`-style codes become a secondary, non-stable representation.
2. **Mine the canonical IDs from `kotlin/`.** The list of factories lives in the upstream compiler under `compiler/fir/checkers/.../FirErrors.kt`, `Errors.kt`, etc. We do not invent IDs; we mine them, the same way `klio-stdlib-gen` mines the stdlib surface.
3. **One model, multiple renderers.** Every diagnostic is the same `Diagnostic` struct. Renderers turn it into plain-text (kotlinc-compatible), JSON, SARIF 2.1.0, or LSP `Diagnostic`. Adding a new format never requires changing checkers.
4. **Rich diagnostics, not just messages.** Each diagnostic carries: stable ID, severity, primary range, labeled secondary ranges, notes, related information, fix-it suggestions. This is the minimum needed for IDEs to do anything useful.
5. **Pull, not push.** The LSP server re-runs analysis on document changes and serves results on demand. Incremental re-parse where cheap; whole-file re-analyze when not. We do not maintain a stale cache.

## The diagnostic model

`Diagnostic` evolves from today's plain struct to something closer to Kotlin's:

```rust
pub struct Diagnostic {
    pub factory: DiagnosticFactory,    // stable ID + severity + msg template
    pub severity: Severity,             // can override factory default
    pub primary: Label,                 // span + display message
    pub secondary: Vec<Label>,
    pub notes: Vec<String>,
    pub fixits: Vec<FixIt>,
}

pub struct DiagnosticFactory {
    pub name: &'static str,             // "UNRESOLVED_REFERENCE"
    pub default_severity: Severity,
    pub message_template: &'static str, // "Unresolved reference: {0}"
}

pub struct FixIt {
    pub title: String,                  // "Import kotlin.collections.listOf"
    pub edits: Vec<TextEdit>,           // span replacements
    pub kind: FixItKind,                // QuickFix, Refactor, …
}
```

`Severity` aligns with `kotlinc`'s `CompilerMessageSeverity`: `Error`, `Warning`, `StrongWarning`, `Info`, `Hint`.

Our existing codes (`E0001`–`E0061`, `R0001`–`R0004`) become legacy aliases attached to the factory; once each one is mapped to a canonical Kotlin factory name, the alias is for backward compat only.

## Renderers

`klio-diagnostics` ships these out of the box. They all consume `&[Diagnostic]` + a `SourceMap`:

### `render::plain` — kotlinc-compatible text

```
src/main.kt:10:5: error: unresolved reference: foo
        foo()
        ^^^
src/main.kt:11:9: warning: variable 'x' is never used
        val x = 1
            ^
```

Matches the format `kotlinc` itself emits (`MessageRenderer.PLAIN`) so editors that already parse `kotlinc` output (the IntelliJ external annotator, the Gradle daemon) consume ours without modification.

### `render::json` — compact, for tooling

```json
{"factory":"UNRESOLVED_REFERENCE","severity":"error","file":"src/main.kt","range":{"start":{"line":10,"col":5},"end":{"line":10,"col":8}},"message":"Unresolved reference: foo","fixits":[]}
```

One object per line (NDJSON), so tools can stream.

### `render::sarif` — SARIF 2.1.0

For GitHub Code Scanning, CodeQL-style dashboards, and any static-analysis aggregator. Same model, well-known schema.

### `render::lsp` — `lsp_types::Diagnostic`

Used by `klio-lsp`. Includes ranges, related information, code actions for fix-its.

## The `klio-lsp` crate

A standalone binary, `klio-lsp`, speaking LSP over stdio. Built on [`tower-lsp`](https://docs.rs/tower-lsp) (well-maintained, async, ergonomic).

### Supported requests

Initial scope, in priority order:

| Request                              | Backed by                              | Status   |
| ------------------------------------ | -------------------------------------- | -------- |
| `initialize` / `shutdown`            | tower-lsp boilerplate                  | required |
| `textDocument/didOpen/didChange/…`   | re-lex + re-parse on edit              | required |
| `textDocument/publishDiagnostics`    | full pipeline (lex → parse → resolver) | required |
| `textDocument/hover`                 | `klio-resolver` + `klio-types`           | high     |
| `textDocument/definition`            | `klio-resolver` (decl span of a use)    | high     |
| `textDocument/references`            | reverse-index over resolver `uses`     | high     |
| `textDocument/completion`            | scope + stdlib FQN catalog             | high     |
| `textDocument/documentSymbol`        | AST outline                            | medium   |
| `textDocument/semanticTokens`        | token stream                           | medium   |
| `textDocument/codeAction`            | fix-its from diagnostics               | medium   |
| `textDocument/signatureHelp`         | callee signature from resolver         | later    |
| `textDocument/rename`                | references + edits                     | later    |
| `textDocument/formatting`            | `klio-fmt` (future crate)               | later    |

### Architecture

```
editor  <-- LSP/stdio -->  klio-lsp  -->  klio-lexer / klio-parser / klio-resolver / klio-types / klio-stdlib
```

`klio-lsp` owns a per-document state (source text + cached lex/parse/resolve output) and re-runs the pipeline on each `didChange`. Re-parses are fast enough at our scale that incremental parsing is a follow-up optimization, not a launch requirement.

The diagnostic model goes through `klio-diagnostics::render::lsp` directly into `publishDiagnostics`. Completion items come from a `CompletionProvider` trait that the resolver and the stdlib registry both implement.

### Performance budget

Editor responsiveness target: **< 50 ms** from keystroke to refreshed diagnostics for files under 10k lines. This is loose enough that the naive "lex + parse + resolve on every change" approach lands well inside it for now. We measure and optimize when we have evidence we need to.

## CLI surface

`klio check <files…> [--diag-format=plain|json|sarif|lsp]` produces diagnostics in the chosen format and exits non-zero if any error-severity entry is emitted. Default format mirrors `kotlinc`.

## Where the upstream IDs live

`kotlin/compiler/fir/checkers/src/.../FirErrors.kt`, plus related files under `kotlin/compiler/frontend.common/`, `kotlin/compiler/diagnostics/`, and `kotlin/compiler/frontend/`. The same generator pattern `klio-stdlib-gen` uses (mine → emit Rust) applies: `klio-diagnostics-gen` reads the upstream factory list and emits `DiagnosticFactory` constants we can reference from checkers.

## Codes added during phases B–E (M29-spec)

Legacy `T00*` codes attached to typeck factories for the M29-spec rollout. The factory `name` (kotlinc-canonical) takes precedence in tool output; the legacy code keeps existing emit sites stable.

| Code   | Rule                                                                                          | Factory (when mapped)              |
| ------ | --------------------------------------------------------------------------------------------- | ---------------------------------- |
| T0027  | `T & Any` definitely-non-nullable type used where `T` is not a type parameter.                | DEFINITELY_NON_NULLABLE_AS_REIFIED |
| T0028  | `expr as List<String>` / generic cast with non-star arguments. Warning.                       | UNCHECKED_CAST                     |
| T0029  | `a foo b` where `foo` resolves to a function declared without `infix`.                        | INFIX_MODIFIER_REQUIRED            |
| T0030  | `return@l` / `break@l` / `continue@l` where `l` is not lexically bound.                       | UNRESOLVED_LABEL                   |
| T0031  | Member or constructor access forbidden by visibility (`private` / `protected` rules).         | INVISIBLE_REFERENCE                |
| T0032  | Reference to a `private` top-level declaration from outside its file.                         | INVISIBLE_REFERENCE                |

`internal` behaves as `public` until module boundaries are modeled (deferred to a future modules milestone).

## Codes added during Phase F (M30-spec)

| Code   | Rule                                                                                          | Factory (when mapped)              |
| ------ | --------------------------------------------------------------------------------------------- | ---------------------------------- |
| T0033  | `const val` declared outside top-level / `object` scope, or `const var`.                      | CONST_VAL_NOT_TOPLEVEL             |
| T0034  | `const val` whose initializer is missing, non-constant, has a delegate / custom accessor, or whose declared type is not a permitted compile-time-constant type. | CONST_VAL_WITH_NON_CONST_INITIALIZER |
| T0035  | `value class` declaration whose shape violates the Kotlin rules (e.g. `open` / `abstract` / `data`, init blocks, secondary body, wrong primary-ctor shape, non-interface supertype, `equals` / `hashCode` override). | VALUE_CLASS_NOT_FINAL              |
| T0036  | `annotation class` declaration whose shape violates the Kotlin rules (body declarations, secondary ctors, init blocks, illegal modifiers, declared supertype). | ANNOTATION_CLASS_MEMBER_REQUIRES_PARAMETER |
| T0037  | `annotation class` primary-ctor parameter whose type is not one of: primitive, `String`, `KClass`, enum, another annotation, or `Array` of those. | INVALID_TYPE_OF_ANNOTATION_MEMBER  |
| T0038  | `typealias` references itself directly or transitively through another alias.                | RECURSIVE_TYPEALIAS                |
| T0039  | `typealias` declared inside a class body, function body, or other non-top-level scope.       | TYPEALIAS_SHOULD_EXPAND_TO_CLASS   |
| T0040  | Extension property declared with an initializer (`val T.foo = ...`). Extension properties have no backing field. | EXTENSION_PROPERTY_HAS_INITIALIZER |
| T0041  | Extension property declared with a `by` delegate. Delegated extension properties are not allowed. | EXTENSION_PROPERTY_HAS_DELEGATE    |
| T0042  | Extension property without a custom getter (and a setter when `var`). A backing field is not allowed; accessors are required. | EXTENSION_PROPERTY_NEEDS_ACCESSOR |
| T0043  | Supertype delegation target is not an interface. `class C : I by d` requires `I` to be an interface. | DELEGATION_NOT_TO_INTERFACE |
| T0044  | Supertype delegation expression's static type is not a subtype of the named interface. | TYPE_MISMATCH_IN_DELEGATION |
| T0045  | `data object` declares `equals` or `hashCode`. The spec auto-generates identity-based versions and forbids user overrides. `toString` overrides remain allowed. | DATA_OBJECT_FORBIDS_EQUALS_HASHCODE |
| T0046  | Bare `field` identifier outside a property accessor body, or inside an accessor for a property with no backing field (extension property). | BACKING_FIELD_OUTSIDE_ACCESSOR |
| T0047  | `*expr` spread argument supplied to a parameter that is not declared `vararg`. | SPREAD_REQUIRES_VARARG |
| T0048  | Warning. A self-recursive call inside a `tailrec` function appears in a non-tail position and will not be optimized into a loop. | NON_TAIL_RECURSIVE_CALL |
| T0049  | Warning. A function is declared `tailrec` but contains no tail-position self-call, so the modifier has no effect. | NO_TAIL_CALLS_FOUND |

## What we are *not* doing

- Reusing any of Kotlin's actual checker code. We compute diagnostics ourselves; we only borrow the **factory IDs and message templates**.
- Implementing the full IntelliJ inspection set. The IntelliJ Kotlin plugin defines many more inspections than the compiler does. We map the compiler ones first; community inspections come later if at all.
- A persistent index / build cache. Each LSP session reanalyzes files on open. A cross-file index is a follow-up once we have classes and multi-file resolution.
