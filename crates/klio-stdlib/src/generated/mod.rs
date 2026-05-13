//! Generated stdlib symbol index.
//!
//! The on-disk form is `symbols.postcard` (binary, produced by
//! `klio-stdlib-gen` or by the in-tree `dump_symbols_postcard`
//! binary). At runtime we deserialise once via [`LazyLock`] and
//! materialise the original `&'static [SymbolEntry]` shape by
//! leaking the decoded strings — they live for the program's
//! lifetime, so the lifetime promise on `SymbolEntry`'s `&'static
//! str` fields is honoured.

#![allow(clippy::all)]
#![allow(clippy::pedantic)]

use std::sync::LazyLock;

use crate::{Modifiers, SourceLoc, SymbolEntry, SymbolKind};

const SYMBOLS_POSTCARD: &[u8] = include_bytes!("symbols.postcard");

static SYMBOLS: LazyLock<Vec<SymbolEntry>> = LazyLock::new(decode_symbols);

/// Static slice of every stdlib symbol mined from upstream Kotlin.
/// First access deserialises the embedded postcard bytes once; every
/// subsequent access reuses the materialised slice.
#[must_use]
pub fn stdlib_symbols() -> &'static [SymbolEntry] {
    SYMBOLS.as_slice()
}

fn decode_symbols() -> Vec<SymbolEntry> {
    let index: klio_pack::schema::SymbolIndex =
        klio_pack::schema::decode(SYMBOLS_POSTCARD).expect("decode stdlib symbols.postcard");
    index.entries.into_iter().map(record_to_entry).collect()
}

fn record_to_entry(r: klio_pack::schema::SymbolRecord) -> SymbolEntry {
    let kind = match r.kind {
        klio_pack::schema::SymbolKind::Function => SymbolKind::Function,
        klio_pack::schema::SymbolKind::Property => SymbolKind::Property,
        klio_pack::schema::SymbolKind::Class => SymbolKind::Class,
        klio_pack::schema::SymbolKind::Interface => SymbolKind::Interface,
        klio_pack::schema::SymbolKind::Object => SymbolKind::Object,
        klio_pack::schema::SymbolKind::TypeAlias => SymbolKind::TypeAlias,
    };
    let fqn = leak_str(r.fqn);
    let package = leak_str(r.package);
    let name = leak_str(r.name);
    let receiver = r.receiver.map(leak_str);
    let signature = leak_str(r.signature);
    let param_names: Vec<&'static str> = r.param_names.into_iter().map(leak_str).collect();
    let param_names: &'static [&'static str] = Box::leak(param_names.into_boxed_slice());
    let source = match r.source {
        Some(s) => SourceLoc {
            path: leak_str(s.path),
            line: s.line,
            column: s.column,
        },
        None => SourceLoc {
            path: "",
            line: 0,
            column: 0,
        },
    };
    SymbolEntry {
        fqn,
        package,
        name,
        kind,
        receiver,
        signature,
        param_names,
        modifiers: Modifiers(r.modifiers.bits()),
        source,
        impl_fn: None,
    }
}

fn leak_str(s: String) -> &'static str {
    Box::leak(s.into_boxed_str())
}
