//! Build a `.klio-pack` byte stream describing this crate's stdlib
//! surface. Used by `klio pack stdlib` and by the `klio-stdlib-pack`
//! build script to embed a pack inside the interpreter binary.
//!
//! The MVP form emits `manifest`, `symbols`, and `bindings` sections
//! only; the AST / resolved / typeck sections are reserved for the
//! interpreted-stdlib path that follows after the MVP.

use klio_pack::schema::{
    encode, Binding, BindingKind, BindingManifest, ModifierBits, PackManifest, Purity, SourceLoc,
    SymbolIndex, SymbolKind, SymbolRecord,
};
use klio_pack::{section_names, Compression, PackError, PackWriter};

use crate::{generated, implementation, param_names, IMPLICITLY_IMPORTED_PACKAGES};

/// Build a deterministic pack for the in-process Kotlin standard
/// library. When `compress_symbols` is true the symbol index section
/// is zstd-compressed (default for the embedded build).
pub fn build_stdlib_pack(compress_symbols: bool) -> Result<Vec<u8>, PackError> {
    let manifest = PackManifest {
        library_id: "stdlib".into(),
        library_version: env!("CARGO_PKG_VERSION").into(),
        abi_version: 1,
        implicit_packages: IMPLICITLY_IMPORTED_PACKAGES
            .iter()
            .map(|s| (*s).to_string())
            .collect(),
        dependencies: vec![],
    };
    let manifest_bytes = encode(&manifest)?;

    let mut sym_entries: Vec<SymbolRecord> = generated::STDLIB_SYMBOLS
        .iter()
        .map(symbol_entry_to_record)
        .collect();
    sym_entries.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let symbol_bytes = encode(&SymbolIndex { entries: sym_entries })?;

    let mut bindings: Vec<Binding> = Vec::new();
    let mut seen = std::collections::BTreeSet::<String>::new();
    for fqn in crate::all_symbol_names() {
        if implementation(fqn).is_none() {
            continue;
        }
        if !seen.insert(fqn.to_string()) {
            continue;
        }
        let arity = param_names(fqn).map(<[&str]>::len).unwrap_or(0);
        let max_arity: u8 = u8::try_from(arity).unwrap_or(u8::MAX);
        bindings.push(Binding {
            fqn: fqn.to_string(),
            kind: BindingKind::Function,
            host_symbol: fqn.to_string(),
            overrides_interpreter: true,
            purity: Purity::Effectful,
            min_arity: max_arity,
            max_arity,
        });
    }
    bindings.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let binding_bytes = encode(&BindingManifest { bindings })?;

    let mut writer = PackWriter::new();
    writer.add_raw(section_names::MANIFEST, manifest_bytes);
    writer.add_section(
        section_names::SYMBOLS,
        symbol_bytes,
        if compress_symbols { Compression::Zstd } else { Compression::None },
    );
    writer.add_raw(section_names::BINDINGS, binding_bytes);
    writer.finish()
}

fn symbol_entry_to_record(e: &crate::SymbolEntry) -> SymbolRecord {
    let kind = match e.kind {
        crate::SymbolKind::Function => SymbolKind::Function,
        crate::SymbolKind::Property => SymbolKind::Property,
        crate::SymbolKind::Class => SymbolKind::Class,
        crate::SymbolKind::Interface => SymbolKind::Interface,
        crate::SymbolKind::Object => SymbolKind::Object,
        crate::SymbolKind::TypeAlias => SymbolKind::TypeAlias,
    };
    let modifiers = ModifierBits::from_bits_truncate(e.modifiers.0);
    SymbolRecord {
        fqn: e.fqn.to_string(),
        package: e.package.to_string(),
        name: e.name.to_string(),
        kind,
        receiver: e.receiver.map(str::to_string),
        signature: e.signature.to_string(),
        param_names: e.param_names.iter().map(|s| (*s).to_string()).collect(),
        modifiers,
        source: Some(SourceLoc {
            path: e.source.path.to_string(),
            line: e.source.line,
            column: e.source.column,
        }),
    }
}
