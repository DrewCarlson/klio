# Pack format

A `.klio-pack` file is a single byte stream with the layout below.
All multi-byte integers are little-endian.

```
+-------------------------+
| magic       "KPK\0"     |  4 bytes
| version     u32         |  4
| flags       u32         |  4   (reserved)
| pack_hash   [u8; 32]    | 32   blake3 over everything that follows
| dir_len     u32         |  4
| dir         [u8; ...]   |       postcard-encoded SectionDirectory
| payloads    [u8; ...]   |       concatenated section bodies
+-------------------------+
```

The `pack_hash` covers every byte after the hash itself, so a pack
is content-addressable: callers can cache parsed packs keyed by
hash. Tampering anywhere in the body fails the hash check on the
next read.

## Section directory

Each `SectionEntry` is

```rust
pub struct SectionEntry {
    pub name: String,
    pub offset: u64,          // into the payload area
    pub stored_len: u64,
    pub uncompressed_len: u64,
    pub compression: Compression, // None | Zstd
}
```

Names are case-sensitive. Readers may encounter unknown names and
must skip them silently — that is how forward-compatible additions
work.

## Well-known sections

| Name        | Required | Contents                                                       |
|-------------|----------|----------------------------------------------------------------|
| `manifest`  | yes      | `PackManifest` (library id/version, abi, deps, implicit pkgs). |
| `symbols`   | yes      | `SymbolIndex` (FQN → kind, signature, source loc).             |
| `bindings`  | no       | `BindingManifest` (FQN → host_symbol, purity, arity).          |
| `ast`       | no       | `AstBundle` — pre-parsed `KotlinFile`s per source file.        |
| `sources`   | no       | `SourceBundle` — raw UTF-8 source bytes.                       |
| `tests`     | no       | Companion test pack(s), same format, embedded.                 |
| `debug`     | no       | Source bytes + line tables for go-to-definition.               |

All section payloads are `postcard`-encoded against the schemas in
`klio_pack::schema` and pinned to `FORMAT_VERSION`. Bump the version
when a schema changes incompatibly.

## Compression

Each section opts into compression independently. Today the choices
are `None` and `Zstd` at default level 3. The header and directory
are never compressed so readers can enumerate sections without
paying for decompression.

Suggested defaults:

| Section     | Compression  |
|-------------|--------------|
| `manifest`  | None         |
| `bindings`  | None         |
| `symbols`   | Zstd (heavy repetition in FQN prefixes) |
| `ast`       | Zstd         |
| `sources`   | Zstd (essential — raw Kotlin text)      |
| `debug`     | Zstd         |

## Determinism

`PackWriter::finish` sorts every section by name and writes
deterministically, so the same input tree always produces a
byte-identical pack. CI can re-pack every shipped library and `diff`
against the committed bytes to catch accidental drift.

## ABI versioning

`PackManifest::abi_version` declares the runtime ABI the pack was
built against. `klio_pack::SUPPORTED_ABI_VERSION` is the highest
ABI this build of klio understands. The interpreter rejects any
pack whose `abi_version` is higher with `PackError::AbiMismatch`,
prompting the author to rebuild against a matching klio release.
