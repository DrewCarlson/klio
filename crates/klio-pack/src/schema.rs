//! High-level pack section schemas.
//!
//! The typed payloads carried inside well-known section names. Every
//! type here is `Serialize + Deserialize`; sections are stored as
//! `postcard::to_allocvec(&value)` bytes inside the
//! [`crate::format::SectionDirectory`] envelope.
//!
//! The Serde representations are stable for a given
//! [`crate::format::FORMAT_VERSION`]. When the schema changes
//! incompatibly, bump that constant.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------
// manifest
// ---------------------------------------------------------------------

/// Top-level pack metadata. Always present, always uncompressed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackManifest {
    /// Library identifier, e.g. `"stdlib"`, `"kotlinx.coroutines"`, or
    /// `"myorg.crypto"`. Used to key the pack inside the host registry.
    pub library_id: String,
    /// Semantic version of the library packaged here.
    pub library_version: String,
    /// Format-level ABI version for native bindings. Bumped when the
    /// `StdlibFn` signature changes; readers reject packs with an ABI
    /// they don't understand.
    pub abi_version: u32,
    /// Packages whose top-level entities are implicitly visible after
    /// this pack is loaded (Kotlin language spec §10.1).
    pub implicit_packages: Vec<String>,
    /// Other packs this pack depends on, by `library_id`. Loader walks
    /// these in topological order.
    pub dependencies: Vec<PackDependency>,
    /// Features active when a consumer requests none (cargo-style
    /// `default = [...]`). Empty means everything not gated by a feature
    /// (the "core") loads and no feature-gated source loads by default.
    pub default_features: Vec<String>,
    /// Named features this pack provides. A source file is gated when its
    /// `rel_path` matches some feature's `sources`; such a file loads only
    /// when that feature is active. Files matched by no feature are core
    /// (always loaded).
    pub features: Vec<FeatureDef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackDependency {
    pub library_id: String,
    /// Optional minimum semantic version. Empty when any version is OK.
    pub min_version: String,
    /// Features of the dependency to activate (cargo-style
    /// `features = [...]`).
    pub features: Vec<String>,
    /// Whether the dependency's `default_features` are also activated.
    pub default_features: bool,
}

/// One named feature: the source-path prefixes it gates, the other packs
/// it pulls in when active, and the sibling features it transitively
/// enables. Mirrors a cargo feature / a kotlinx Gradle member module.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeatureDef {
    pub name: String,
    /// `rel_path` prefix patterns (matched like `[[source]]` includes)
    /// for the source files this feature gates.
    pub sources: Vec<String>,
    /// `library_id`s pulled in only when this feature is active.
    pub deps: Vec<String>,
    /// Sibling features this one transitively activates.
    pub requires: Vec<String>,
}

// ---------------------------------------------------------------------
// symbols
// ---------------------------------------------------------------------

/// Symbol index for the pack. One entry per public declaration.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SymbolIndex {
    pub entries: Vec<SymbolRecord>,
}

/// Kind of a declared symbol. Mirrors the small enum carried in
/// `klio-stdlib::SymbolKind`, but lives here so the schema does not
/// depend on the stdlib crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum SymbolKind {
    Function = 0,
    Property = 1,
    Class = 2,
    Interface = 3,
    Object = 4,
    TypeAlias = 5,
}

bitflags::bitflags! {
    /// Kotlin modifier bits attached to a symbol. The layout matches
    /// the bit positions in `klio-stdlib::Modifiers` so we can
    /// round-trip without a translation table.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
    pub struct ModifierBits: u32 {
        const PUBLIC     = 1 << 0;
        const INTERNAL   = 1 << 1;
        const PROTECTED  = 1 << 2;
        const PRIVATE    = 1 << 3;
        const OPEN       = 1 << 4;
        const ABSTRACT   = 1 << 5;
        const FINAL      = 1 << 6;
        const SEALED     = 1 << 7;
        const INLINE     = 1 << 8;
        const INFIX      = 1 << 9;
        const OPERATOR   = 1 << 10;
        const TAILREC    = 1 << 11;
        const EXPECT     = 1 << 12;
        const ACTUAL     = 1 << 13;
        const EXTERNAL   = 1 << 14;
        const SUSPEND    = 1 << 15;
        const OVERRIDE   = 1 << 16;
        const DATA       = 1 << 17;
        const VALUE      = 1 << 18;
        const ENUM       = 1 << 19;
        const ANNOTATION = 1 << 20;
        const COMPANION  = 1 << 21;
        const CONST      = 1 << 22;
    }
}

/// One declared symbol. Designed to round-trip
/// `klio_stdlib::SymbolEntry` without information loss.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SymbolRecord {
    /// Fully qualified name (`kotlin.collections.listOf`).
    pub fqn: String,
    /// Package path (`kotlin.collections`).
    pub package: String,
    /// Simple name (`listOf`).
    pub name: String,
    pub kind: SymbolKind,
    /// Extension receiver type as text, if any.
    pub receiver: Option<String>,
    /// Raw textual signature (trimmed source line).
    pub signature: String,
    /// Parameter names in declaration order. Empty for non-function
    /// declarations.
    pub param_names: Vec<String>,
    pub modifiers: ModifierBits,
    /// Upstream source location, for go-to-definition / tooling.
    pub source: Option<SourceLoc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceLoc {
    pub path: String,
    pub line: u32,
    pub column: u32,
}

// ---------------------------------------------------------------------
// bindings
// ---------------------------------------------------------------------

/// Map of FQN → native binding for the host to install at load time.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BindingManifest {
    pub bindings: Vec<Binding>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Binding {
    /// Kotlin FQN this binding satisfies (`kotlin.io.println`).
    pub fqn: String,
    pub kind: BindingKind,
    /// Logical host-symbol key the loader uses to resolve the Rust
    /// function pointer via [`HostBindings::resolve`]. Convention is
    /// the FQN — same identifier on both sides — but the schema keeps
    /// them separate so a host may register a single Rust function
    /// under multiple Kotlin names.
    pub host_symbol: String,
    /// True when the binding always wins over an interpreted body for
    /// this FQN; false when the binding is a fast path and the
    /// interpreter may still fall through to a Kotlin implementation
    /// shipped in the `ast` section.
    pub overrides_interpreter: bool,
    pub purity: Purity,
    pub min_arity: u8,
    pub max_arity: u8,
    /// True when this binding is the `actual` half of an `expect /
    /// actual` declaration: the library ships an `expect` declaration
    /// in its common sources, and this binding's Rust function is the
    /// platform-specific implementation. Defaults to false. The
    /// interpreter treats `expect`-shaped declarations as
    /// non-instantiable unless an `actual` binding (here) is
    /// installed.
    #[serde(default)]
    pub platform_actual: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum BindingKind {
    Function = 0,
    Property = 1,
    ClassCtor = 2,
    EnumEntry = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum Purity {
    Pure = 0,
    Effectful = 1,
    Suspend = 2,
}

// ---------------------------------------------------------------------
// sources
// ---------------------------------------------------------------------

/// Kotlin source files shipped inside the pack. The interpreter parses
/// these at install time and registers the resulting declarations as
/// if the user had written them. A future phase replaces this section
/// with frozen `ast` + `resolved` + `typeck` sections produced by the
/// pack builder.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceBundle {
    pub files: Vec<SourceFile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceFile {
    /// Path relative to the library root (e.g.
    /// `common/src/main/kotlin/kotlinx/coroutines/Job.kt`). Used for
    /// diagnostic spans and go-to-definition.
    pub rel_path: String,
    /// UTF-8 source bytes.
    pub bytes: Vec<u8>,
}

// ---------------------------------------------------------------------
// ast
// ---------------------------------------------------------------------

/// Frozen front-end output. When present, the interpreter skips the
/// parse pass at install time and feeds the carried `KotlinFile`
/// directly into `register_pack_classes`. The pack still ships the
/// raw source bytes in `sources` for diagnostic spans and re-parse
/// fallback.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AstBundle {
    pub files: Vec<AstFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AstFile {
    pub rel_path: String,
    pub kotlin_file: klio_ast::KotlinFile,
}

// ---------------------------------------------------------------------
// typeck
// ---------------------------------------------------------------------

/// Frozen type-check output. Keyed by source span so the loader can
/// rebuild the interpreter's `expr_types` map without re-running the
/// type checker. The schema is intentionally narrow: only the
/// per-expression `Type` map is carried; the auxiliary side channels
/// (`expr_class`, `list_elem`) are reserved for future fields.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TypeckBundle {
    /// Pairs of `(Span, Type)` so the on-disk shape is deterministic
    /// (`HashMap` is non-deterministic; a sorted Vec keeps round-trips
    /// byte-identical).
    pub entries: Vec<(klio_span::Span, klio_types::Type)>,
}

// ---------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------

/// Postcard-encode a value into bytes ready for the pack writer. A
/// thin wrapper that pins us to a single serialiser at the boundary.
pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, crate::PackError> {
    postcard::to_allocvec(value).map_err(crate::PackError::Encode)
}

/// Postcard-decode a section payload.
pub fn decode<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T, crate::PackError> {
    postcard::from_bytes(bytes).map_err(crate::PackError::Decode)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{PackReader, PackWriter, section_names};

    #[test]
    fn manifest_round_trip_through_pack() {
        let manifest = PackManifest {
            library_id: "stdlib".into(),
            library_version: "0.1.0".into(),
            abi_version: 1,
            implicit_packages: vec!["kotlin".into(), "kotlin.collections".into()],
            dependencies: vec![],
            default_features: vec![],
            features: vec![],
        };
        let bytes = encode(&manifest).unwrap();
        let mut w = PackWriter::new();
        w.add_raw(section_names::MANIFEST, bytes);
        let pack = w.finish().unwrap();

        let reader = PackReader::from_bytes(pack).unwrap();
        let payload = reader
            .read_section(section_names::MANIFEST)
            .unwrap()
            .unwrap();
        let decoded: PackManifest = decode(&payload).unwrap();
        assert_eq!(decoded, manifest);
    }

    #[test]
    fn symbol_record_round_trip() {
        let index = SymbolIndex {
            entries: vec![SymbolRecord {
                fqn: "kotlin.io.println".into(),
                package: "kotlin.io".into(),
                name: "println".into(),
                kind: SymbolKind::Function,
                receiver: None,
                signature: "public fun println(message: Any?): Unit".into(),
                param_names: vec!["message".into()],
                modifiers: ModifierBits::PUBLIC,
                source: Some(SourceLoc {
                    path: "kotlin/libraries/stdlib/src/kotlin/io/Console.kt".into(),
                    line: 42,
                    column: 1,
                }),
            }],
        };
        let bytes = encode(&index).unwrap();
        let decoded: SymbolIndex = decode(&bytes).unwrap();
        assert_eq!(decoded, index);
    }

    #[test]
    fn binding_manifest_round_trip() {
        let manifest = BindingManifest {
            bindings: vec![Binding {
                fqn: "kotlin.io.println".into(),
                kind: BindingKind::Function,
                host_symbol: "kotlin.io.println".into(),
                overrides_interpreter: true,
                purity: Purity::Effectful,
                min_arity: 0,
                max_arity: 1,
                platform_actual: false,
            }],
        };
        let bytes = encode(&manifest).unwrap();
        let decoded: BindingManifest = decode(&bytes).unwrap();
        assert_eq!(decoded, manifest);
    }
}
