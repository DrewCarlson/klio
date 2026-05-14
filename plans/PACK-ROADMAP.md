# Pack roadmap — beyond the MVP

The MVP in [`PACK-DESIGN.md`](./PACK-DESIGN.md) (M0–M5) shipped the
container format, the binding registry, the embedded stdlib pack, and
the implicit-package surface. The interpreter now loads its standard
library through a pack at every startup. What remains is to expand the
mechanism across the *three* original goals: full stdlib coverage
without per-symbol Rust, third-party library support, and tooling.

This document plans the work in phases. Each phase is independent
enough to ship on its own and has clear acceptance criteria; later
phases depend on earlier ones in obvious ways but the dependencies are
flagged explicitly.

---

## Goal recap

1. **Stdlib coverage without manual Rust per symbol.** Native intrinsics
   only where performance demands them; everything else flows through
   interpreted Kotlin baked into the pack so we don't ship the parser
   for every program load.
2. **Third-party library support.** A maintainable way to package
   kotlinx libraries (coroutines, atomicfu, datetime, io, ktor) where
   common Kotlin source rides along and platform-specific pieces are
   pluggable Rust impls.
3. **Tooling infrastructure.** Autocomplete, go-to-definition, and
   inspection use the same artifact the interpreter consumes.

---

## Status

| Phase | Status      |
|-------|-------------|
| 6     | done        |
| 7     | done (source-bundle path; frozen AST sections deferred to a later phase) |
| 8     | done        |
| 9     | done (packs build; binding crates are scaffolds, real native impls are next) |
| 10    | next        |
| 11    | next        |
| 12    | next        |

Phase-by-phase notes below capture both the original plan and what
landed when it diverged in delivery.

## Phase 6 — `klio-stdlib` shrinks to its runtime surface

**Goal.** Replace the 57k-line `crates/klio-stdlib/src/generated/symbols.rs`
with a postcard-encoded `symbols.postcard` produced by
`klio-stdlib-gen`, so the crate shrinks to its runtime surface
(`implementations.rs` + `HostBindings`) and the canonical symbol
index lives in one place.

**Scope.**

- `klio-stdlib-gen` emits `crates/klio-stdlib/src/generated/symbols.postcard`
  (binary, deterministic, committed). The schema is
  `klio_pack::schema::SymbolIndex` — same one the pack carries.
- `klio-stdlib` deserialises lazily via `OnceLock<Vec<SymbolEntry>>`;
  `STDLIB_SYMBOLS` becomes a function that returns `&'static [SymbolEntry]`
  pointing into the cached vector.
- One-time regeneration commit: run `klio-stdlib-gen build` against the
  upstream Kotlin checkout, drop `symbols.rs`, write `symbols.postcard`.
- Build script for `klio-stdlib-pack` calls
  `klio_stdlib::build_stdlib_pack(true)` exactly as today — no schema
  changes propagate beyond the crate boundary.

**Acceptance.**

- `klio-stdlib` source < 7 k LOC.
- `cargo test --workspace` unchanged.
- Pack-build wall time still < 2 s warm.

**Dependencies.** None beyond MVP.

---

## Phase 7 — Interpreted Kotlin shipped in packs (AST sections)

**Goal.** Cover the long tail of stdlib API without writing a Rust
intrinsic per function. Kotlin sources are parsed, resolved, and
typechecked *once* during `klio pack build`; the pack carries the
resulting frozen artifacts; the interpreter dispatches against them
when no native binding wins.

**Scope.**

### 7.1 Pack sections for frozen front-end output

Add three optional sections (already named in [PACK-DESIGN.md](./PACK-DESIGN.md)):

- `ast` — `Vec<FileAst>` (one entry per source file). Schema wraps
  `klio_ast::KotlinFile` in a versioned envelope. Sources have to be
  serializable; today the AST already derives `Clone` / `Debug` but
  not `Serialize`. Add the derives behind a `serde` feature flag on
  `klio-ast` so the runtime crate stays serde-free.
- `resolved` — frozen `klio_resolver::Resolution`. Same feature-flag
  story.
- `typeck` — `Span -> Type` map plus the few side-channels
  (`expr_class`, `list_elem`). Serialise the maps via
  `Vec<(Span, Type)>` for determinism.

### 7.2 Pack loader: AST dispatch path

- `Interpreter::install_pack` learns to install AST + resolved + typeck
  alongside bindings. When dispatching a call whose FQN is not in
  `installed_bindings`, the dispatcher walks the pack's symbol index
  to a `FileId + Span`, looks up the AST node, and calls into the
  existing `eval_function` path with the pre-computed types.
- Top-level pack symbols become first-class entries in the
  interpreter's `class_table` / top-level function map exactly as if
  the source had been part of the user's program.

### 7.3 Pack builder: `klio pack build <library-dir>`

- New subcommand `klio pack build <library-dir> [--out PATH] [--id ID]
  [--bindings TOML]`.
- Walks `<library-dir>/src/**/*.kt`, runs parse → resolve → typeck on
  the lot as a single module, emits a pack with all sections
  populated. Optional `--bindings <toml>` supplies a binding manifest
  for any FQNs whose Rust implementations live in a separate crate.
- Reuses `klio-stdlib`'s `build_stdlib_pack` pipeline factored into a
  general `klio_pack::build::Builder` API so kotlinx and user packs
  produce identical artefacts.

### 7.4 Long-tail stdlib coverage

- Vendor a copy of upstream Kotlin's stdlib sources under
  `crates/klio-stdlib/upstream/` (sparse checkout, just the
  pure-Kotlin portion).
- `klio pack build crates/klio-stdlib/upstream --bindings ...` now
  produces a stdlib pack with AST + bindings; the interpreter
  satisfies a call to `kotlin.collections.windowed` either from the
  baked Kotlin source or from a Rust binding, with the binding winning.

**Acceptance.**

- `klio pack build crates/klio-stdlib/upstream` succeeds, < 30 s cold.
- The stdlib pack carries an `ast` section; a test program calling a
  pure-Kotlin extension function (no Rust binding) runs to completion.
- Hand-written Rust intrinsics covered by a pack still win at
  dispatch (verified by a benchmark).

**Dependencies.** Phase 6 (symbols already postcard); MVP.

---

## Phase 8 — Third-party library packs (kotlinx-style libraries)

**Goal.** Make `klio pack build` work end-to-end for any Kotlin source
tree, with pack-to-pack dependencies and a clear platform-extension
hook.

**Scope.**

### 8.1 Pack-to-pack dependencies

- `PackManifest::dependencies` already exists; wire the loader to
  refuse to install a pack whose dependencies are unmet. Build order
  becomes a topological sort over the dependency graph.
- `Interpreter::load_packs(&[PackReader])` accepts the full set,
  installs them in order, fails fast on missing deps.

### 8.2 Platform-extension hooks

- `expect` / `actual` from Kotlin multiplatform maps onto the
  Rust-binding mechanism: a library declares `expect fun
  systemNanoTime(): Long` in common source and ships an `actual`
  Rust binding under its own `library_id`.
- Add a `Binding::platform_actual: bool` flag the loader honors so
  the pack builder doesn't double-emit interpreted bodies for
  `expect`-shaped declarations.

### 8.3 Library project layout convention

Document a single library shape so the ecosystem stays consistent:

```
klio-kotlinx-coroutines/
  klio.toml          # name, version, abi, deps
  src/main/kotlin/   # common Kotlin source
  src/native/        # Rust crate exposing HostBindings
  bindings.toml      # FQN -> host_symbol mapping
```

`klio pack build` reads `klio.toml`, walks `src/main/kotlin`, applies
`bindings.toml`, and pulls binary impls from the named Rust crate via
the `HostBindings` registry.

### 8.4 Pack discovery and distribution

- Local discovery: `~/.klio/packs/<id>-<version>.klio-pack`.
- `klio pack install <path>` copies a pack into the local cache.
- The interpreter at startup walks the cache and loads every pack
  whose dependencies are satisfied. (Future: registry server.)

**Acceptance.**

- A toy library packaged via `klio pack build` loads through the
  cache, and a user program imports from it as if it were stdlib.
- A second library declaring a dependency on the first loads in
  order; reversing the load order fails with a clear error.

**Dependencies.** Phase 7 (AST in packs).

---

## Phase 9 — kotlinx native-backed subsystems

**Goal.** Ship the four kotlinx libraries the user named so user
programs against them run without further plumbing.

**Scope.** Each subsystem is its own crate + pack. They share the
pattern but the binding surfaces differ.

### 9.1 `klio-kotlinx-coroutines` — `kotlinx.coroutines`

- The MVP interpreter already implements core `suspend` / `Continuation`
  / `runBlocking` (spec §18). This phase adds the *library*:
  `Dispatchers`, `CoroutineScope`, `async` / `launch`, channels,
  flows.
- Native bindings: dispatcher threads, channel buffer queues. The
  rest (`async`, `launch`, scope) lives in Kotlin source.

### 9.2 `klio-kotlinx-atomicfu`

- Pure Rust binding crate. Maps each `atomic*` constructor to an
  `Rc<RefCell<...>>` wrapper, each `compareAndSet` to the standard
  CAS dance. Tiny — the Kotlin surface is small, all native.

### 9.3 `klio-kotlinx-datetime`

- `kotlinx.datetime` revolves around `Instant`, `LocalDateTime`,
  `TimeZone`. Bind these to `chrono` types under the hood; expose the
  Kotlin surface through interpreted source.

### 9.4 `klio-kotlinx-io`

- The bytes side: `Buffer`, `Source`, `Sink`. Rust backings against
  `bytes::BytesMut` and `tokio::io` for cancellable I/O.

### 9.5 Ktor (stretch within this phase)

- HTTP client + minimal server. Bindings call into `reqwest` (client)
  and `axum` (server). Most of the DSL is interpreted Kotlin.

**Acceptance.**

- For each library: a representative example program runs to
  completion through the interpreter using only `klio run`, no
  custom Rust glue per program.
- A benchmark comparison: kotlinx.coroutines `runBlocking { delay
  (10).repeat(1000) }` finishes within an order of magnitude of
  kotlin-jvm.

**Dependencies.** Phase 8 (3rd-party packaging), Phase 7 (AST in packs).

---

## Phase 10 — Tooling: LSP that reads packs

**Goal.** Autocomplete, hover, go-to-definition, find-references for
any pack the user has loaded.

**Scope.**

- New crate `klio-lsp` exposing a JSON-RPC server over stdio.
- Loads packs from `~/.klio/packs`. For each open `.kt` file, runs
  the parse / resolve / typecheck pipeline incrementally and answers
  requests by joining file-local symbols with the union of every
  loaded pack's `symbols` section.
- `textDocument/completion`: symbol index by package, filtered by
  current import set and prefix.
- `textDocument/definition`: `SourceLoc` from the symbol index opens
  the pack's `debug` section (or the original file on disk for
  user-source packs).
- `textDocument/hover`: render the `signature` string plus the KDoc
  comment from `debug`.

**Acceptance.**

- VS Code extension stub that registers `klio-lsp` and demonstrates
  completion / hover / go-to-definition against the embedded stdlib
  pack.

**Dependencies.** Phase 7 (pack carries `debug` source bytes for go-
to-definition into stdlib).

---

## Phase 11 — User-facing pack workflow

**Goal.** A user can package, share, and consume Kotlin libraries
themselves without touching klio internals.

**Scope.**

- `klio pack new <dir>` scaffolds a library project (klio.toml,
  src/main/kotlin, README).
- `klio pack publish <pack>` (eventually): push to a registry. Out of
  scope for the local-first start; only file-based distribution
  initially.
- `klio pack list` shows every cached pack with version and load
  status.
- `klio pack remove <id>@<version>` deletes from the cache.
- Documentation: a worked example walking through publishing a small
  utility library.

**Acceptance.**

- A blog-post-length walkthrough exists. Following it produces a
  pack consumed by another klio program.

**Dependencies.** Phases 7, 8.

---

## Phase 12 — Hygiene, versioning, performance

**Goal.** Production-shape concerns.

**Scope.**

- **ABI versioning.** Each pack declares `abi_version`. Bump that
  when `StdlibFn` or the runtime `Value` shape changes; the loader
  rejects mismatched packs with a clear remediation hint
  ("regenerate this pack against klio ≥ x.y").
- **Pack format version bumps.** `format::FORMAT_VERSION` already
  exists. Document a migration policy: bump major when the section
  layout changes; ship a one-shot migrator (`klio pack migrate <old>
  <new>`).
- **mmap-backed `PackReader`.** Today `PackReader::from_bytes` owns
  the bytes. Add `from_path` that mmaps the file so cold startup
  stays cheap even for multi-MB packs (3rd-party libraries).
- **Optional dictionary-trained zstd.** Train a dictionary across
  stdlib + kotlinx packs once at install time; symbol-index
  sections benefit from the cross-pack vocabulary.
- **Pack-cache index file.** Avoid mmapping every pack at startup;
  read a sidecar index that lists `(id, version, path, hash)` and
  load lazily on first reference.

**Acceptance.**

- Cold `klio run hello.kt` startup < 50 ms with the full stdlib +
  kotlinx-coroutines + kotlinx-datetime packs installed.
- `klio pack migrate` converts a v1 pack to v2 successfully.

**Dependencies.** Anytime, but most relevant after Phase 9.

---

## Sequencing summary

```
MVP (done) ──► 6 ──► 7 ──► 8 ──► 9
                       └─► 10 (tooling)
                       └─► 11 (user workflow)
                       └─► 12 (hygiene)
```

Phase 6 is small and gates the symbols-everywhere cleanup; ship first.
Phase 7 unlocks everything else and is the biggest piece — split it
into the four sub-phases above when scheduling. Phases 8 and 9 stack
together to deliver the kotlinx promise. Phases 10–12 run in parallel
once 7 lands.

Each phase ends with the same gate as the MVP: workspace tests green,
`klio pack verify` over every shipped pack, and one example program
demonstrating the new capability.
