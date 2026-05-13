//! One-shot tool: serialise the in-process `STDLIB_SYMBOLS` table into
//! a postcard byte stream and write it to
//! `crates/klio-stdlib/src/generated/symbols.postcard`.
//!
//! Used during the symbols.rs → symbols.postcard migration and then by
//! `klio-stdlib-gen` going forward. Producing the binary file from the
//! existing checked-in Rust source avoids needing the upstream Kotlin
//! checkout for the one-time migration commit.

use std::path::PathBuf;

use klio_pack::schema::{encode, ModifierBits, SourceLoc, SymbolIndex, SymbolKind, SymbolRecord};
use klio_stdlib::{generated, SymbolEntry};

fn main() {
    let mut entries: Vec<SymbolRecord> =
        generated::stdlib_symbols().iter().map(entry_to_record).collect();
    entries.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let index = SymbolIndex { entries };
    let bytes = encode(&index).expect("encode SymbolIndex");

    let out: PathBuf = match std::env::args().nth(1) {
        Some(p) => PathBuf::from(p),
        None => {
            let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            crate_root.join("src").join("generated").join("symbols.postcard")
        }
    };
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent).expect("create generated dir");
    }
    std::fs::write(&out, &bytes).expect("write symbols.postcard");
    eprintln!("wrote {} ({} bytes)", out.display(), bytes.len());
}

fn entry_to_record(e: &SymbolEntry) -> SymbolRecord {
    let kind = match e.kind {
        klio_stdlib::SymbolKind::Function => SymbolKind::Function,
        klio_stdlib::SymbolKind::Property => SymbolKind::Property,
        klio_stdlib::SymbolKind::Class => SymbolKind::Class,
        klio_stdlib::SymbolKind::Interface => SymbolKind::Interface,
        klio_stdlib::SymbolKind::Object => SymbolKind::Object,
        klio_stdlib::SymbolKind::TypeAlias => SymbolKind::TypeAlias,
    };
    SymbolRecord {
        fqn: e.fqn.to_string(),
        package: e.package.to_string(),
        name: e.name.to_string(),
        kind,
        receiver: e.receiver.map(str::to_string),
        signature: e.signature.to_string(),
        param_names: e.param_names.iter().map(|s| (*s).to_string()).collect(),
        modifiers: ModifierBits::from_bits_truncate(e.modifiers.0),
        source: Some(SourceLoc {
            path: e.source.path.to_string(),
            line: e.source.line,
            column: e.source.column,
        }),
    }
}
