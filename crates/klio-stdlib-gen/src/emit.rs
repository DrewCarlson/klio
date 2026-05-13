//! Emit the postcard-encoded symbol index consumed by `klio-stdlib`.

use std::collections::HashSet;
use std::fs;
use std::path::Path;

use klio_pack::schema::{
    encode, ModifierBits, SourceLoc, SymbolIndex, SymbolKind, SymbolRecord,
};

use crate::parse::{Decl, DeclKind};
use crate::walk::FileDecls;

pub fn emit_generated(out_dir: &Path, files: &[FileDecls]) -> std::io::Result<usize> {
    fs::create_dir_all(out_dir)?;

    let mut seen: HashSet<String> = HashSet::new();
    let mut entries: Vec<SymbolRecord> = Vec::new();
    for f in files {
        for d in &f.decls {
            let key = format!("{}|{}|{:?}|{}", d.fqn, d.signature, d.kind, f.rel_path);
            if !seen.insert(key) {
                continue;
            }
            entries.push(decl_to_record(d, &f.rel_path));
        }
    }
    let count = entries.len();
    entries.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let bytes = encode(&SymbolIndex { entries }).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string())
    })?;
    fs::write(out_dir.join("symbols.postcard"), &bytes)?;
    Ok(count)
}

fn decl_to_record(d: &Decl, rel: &str) -> SymbolRecord {
    let kind = match d.kind {
        DeclKind::Function => SymbolKind::Function,
        DeclKind::Property => SymbolKind::Property,
        DeclKind::Class => SymbolKind::Class,
        DeclKind::Interface => SymbolKind::Interface,
        DeclKind::Object => SymbolKind::Object,
        DeclKind::TypeAlias => SymbolKind::TypeAlias,
    };
    let package = d.fqn.rsplit_once('.').map(|(p, _)| p).unwrap_or("").to_string();
    SymbolRecord {
        fqn: d.fqn.clone(),
        package,
        name: d.name.clone(),
        kind,
        receiver: d.receiver.clone(),
        signature: d.signature.clone(),
        param_names: d.param_names.clone(),
        modifiers: ModifierBits::from_bits_truncate(d.modifiers),
        source: Some(SourceLoc {
            path: rel.to_string(),
            line: d.line,
            column: d.column,
        }),
    }
}
