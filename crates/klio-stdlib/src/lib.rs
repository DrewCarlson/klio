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

/// Bare names that resolve through implicit Kotlin imports. `(name, fqn)`
/// pairs the parser / interpreter installs into globals so identifiers
/// like `println`, `listOf`, or `IllegalArgumentException` resolve
/// without an explicit import. Mirrors Kotlin's
/// `kotlin.*` / `kotlin.io.*` / `kotlin.collections.*` /
/// `kotlin.text.*` / `kotlin.ranges.*` default imports.
pub const IMPLICIT_ALIASES: &[(&str, &str)] = &[
    ("print", "kotlin.io.print"),
    ("println", "kotlin.io.println"),
    ("readLine", "kotlin.io.readLine"),
    ("ArithmeticException", "kotlin.ArithmeticException"),
    ("ClassCastException", "kotlin.ClassCastException"),
    ("Error", "kotlin.Error"),
    ("Exception", "kotlin.Exception"),
    ("IllegalArgumentException", "kotlin.IllegalArgumentException"),
    ("IllegalStateException", "kotlin.IllegalStateException"),
    ("IndexOutOfBoundsException", "kotlin.IndexOutOfBoundsException"),
    ("NoSuchElementException", "kotlin.NoSuchElementException"),
    ("NullPointerException", "kotlin.NullPointerException"),
    ("RuntimeException", "kotlin.RuntimeException"),
    ("Throwable", "kotlin.Throwable"),
    ("UnsupportedOperationException", "kotlin.UnsupportedOperationException"),
    ("NoWhenBranchMatchedException", "kotlin.NoWhenBranchMatchedException"),
    ("NumberFormatException", "kotlin.NumberFormatException"),
    ("ConcurrentModificationException", "kotlin.ConcurrentModificationException"),
    ("AssertionError", "kotlin.AssertionError"),
    ("Pair", "kotlin.Pair"),
    ("Triple", "kotlin.Triple"),
    ("emptyList", "kotlin.collections.emptyList"),
    ("emptyMap", "kotlin.collections.emptyMap"),
    ("emptySet", "kotlin.collections.emptySet"),
    ("listOf", "kotlin.collections.listOf"),
    ("mapOf", "kotlin.collections.mapOf"),
    ("mutableListOf", "kotlin.collections.mutableListOf"),
    ("mutableMapOf", "kotlin.collections.mutableMapOf"),
    ("mutableSetOf", "kotlin.collections.mutableSetOf"),
    ("setOf", "kotlin.collections.setOf"),
    ("to", "kotlin.to"),
    ("ArrayList", "kotlin.collections.ArrayList"),
    ("ArrayDeque", "kotlin.collections.ArrayDeque"),
    ("HashMap", "kotlin.collections.HashMap"),
    ("HashSet", "kotlin.collections.HashSet"),
    ("LinkedHashMap", "kotlin.collections.LinkedHashMap"),
    ("LinkedHashSet", "kotlin.collections.LinkedHashSet"),
    ("sequenceOf", "kotlin.sequences.sequenceOf"),
    ("emptySequence", "kotlin.sequences.emptySequence"),
    ("generateSequence", "kotlin.sequences.generateSequence"),
    ("sequence", "kotlin.sequences.sequence"),
    ("downTo", "kotlin.ranges.downTo"),
    ("step", "kotlin.ranges.step"),
    ("until", "kotlin.ranges.until"),
    ("minOf", "kotlin.comparisons.minOf"),
    ("maxOf", "kotlin.comparisons.maxOf"),
    ("Regex", "kotlin.text.Regex"),
    ("StringBuilder", "kotlin.text.StringBuilder"),
];

/// True when `name` is a top-level stdlib *function* (a builder /
/// factory / IO / comparison helper), as opposed to an extension or
/// infix function on a receiver, a type, or an exception. Used by
/// member dispatch to avoid mis-classifying a bare call like
/// `listOf(1, 2)` (inside a receiver-typed lambda) as
/// `receiver.listOf(...)`: these names resolve to the top-level
/// function in Kotlin, never to a member of an arbitrary receiver.
///
/// Derived from [`IMPLICIT_ALIASES`] (the source of truth for which
/// bare names are stdlib top-level entities): take the lowercase
/// entries (functions, not types/exceptions) and exclude the few
/// that genuinely are receiver/infix extensions.
pub fn is_toplevel_function(name: &str) -> bool {
    // `to`, `downTo`, `step`, `until` are infix extensions on a
    // receiver — they legitimately dispatch with a receiver.
    const RECEIVER_INFIX: &[&str] = &["to", "downTo", "step", "until"];
    if RECEIVER_INFIX.contains(&name) {
        return false;
    }
    IMPLICIT_ALIASES.iter().any(|(alias, _)| {
        *alias == name && alias.chars().next().is_some_and(|c| c.is_lowercase())
    })
}

pub mod implementations;
pub mod pack_builder;
pub use pack_builder::build_stdlib_pack;

// Re-export internal helpers that the interpreter's higher-order ops use
// for comparisons. Keeps the API surface small.
pub use implementations::compare_values;
pub use implementations::materialise_sequence;
pub use implementations::primitive_companion_const;
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

/// Curated stdlib sources that PARSE but are not yet *consumed* (loaded /
/// registered): their interpreted declarations would shadow — and
/// currently conflict with — klio's host intrinsics, so the intrinsics
/// serve these APIs until the source bodies interoperate. The loaders
/// skip these by `rel_path` suffix. Each entry is a tracked
/// stdlib-source-integration TODO, not a permanent exclusion.
///
/// - `comparisons/Comparisons.kt`: `compareBy`/`thenBy`/`reversed`/the
///   `Comparator` SAM build comparator values the source combinators
///   expect to chain on; not yet interoperable with `Value::Comparator`
///   + `sortedWith`.
/// - `kotlin/TextH.kt`: declares the `Regex` / text surface whose
///   interpreted form shadows klio's `Value::Regex` intrinsics.
pub const CONSUMPTION_DEFERRED_SOURCES: &[&str] = &[
    "comparisons/Comparisons.kt",
    "kotlin/TextH.kt",
];

/// True when `rel_path` names a curated source on the consumption
/// deferral list (see [`CONSUMPTION_DEFERRED_SOURCES`]).
#[must_use]
pub fn is_consumption_deferred_source(rel_path: &str) -> bool {
    CONSUMPTION_DEFERRED_SOURCES
        .iter()
        .any(|suffix| rel_path.ends_with(suffix))
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
    if EXTRA_KNOWN_PACKAGES
        .get_or_init(Default::default)
        .lock()
        .map(|s| s.contains(package_path))
        .unwrap_or(false)
    {
        return true;
    }
    let prefix = format!("{package_path}.");
    if generated::stdlib_symbols()
        .iter()
        .any(|e| e.package == package_path || e.fqn.starts_with(&prefix))
    {
        return true;
    }
    // Hand-written intrinsics live outside the mined symbol index
    // (e.g. `kotlin.concurrent.thread`). A package that owns at least
    // one such intrinsic is just as real as a mined one.
    implementations::all_fqns().any(|fqn| {
        fqn.rsplit_once('.')
            .map_or(false, |(pkg, _)| pkg == package_path)
            || fqn.starts_with(&prefix)
    })
}

/// Augment the set of packages that [`is_known_package`] recognises.
/// Loaded packs call this when their manifest's `implicit_packages`
/// or symbol index declares packages outside the static stdlib
/// surface (e.g. `kotlinx.coroutines` once that pack ships). Idempotent.
pub fn register_known_package(package_path: impl Into<String>) {
    let pkg = package_path.into();
    if let Ok(mut set) = EXTRA_KNOWN_PACKAGES.get_or_init(Default::default).lock() {
        set.insert(pkg);
    }
}

/// Process-global resolver configuration: the set of package names
/// loaded packs have registered. This is deliberately *outside* the
/// per-thread interpreter execution context / publication boundary
/// (see `klio_interp_ir::ExecState`): it is set-up-time
/// configuration, not Kotlin heap state, written as packs install
/// and read-only during execution. It is already `Mutex`-guarded
/// and therefore safe to share across interpreter threads as-is.
static EXTRA_KNOWN_PACKAGES: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashSet<String>>,
> = std::sync::OnceLock::new();

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
    generated::stdlib_symbols().iter().find(|e| e.fqn == fqn)
}

/// Iterate every registered stdlib symbol FQN. Used by import resolution
/// to expand wildcard imports (`import kotlin.math.*`).
pub fn all_symbol_names() -> impl Iterator<Item = &'static str> {
    let registry = generated::stdlib_symbols().iter().map(|e| e.fqn);
    let hand = implementations::all_fqns();
    registry.chain(hand)
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
    let total = generated::stdlib_symbols().len();
    let registry_count = generated::stdlib_symbols()
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

/// Registry of native bindings — `host_symbol` → Rust [`StdlibFn`]. A
/// pack carries the FQN → `host_symbol` mapping; the host populates
/// this registry with the actual function pointers; the interpreter
/// joins them at load time. By convention `host_symbol` equals the
/// Kotlin FQN, but the registry treats them as opaque keys.
#[derive(Default, Clone)]
pub struct HostBindings {
    table: std::collections::HashMap<&'static str, StdlibFn>,
}

impl HostBindings {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Build a registry pre-populated with every FQN this build of
    /// `klio-stdlib` knows how to handle. Calling this is equivalent
    /// to "install everything the interpreter already had access to".
    #[must_use]
    pub fn with_stdlib_defaults() -> Self {
        let mut out = Self::new();
        for fqn in implementations::all_fqns() {
            if let Some(f) = implementations::lookup(fqn) {
                out.register(fqn, f);
            }
        }
        for entry in generated::stdlib_symbols() {
            if let Some(f) = entry.impl_fn {
                out.register(entry.fqn, f);
            }
        }
        out
    }

    pub fn register(&mut self, host_symbol: &'static str, f: StdlibFn) -> &mut Self {
        self.table.insert(host_symbol, f);
        self
    }

    #[must_use]
    pub fn resolve(&self, host_symbol: &str) -> Option<StdlibFn> {
        self.table.get(host_symbol).copied()
    }

    /// Iterate every `(host_symbol, fn)` pair currently registered.
    /// Used by callers that want to fold multiple registries into
    /// one — `klio-cli` merges the stdlib defaults with each
    /// `klio-kotlinx-*` crate's bindings this way.
    pub fn entries(&self) -> impl Iterator<Item = (&'static str, StdlibFn)> + '_ {
        self.table.iter().map(|(k, f)| (*k, *f))
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.table.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.table.is_empty()
    }
}

/// Declarative builder for a [`HostBindings`] registry. Each entry is
/// a `"fqn" => function` pair; the macro expands to a function returning
/// a populated registry. Cuts ~one line of boilerplate per binding.
///
/// ```ignore
/// klio_stdlib::host_bindings! {
///     pub fn host_bindings() {
///         "com.example.foo" => foo_impl,
///         "com.example.bar" => bar_impl,
///     }
/// }
/// ```
#[macro_export]
macro_rules! host_bindings {
    (
        $vis:vis fn $name:ident() {
            $( $fqn:literal => $func:path ),* $(,)?
        }
    ) => {
        #[must_use]
        $vis fn $name() -> $crate::HostBindings {
            let mut b = $crate::HostBindings::new();
            $(
                b.register($fqn, $func);
            )*
            b
        }
    };
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
    generated::stdlib_symbols()
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
        assert!(!generated::stdlib_symbols().is_empty(), "empty registry");
    }

    #[test]
    fn coverage_consistent_with_total() {
        let c = coverage();
        assert_eq!(c.total, generated::stdlib_symbols().len());
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
