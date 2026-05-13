# What is a Pack?

A *pack* is a single-file binary archive that bundles a Kotlin
library — manifest, parsed AST, symbol index, optional native
binding manifest — into a format the klio interpreter can install
without re-running the parser or typechecker.

```
+---------------------------+
| KPK\0  magic + version    |  header (verified + hashed)
|--------|------------------|
| manifest    PackManifest  |  always present
| symbols     SymbolIndex   |  for imports / tooling
| bindings    BindingManifest |  native intrinsics
| ast         AstBundle     |  frozen front-end output
| sources     SourceBundle  |  raw .kt fallback
| debug       …             |  optional source bytes for IDE
+---------------------------+
```

## Why a pack instead of a zip / jar?

- **Deterministic.** Sections are sorted by name and `blake3`-hashed
  so the same source tree always produces the same bytes.
- **Section-addressable.** Readers walk a small directory and decode
  only the sections they care about. The LSP can load just
  `symbols` and `debug`; the interpreter adds `ast` + `bindings`.
- **Schema-driven.** Each section is `postcard`-encoded against a
  serde schema in `klio_pack::schema`.
- **Compressible.** Sections can be uncompressed or
  zstd-compressed individually.

## Three kinds of packs

| Kind            | Example                | Loaded by                                        |
|-----------------|------------------------|--------------------------------------------------|
| Embedded stdlib | `stdlib.klio-pack`     | Built into the `klio` binary; always active.     |
| Kotlinx libs    | `kotlinx.io.klio-pack` | Bundled in the workspace; `klio pack install`.   |
| Opt-in modules  | `io.ktor.client.klio-pack` | Same flow; not loaded unless the user asks.  |
| Third-party     | Anything you build     | `klio pack install <file>`.                       |

The same format, the same loader, the same dispatch path — only the
content and the install flow differ.

## What goes in a pack

- **Kotlin source.** Everything under the library's `source_roots`
  is parsed at pack-build time. The resulting AST goes into the
  `ast` section. Bytes go into `sources` as a fallback.
- **Binding manifest.** `klio.toml`'s `[bindings]` table is
  serialised into the `bindings` section so the loader can resolve
  each FQN against a host's `HostBindings` registry.
- **Manifest.** Library id, version, ABI version, dependencies, and
  implicit packages.

## What does not go in a pack

- The Rust crate that provides the native bindings — pointers can't
  travel through serde. Hosts register them once at startup; the
  pack only carries the `host_symbol` name to join against.
- Build artefacts (`target/`), test fixtures, CI configs, anything
  outside the declared `source_roots`.

## Loader behaviour

When `klio` starts:

1. The embedded stdlib pack is decoded and installed.
2. Every file matching `~/.klio/packs/*.klio-pack` and
   `$KLIO_PACKS` is enumerated.
3. Packs are topologically sorted by `[[deps]]` and installed in
   order.
4. For each pack:
    - `manifest.abi_version` is checked against
      `klio_pack::SUPPORTED_ABI_VERSION`.
    - `implicit_packages` and packages mentioned in the symbol index
      are registered with the resolver.
    - Bindings whose `host_symbol` resolves in the host registry
      are installed into `Interpreter::installed_bindings`.
    - The pack's frozen AST is fed through `register_pack_sources`
      so top-level declarations become globals.
