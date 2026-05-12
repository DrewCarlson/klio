//! Kotlin stdlib host.
//!
//! This crate is the home of the Rust-native Kotlin standard library. The shape
//! of the API surface is produced by the `klio-stdlib-gen` binary from the
//! upstream Kotlin sources (`kotlin/libraries/stdlib/`) and lives in
//! `src/generated/`.
//!
//! # Symbol schema
//!
//! Every public symbol mined from the upstream tree is recorded as a
//! [`SymbolEntry`]. The `STDLIB_SYMBOLS` slice in `generated::symbols` is the
//! canonical registry. Each entry carries:
//!
//! * `fqn`        — fully qualified name (`kotlin.collections.listOf`)
//! * `package`    — package path (`kotlin.collections`)
//! * `name`       — simple name (`listOf`)
//! * `kind`       — function / property / class / interface / typealias / object
//! * `receiver`   — extension receiver type as text, if any
//! * `signature`  — raw textual signature (trimmed source line)
//! * `modifiers`  — bitset of Kotlin modifiers we care about
//! * `source`     — relative upstream path + 1-based line/column
//! * `impl_fn`    — `Some(fn)` once a Rust implementation is wired up.
//!
//! Future contributors: when adding a real Rust implementation, set the entry's
//! `impl_fn` to `Some(...)`. Coverage is `entries with impl_fn = Some / total`.

pub mod collections;
pub mod exceptions;
pub mod generated;
pub mod io;
pub mod numerics;
pub mod ranges;
pub mod sequences;
pub mod text;

/// Function pointer signature for a Rust-native stdlib intrinsic.
pub use klio_runtime::StdlibFn;

pub mod implementations;

// Re-export internal helpers that the interpreter's higher-order ops use
// for comparisons. Keeps the API surface small.
pub use implementations::compare_values;
pub use text::compare_utf16;

/// Packages whose top-level entities are implicitly visible in every Kotlin
/// source file, per Kotlin language spec §10.1. The exact set the spec lists
/// for `Kotlin/Core`.
pub const IMPLICITLY_IMPORTED_PACKAGES: &[&str] = &[
    "kotlin",
    "kotlin.annotation",
    "kotlin.collections",
    "kotlin.comparisons",
    "kotlin.io",
    "kotlin.ranges",
    "kotlin.sequences",
    "kotlin.text",
    "kotlin.math",
];

/// Returns true when `package_path` is one of the spec's implicitly imported
/// packages (an exact match against [`IMPLICITLY_IMPORTED_PACKAGES`]).
#[must_use]
pub fn is_implicitly_imported_package(package_path: &str) -> bool {
    IMPLICITLY_IMPORTED_PACKAGES.iter().any(|p| *p == package_path)
}

/// Returns true when `package_path` names any package recognised by the
/// stdlib registry. Wider than [`is_implicitly_imported_package`] — covers
/// every package that has at least one symbol mined from upstream Kotlin
/// (e.g. `kotlin.coroutines`, `kotlin.coroutines.intrinsics`, `kotlin.reflect`).
/// Used by the resolver to decide whether an `import kotlin.<pkg>.*` is
/// well-formed even though the package is not implicitly visible.
#[must_use]
pub fn is_known_package(package_path: &str) -> bool {
    if is_implicitly_imported_package(package_path) {
        return true;
    }
    let prefix = format!("{package_path}.");
    generated::STDLIB_SYMBOLS
        .iter()
        .any(|e| e.package == package_path || e.fqn.starts_with(&prefix))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SymbolKind {
    Function,
    Property,
    Class,
    Interface,
    Object,
    TypeAlias,
}

impl SymbolKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Function => "function",
            Self::Property => "property",
            Self::Class => "class",
            Self::Interface => "interface",
            Self::Object => "object",
            Self::TypeAlias => "typealias",
        }
    }
}

/// Modifier flags as a bitset. Stable bit assignments so the generator can emit
/// `Modifiers(0b...)` literals.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Modifiers(pub u32);

impl Modifiers {
    pub const PUBLIC: u32 = 1 << 0;
    pub const INTERNAL: u32 = 1 << 1;
    pub const PROTECTED: u32 = 1 << 2;
    pub const PRIVATE: u32 = 1 << 3;
    pub const OPEN: u32 = 1 << 4;
    pub const ABSTRACT: u32 = 1 << 5;
    pub const FINAL: u32 = 1 << 6;
    pub const SEALED: u32 = 1 << 7;
    pub const INLINE: u32 = 1 << 8;
    pub const INFIX: u32 = 1 << 9;
    pub const OPERATOR: u32 = 1 << 10;
    pub const TAILREC: u32 = 1 << 11;
    pub const EXPECT: u32 = 1 << 12;
    pub const ACTUAL: u32 = 1 << 13;
    pub const EXTERNAL: u32 = 1 << 14;
    pub const SUSPEND: u32 = 1 << 15;
    pub const OVERRIDE: u32 = 1 << 16;
    pub const DATA: u32 = 1 << 17;
    pub const VALUE: u32 = 1 << 18;
    pub const ENUM: u32 = 1 << 19;
    pub const ANNOTATION: u32 = 1 << 20;
    pub const COMPANION: u32 = 1 << 21;
    pub const CONST: u32 = 1 << 22;

    #[must_use]
    pub const fn has(self, bit: u32) -> bool {
        (self.0 & bit) != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SourceLoc {
    pub path: &'static str,
    pub line: u32,
    pub column: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct SymbolEntry {
    pub fqn: &'static str,
    pub package: &'static str,
    pub name: &'static str,
    pub kind: SymbolKind,
    pub receiver: Option<&'static str>,
    pub signature: &'static str,
    /// Parameter names in declaration order. Empty for non-function
    /// declarations. The interpreter consults this when reordering
    /// named-argument calls before dispatching the function pointer.
    pub param_names: &'static [&'static str],
    pub modifiers: Modifiers,
    pub source: SourceLoc,
    pub impl_fn: Option<StdlibFn>,
}

/// Look up a symbol by fully qualified name.
///
/// Linear scan today. The registry is small enough (< 50k) that this is fine
/// for the codegen milestone. A perfect-hash or precomputed sorted-binary-search
/// table is a trivial follow-up if profiling demands it.
#[must_use]
pub fn lookup(fqn: &str) -> Option<&'static SymbolEntry> {
    generated::STDLIB_SYMBOLS.iter().find(|e| e.fqn == fqn)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Coverage {
    pub implemented: usize,
    pub total: usize,
}

impl Coverage {
    #[must_use]
    pub fn percent(self) -> f64 {
        if self.total == 0 {
            0.0
        } else {
            (self.implemented as f64) * 100.0 / (self.total as f64)
        }
    }
}

#[must_use]
pub fn coverage() -> Coverage {
    let total = generated::STDLIB_SYMBOLS.len();
    let registry_count = generated::STDLIB_SYMBOLS
        .iter()
        .filter(|e| e.impl_fn.is_some())
        .count();
    let hand_count = implementations::COUNT;
    Coverage { implemented: registry_count + hand_count, total }
}

/// Look up a hand-written intrinsic by FQN. Used by the interpreter to
/// dispatch qualified calls (`kotlin.math.abs`) and member access on
/// builtin types (`<typeFQN>.<name>`).
#[must_use]
pub fn implementation(fqn: &str) -> Option<StdlibFn> {
    implementations::lookup(fqn)
}

/// Look up the declared parameter names for a function FQN. The interpreter
/// uses this to reorder named-argument calls before dispatching the
/// intrinsic. Returns `None` when no entry exists (e.g. our hand-written
/// intrinsic isn't covered by the upstream surface) or when the FQN names
/// a non-function symbol.
#[must_use]
pub fn param_names(fqn: &str) -> Option<&'static [&'static str]> {
    // Hand-impl table wins. Its FQNs match what `klio-interp`'s dispatch
    // synthesizes (`kotlin.collections.List.joinToString` etc.) and entries
    // are curated for the intrinsics where named args actually matter.
    if let Some(p) = implementations::lookup_param_names(fqn) {
        return Some(p);
    }
    if let Some(p) = direct_param_lookup(fqn) {
        return Some(p);
    }
    // Our dispatch synthesizes FQNs like `kotlin.collections.List.joinToString`
    // for member calls on a `List`, but the upstream surface stores the
    // extension form `kotlin.collections.joinToString`. Strip the
    // second-to-last segment (the receiver type) and retry once.
    let parts: Vec<&str> = fqn.split('.').collect();
    if parts.len() >= 3 {
        let mut alt = String::new();
        for (i, p) in parts.iter().enumerate() {
            if i == parts.len() - 2 {
                continue;
            }
            if !alt.is_empty() {
                alt.push('.');
            }
            alt.push_str(p);
        }
        if let Some(p) = direct_param_lookup(&alt) {
            return Some(p);
        }
    }
    None
}

fn direct_param_lookup(fqn: &str) -> Option<&'static [&'static str]> {
    // The upstream mining produces multiple SymbolEntry rows per FQN (one
    // per overload / receiver). Their parameter-name lists are
    // overwhelmingly identical, so the first non-empty hit is correct for
    // the common case.
    generated::STDLIB_SYMBOLS
        .iter()
        .find(|e| e.fqn == fqn && !e.param_names.is_empty())
        .map(|e| e.param_names)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_is_non_empty() {
        // The generated registry should contain at least the seed symbols
        // committed in `generated/symbols.rs`. Real builds replace this with
        // the full mined surface.
        assert!(!generated::STDLIB_SYMBOLS.is_empty(), "empty registry");
    }

    #[test]
    fn coverage_consistent_with_total() {
        let c = coverage();
        assert_eq!(c.total, generated::STDLIB_SYMBOLS.len());
        assert!(c.implemented <= c.total);
    }

    #[test]
    fn lookup_returns_none_for_unknown() {
        assert!(lookup("definitely.not.a.real.kotlin.symbol").is_none());
    }

    #[test]
    fn implicitly_imported_packages_match_spec_list() {
        // Spec §10.1 fixes this list. Lock it down so accidental
        // additions or reorderings fail loudly.
        assert_eq!(
            IMPLICITLY_IMPORTED_PACKAGES,
            &[
                "kotlin",
                "kotlin.annotation",
                "kotlin.collections",
                "kotlin.comparisons",
                "kotlin.io",
                "kotlin.ranges",
                "kotlin.sequences",
                "kotlin.text",
                "kotlin.math",
            ]
        );
        assert!(is_implicitly_imported_package("kotlin.math"));
        assert!(!is_implicitly_imported_package("kotlin.reflect"));
        assert!(!is_implicitly_imported_package("kotlin.math.foo"));
    }

    #[test]
    fn is_known_package_covers_coroutines() {
        // Spec §18.3: kotlin.coroutines and kotlin.coroutines.intrinsics
        // are not implicitly imported, but the symbols exist in the
        // registry so an explicit `import kotlin.coroutines.*` must
        // resolve.
        assert!(is_known_package("kotlin.coroutines"));
        assert!(is_known_package("kotlin.coroutines.intrinsics"));
        assert!(!is_known_package("kotlin.bogus"));
    }

    #[test]
    fn coroutine_core_types_present() {
        for fqn in [
            "kotlin.coroutines.Continuation",
            "kotlin.coroutines.CoroutineContext",
            "kotlin.coroutines.EmptyCoroutineContext",
            "kotlin.coroutines.ContinuationInterceptor",
            "kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn",
            "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
        ] {
            assert!(
                lookup(fqn).is_some(),
                "stdlib registry missing {fqn}"
            );
        }
    }
}
