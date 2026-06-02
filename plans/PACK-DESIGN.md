# klio-pack — module format and binding manifest

Status: MVP shipped (M0–M5). Follow-on phases live in
[`PACK-ROADMAP.md`](./PACK-ROADMAP.md).

## Goals

1. One on-disk module format used by stdlib, kotlinx libs, and user libs.
2. Loadable into the interpreter without re-parsing or re-typechecking.
3. Carries enough metadata for autocomplete / go-to-definition tooling to
   read the same artifact the interpreter loads.
4. Native-Rust bindings are declared per-FQN, not per-library, so any pack
   (including third-party) can attach optimised intrinsics.
5. Reproducible: the same source tree always produces a byte-identical pack.

## File layout

A pack is a single file with the magic `KPK\0`, a small fixed header, then
length-prefixed sections. Sections are addressed by name; readers may
skip unknown sections (forward-compat).

```
+---------------------------+
| magic       "KPK\0"       |  4  bytes
| version     u32 LE        |  4  bytes   pack format version (start at 1)
| flags       u32 LE        |  4  bytes   reserved bits
| pack_hash   [u8; 32]      | 32  bytes   blake3 of the rest of the file
+---------------------------+
| section_count   u32 LE    |  4  bytes
| section_table   [Entry]*  | section_count * 24 bytes
|   name_len    u32         |
|   name_off    u32         |  -> offset into the string blob
|   data_off    u64         |  -> offset into the file body
|   data_len    u64         |
+---------------------------+
| string blob                |  utf-8 strings referenced by name_off
+---------------------------+
| section payloads ...      |  postcard-encoded (serde) bytes
+---------------------------+
```

Section payloads are encoded with [`postcard`] (compact, schema-driven,
no_std-friendly). One reusable Serde schema per section, versioned by
`pack.version`.

### Sections

| name           | required | contents                                                                       |
|----------------|----------|--------------------------------------------------------------------------------|
| `manifest`     | yes      | `PackManifest` — id, version, deps, source SHAs, exported package set.         |
| `ast`          | yes      | `Vec<FileAst>` — one entry per source file, AST as today's `klio_ast::File`.   |
| `resolved`     | yes      | `Resolution` snapshot from `klio_resolver` keyed by file id.                   |
| `typeck`       | yes      | `Span -> Type`, `expr_class`, `list_elem`, FnSig table.                        |
| `symbols`      | yes      | Symbol index: FQN -> (file_id, span, kind, sig_summary). Drives imports & LSP. |
| `bindings`     | no       | Binding manifest (see below) — names native-Rust intrinsics by FQN.            |
| `tests`        | no       | Companion test packs (separate compilation unit, same format).                 |
| `debug`        | no       | Source file bytes + line tables for diagnostic spans.                          |

`pack_hash` covers every byte after the hash field, so the pack is
content-addressable: callers can cache parsed packs keyed by `pack_hash`.

## Binding manifest

```rust
pub struct BindingManifest {
    pub library_id: String,   // "stdlib", "kotlinx.coroutines", "myorg.crypto"
    pub abi_version: u32,     // bumped when StdlibFn shape changes
    pub bindings: Vec<Binding>,
}

pub struct Binding {
    pub fqn: String,                 // "kotlin.collections.listOf"
    pub kind: BindingKind,           // Function | Property | ClassCtor | EnumEntry
    pub host_symbol: String,         // "klio_stdlib::collections::list_of"
    pub overrides_interpreter: bool, // true => never fall through to AST body
    pub purity: Purity,              // Pure | Effectful | Suspend
    pub min_arity: u8,
    pub max_arity: u8,
    pub flags: BindingFlags,         // is_inline_only, requires_reified, ...
}
```

Bindings live in the pack but the Rust function pointers do not — they
live in the host. At load time the interpreter walks `bindings`, resolves
`host_symbol` against a registry the host populates, and installs each
function pointer in its FQN → `StdlibFn` table.

A library that ships only Kotlin source omits the `bindings` section
entirely. A library that ships only native impls (rare) still ships an
empty `ast` section so symbol resolution and tooling work uniformly.

### Host registry

```rust
pub struct HostBindings {
    table: HashMap<&'static str, StdlibFn>,
}

impl HostBindings {
    pub fn register(&mut self, host_symbol: &'static str, f: StdlibFn) { ... }
    pub fn resolve(&self, host_symbol: &str) -> Option<StdlibFn> { ... }
}
```

`klio-stdlib` (the Rust crate) becomes a thin façade: it exports a
`HostBindings` builder and the Rust functions themselves. The pack
declares the mapping; the crate provides the implementations. New
libraries do the same — `klio-kotlinx-coroutines` would expose its own
`HostBindings` and a `coroutines.klio-pack` next to it.

## Loader path

```
Interpreter::load_pack(path)
  -> mmap, verify magic + pack_hash
  -> deserialize manifest, check abi_version + deps
  -> deserialize symbols (always, for resolver / imports / LSP)
  -> deserialize ast + resolved + typeck (lazy; on first call into pack)
  -> for each binding in `bindings`:
        host_bindings.resolve(b.host_symbol) ? install : record-missing
```

`Interpreter` already has per-FQN tables (`class_table`, intrinsic
lookups, top-level functions). Loading a pack just populates those
tables from the deserialised sections instead of from a fresh run of
the parser / resolver / typeck.

## Tooling story (LSP / IDE)

The `symbols` section is the entire surface tooling needs:

- Autocomplete: enumerate FQNs in the imported packages.
- Go-to-definition: `symbol.file_id + span` → open file, jump.
- Hover: `sig_summary` carries the rendered Kotlin signature plus, when
  the `debug` section is present, the original KDoc comment block.
- "Open declaration" for a stdlib symbol works the same as for a user
  symbol — they all live in packs.

A separate `klio lsp` binary loads packs read-only and answers requests.
No fork in representation.

## Compression

Each section payload may be stored uncompressed or zstd-compressed; the
choice is per-section and recorded in the directory entry. The header
and directory are never compressed — readers can enumerate sections
without paying for decompression up front.

zstd was chosen for the dictionary-free path: level-3 encoding is fast
to produce, decompression is near memcpy speed, and the library is
broadly available. The default builder helper (`PackWriter::add_zstd`)
uses level 3; callers that want a different tradeoff can drive
`add_section(name, bytes, Compression::Zstd)` and the writer will pick
that level up later when configurable.

Expected payoff:

- `manifest` / `bindings` — small (< 64 KiB) and already compact;
  leave uncompressed.
- `symbols` — large and very repetitive (FQN prefixes, signature
  fragments); zstd typically halves it.
- `ast` / `resolved` / `typeck` — postcard already encodes compactly,
  but zstd still wins another 30–50 % on Kotlin source.
- `debug` — original source bytes; zstd is essential.

Per-section compression also keeps unknown sections cheap to skip — a
reader walks the directory without ever touching their bytes.

## Bundling the stdlib pack into the interpreter

Building the stdlib pack at build time and embedding it in the binary
keeps the runtime story self-contained — no separate file to ship, no
load-path search, and dev edits stay in-tree.

```
crates/klio-stdlib-pack/
  Cargo.toml         # depends on klio-pack + klio-stdlib (build-time)
  build.rs           # invokes the pack builder, writes to OUT_DIR
  src/lib.rs         # exposes `pub const STDLIB_PACK: &[u8] = include_bytes!(...)`
```

The build script runs once per Cargo build: it walks
`klio_stdlib::implementations` + the curated `STDLIB_SYMBOLS` entries,
constructs a `PackWriter`, and writes
`$OUT_DIR/stdlib.klio-pack`. The crate root re-exports the embedded
bytes:

```rust
// crates/klio-stdlib-pack/src/lib.rs
pub const STDLIB_PACK: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/stdlib.klio-pack"));
```

The interpreter takes the embedded slice directly:

```rust
let pack = PackReader::from_bytes(klio_stdlib_pack::STDLIB_PACK.to_vec())?;
interp.install_pack(&pack, &host_bindings)?;
```

For local development, an environment override
`KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` swaps the embedded bytes
for an on-disk file, so iterating on stdlib changes does not require
rebuilding the binary.

Trade-offs:

- Binary size grows by the compressed pack — for the MVP (bindings
  manifest + symbol index only, no AST) we expect on the order of
  100–300 KB. Adding the interpreted stdlib sources later will push
  that into the low megabytes, still acceptable for a developer tool.
- A pack rebuild on every Cargo build triggers if the build script's
  inputs change. The script declares `rerun-if-changed=` lines for
  `klio-stdlib`'s source so unrelated edits don't pay the cost.
- `cargo build --release` benefits from `lto = "thin"` already; the
  embedded `&[u8]` lives in `.rodata` and incurs no init-time cost.

## Reproducibility

`klio pack` emits packs deterministically:

- Source files sorted by relative path.
- `HashMap` substitutes a `BTreeMap` for any section that serialises a map.
- No timestamps embedded.
- `pack_hash` over the byte stream guarantees byte-identity for identical
  sources + identical compiler version (`pack.version` + `abi_version`).

CI gate: re-pack every shipped library and diff against the committed
pack. Drift fails the build.

---

# Stdlib MVP — cover what's currently baked in

Scope: produce `stdlib.klio-pack` that, when loaded, lets the
interpreter run the existing test corpus unchanged, with no Kotlin
source files in the stdlib pack — only bindings to the existing Rust
intrinsics. New stdlib coverage (interpreted Kotlin sources for the
long tail) is explicitly out of scope for the MVP.

## Current state recap

- `klio-stdlib::implementations` — ~5.5k lines of hand-written Rust
  intrinsics keyed by FQN, exposed through `klio_stdlib::implementation(fqn)`.
- `klio-stdlib::generated::STDLIB_SYMBOLS` — 57k lines of declarative
  `SymbolEntry` records (FQN, signature, kind, source loc) produced by
  `klio-stdlib-gen` from upstream Kotlin sources. Most rows have
  `impl_fn: None`. ~750 have `impl_fn: Some(...)`.
- Interpreter consumes both: `klio_stdlib::implementation(fqn)` for
  dispatch, and `STDLIB_SYMBOLS` for import / resolver visibility.

## MVP milestones

### M0 — crate skeleton (**done**)

- New crate `klio-pack`:
  - `format` — magic, version, hash offsets, `SectionDirectory` /
    `SectionEntry` (with per-section `Compression`).
  - `read::PackReader` — validates magic + format version + blake3
    pack hash, decodes the directory eagerly, decompresses section
    payloads on demand (`Cow<[u8]>`).
  - `write::PackWriter` — builder that sorts sections by name,
    optionally zstd-compresses each, and emits a deterministic byte
    stream.
- Six tests in `klio-pack`: empty round-trip, multi-section round-trip,
  deterministic byte output across two builds, zstd round-trip with
  size assertion, tamper detection via hash mismatch, duplicate-section
  rejection.

### M1 — manifest + symbols round-trip

- Define `PackManifest`, `SymbolIndex`, `Binding`, `BindingManifest`.
- Add `klio pack stdlib --bindings-only` subcommand to the existing CLI:
  walks `klio_stdlib::implementations` plus the curated entries from
  `STDLIB_SYMBOLS` that already have `impl_fn = Some`, emits
  `target/packs/stdlib.klio-pack` with `manifest`, `symbols`, and
  `bindings` sections only. No `ast` / `resolved` / `typeck` yet.
- Reproducibility test: build twice, diff bytes.

### M2 — interpreter loads bindings from pack

- New `klio_interp::Interpreter::with_pack(&Pack)` constructor (or
  builder method) that:
  - Reads `bindings`, looks up host symbols via a `HostBindings`
    registry populated by `klio_stdlib` (added in this milestone).
  - Installs each FQN → `StdlibFn` into the same internal table that
    `implementation()` currently feeds.
  - Reads `symbols` and uses it for `is_known_package` /
    `all_symbol_names` (replacing the static `STDLIB_SYMBOLS` reads).
- Old direct calls to `klio_stdlib::implementation` / `all_symbol_names`
  get a feature-flagged shim: behind `--legacy-stdlib`, original path;
  default, pack-driven path. Once everything's green, delete the legacy
  path and the static `STDLIB_SYMBOLS` consts.

### M3 — bindings completeness check

- New `klio pack verify` mode: load the stdlib pack, instantiate the
  interpreter, run the workspace test corpus. The change at this point
  is purely architectural — no test should change output.
- CI gate: `cargo test --workspace` plus `klio pack verify stdlib`.

### M4 — `klio-stdlib-gen` retargets to pack output (**partial**)

Done:

- New `klio-stdlib-pack` crate with `build.rs` that calls
  `klio_stdlib::build_stdlib_pack(true)` once per Cargo build and
  writes `stdlib.klio-pack` into `OUT_DIR`.
- `klio_stdlib_pack::STDLIB_PACK: &[u8]` re-exports the bytes via
  `include_bytes!`. `stdlib_pack_bytes()` honors a `KLIO_STDLIB_PACK`
  env override for dev-time iteration without rebuilding.
- `klio-cli` installs the embedded pack into every `Interpreter`
  produced by `klio run` / `klio run <module-files>`.

Deferred (next milestone after the MVP):

- Replacing the 57k-line `generated/symbols.rs` with a binary
  `generated/symbols.postcard` deserialised at startup. Requires
  re-running `klio-stdlib-gen` against the upstream Kotlin checkout
  to regenerate the file in its new shape; the work is mechanical
  but disruptive to commit without that regeneration. Tracked
  separately so the MVP can land without blocking on a stdlib
  regeneration run.

### M5 — implicit-imports + package-resolution via pack (**done**)

- `PackManifest::implicit_packages` is the canonical declaration; the
  stdlib pack's manifest mirrors the static
  `klio_stdlib::IMPLICITLY_IMPORTED_PACKAGES`, and an
  `embedded_implicit_packages_match_static_list` test enforces parity
  for the transition period.
- `Interpreter::install_pack` reads `implicit_packages` from the
  manifest plus every package referenced by the symbol index and
  calls `klio_stdlib::register_known_package` so any future pack
  (kotlinx.coroutines, user libraries) extends
  `is_known_package` for the resolver automatically.
- The resolver call site (`klio_stdlib::is_known_package`) is
  unchanged but now consults the merged static + runtime registry.

## What's deliberately left out of the MVP

- `ast` / `resolved` / `typeck` sections for stdlib. The MVP ships an
  empty AST in the pack — every existing intrinsic remains Rust-backed.
  Coverage stays exactly where it is today; the change is mechanical
  (lookup goes through pack instead of static table).
- Interpreted Kotlin stdlib coverage for the long tail. Once the pack
  format is in place, future work attaches real `.kt` sources to the
  pack so unbound FQNs fall through to AST execution.
- Third-party library packs. The format and CLI support it from day one,
  but no kotlinx pack ships in the MVP — that's the next milestone after
  stdlib.
- LSP binary. The `symbols` section is shaped to support it, but the
  binary itself is a separate workstream.

## Acceptance criteria

1. `cargo run -p klio-cli -- pack build crates/klio-stdlib` produces a
   deterministic `stdlib.klio-pack`.
2. `cargo run -p klio-cli -- pack verify stdlib.klio-pack` passes.
3. `cargo test --workspace` passes with the interpreter loading
   `stdlib.klio-pack` at startup instead of statically linking
   `STDLIB_SYMBOLS`.
4. `klio-stdlib` crate is < 7k lines (down from ~63k).
5. Pack-build wall time < 2 s on a warm cache.
