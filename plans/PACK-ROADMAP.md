# Pack roadmap — beyond the MVP

The container-format MVP shipped the container format, the binding registry, the embedded stdlib pack, and the implicit-package surface. The interpreter loads its standard library through a pack at every startup. Two of the three original goals are met (stdlib coverage without per-symbol Rust; third-party library support); the third — tooling that consumes the same artifact — is the main open work below.

## Completed

- **Phase 6** — the stdlib runtime crate shrank to its runtime surface: a postcard-encoded symbol index plus the runtime `implementations` + `HostBindings`, with the canonical symbol index living in one place.
- **Phase 7** — interpreted Kotlin shipped in packs (AST-in-packs sections) and the embedded stdlib image. Kotlin sources are parsed/resolved/typechecked once at pack build; the interpreter dispatches against the baked front-end output when no native binding wins (native bindings still win at dispatch).
- **Phase 8** — third-party packs with pack-to-pack dependencies (`src/pack/schema.zig`) and the `~/.klio/packs` cache. Load order is a topological sort over the dependency graph; unmet deps fail fast with a clear error.
- **Phase 9** — kotlinx native-backed packs (coroutines, atomicfu, datetime, io, ktor) build and run: a representative program for each runs to completion through `klio run` with no per-program Rust glue.
- **Phase 11** — pack workflow CLI: `src/cli/cli.zig` exposes `build | stdlib | install | list | remove | inspect | verify | new | migrate | publish | search | fetch`.
- **Phase 12 (partial)** — ABI/format versioning and `klio pack migrate` (format-version bump) landed. The mmap-backed reader residual is below.

---

## Phase 10 — Tooling: LSP that reads packs

**Goal.** Autocomplete, hover, go-to-definition, find-references for any pack the user has loaded. Not started — there is no `src/lsp`, and no `klio-lsp` / `textDocument` / jsonrpc surface in the tree.

**Scope.**

- New `klio-lsp` binary exposing a JSON-RPC server over stdio.
- Loads packs from `~/.klio/packs`. For each open `.kt` file, runs the parse / resolve / typecheck pipeline incrementally and answers requests by joining file-local symbols with the union of every loaded pack's `symbols` section.
- `textDocument/completion`: symbol index by package, filtered by current import set and prefix.
- `textDocument/definition`: `SourceLoc` from the symbol index opens the pack's `debug` section (or the original file on disk for user-source packs).
- `textDocument/hover`: render the `signature` string plus the KDoc comment from `debug`.

**Acceptance.** VS Code extension stub that registers `klio-lsp` and demonstrates completion / hover / go-to-definition against the embedded stdlib pack.

**Dependencies.** Phase 7 (pack carries `debug` source bytes for go-to-definition into stdlib) — landed.

---

## Phase 12 residual — mmap-backed pack reader

A true mmap-backed pack reader is not done. `src/pack/read.zig` decodes the header and section directory eagerly and notes "the mmap-backed constructor for large packs is reserved for a later stage" (`read.zig:6`); `fromPath` (`read.zig:57`) reads the whole file into an owned allocation. Add a path that mmaps the file so cold startup stays cheap even for multi-MB packs (third-party libraries), rather than reading the bytes into an owned buffer.

Related, still-open hygiene under the same phase:

- **Optional dictionary-trained zstd.** Train a dictionary across stdlib + kotlinx packs once at install time; symbol-index sections benefit from the cross-pack vocabulary.
- **Pack-cache index file.** Read a sidecar index that lists `(id, version, path, hash)` and load lazily on first reference, instead of mapping every pack at startup.

**Acceptance.** Cold `klio run hello.kt` startup < 50 ms with the full stdlib + kotlinx-coroutines + kotlinx-datetime packs installed.
