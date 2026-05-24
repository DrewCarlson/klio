//! Build a `.klio-pack` byte stream describing this crate's stdlib
//! surface. Used by `klio pack stdlib` and by the `klio-stdlib-pack`
//! build script to embed a pack inside the interpreter binary.
//!
//! The MVP form emits `manifest`, `symbols`, and `bindings` sections
//! only; the AST / resolved / typeck sections are reserved for the
//! interpreted-stdlib path that follows after the MVP.

use std::path::{Path, PathBuf};

use klio_pack::schema::{
    encode, Binding, BindingKind, BindingManifest, ModifierBits, PackManifest, Purity, SourceBundle,
    SourceFile, SourceLoc, SymbolIndex, SymbolKind, SymbolRecord,
};
use klio_pack::{section_names, Compression, PackError, PackWriter};

use crate::{generated, implementation, param_names, IMPLICITLY_IMPORTED_PACKAGES};

/// Curated set of upstream stdlib commonMain `.kt` files the embedded
/// stdlib pack ships verbatim as a `SOURCES` section, so the
/// interpreter consumes the real upstream Kotlin instead of (or
/// alongside) the mined Rust surface.
///
/// This is the general, include-list-driven mechanism: each entry is a
/// path **relative to `kotlin/libraries/stdlib`** in the local upstream
/// Kotlin checkout. The list is intentionally scoped to `kotlin.time`
/// for now; growing the consumed-from-source surface later is a matter
/// of appending entries here (plus authoring any matching `actual`s).
///
/// The platform `actual`s for the `internal expect` declarations in
/// these files (and the one `public expect enum class DurationUnit`)
/// are supplied by [`KLIO_STDLIB_ACTUAL_FILES`], authored under
/// `crates/klio-stdlib/`.
const CURATED_UPSTREAM_SOURCES: &[&str] = &[
    "src/kotlin/time/Duration.kt",
    "src/kotlin/time/DurationUnit.kt",
    "src/kotlin/time/longSaturatedMath.kt",
    "src/kotlin/time/measureTime.kt",
    "src/kotlin/time/TimeSource.kt",
    "src/kotlin/time/TimeSources.kt",
    "src/kotlin/time/Clock.kt",
    "src/kotlin/time/Clocks.kt",
    "src/kotlin/time/Instant.kt",
    "src/kotlin/time/ExperimentalTime.kt",
    "src/kotlin/coroutines/CoroutineContext.kt",
    "src/kotlin/coroutines/CoroutineContextImpl.kt",
    "src/kotlin/coroutines/ContinuationInterceptor.kt",
    "src/kotlin/coroutines/Continuation.kt",
    "common/src/generated/_Strings.kt",
    "common/src/generated/_Maps.kt",
    "common/src/generated/_Collections.kt",
    "common/src/generated/_Sets.kt",
    "common/src/generated/_Ranges.kt",
    "common/src/generated/_Sequences.kt",
    "common/src/kotlin/Comparator.kt",
    "src/kotlin/util/Standard.kt",
    "src/kotlin/util/Tuples.kt",
    "src/kotlin/util/Result.kt",
    "src/kotlin/util/Numbers.kt",
    "src/kotlin/util/Lateinit.kt",
    "src/kotlin/util/FloorDivMod.kt",
    "src/kotlin/util/Suspend.kt",
    "src/kotlin/util/DeepRecursive.kt",
    "src/kotlin/util/HashCode.kt",
    "src/kotlin/util/Preconditions.kt",
    "src/kotlin/collections/AbstractCollection.kt",
    "src/kotlin/collections/AbstractList.kt",
    "src/kotlin/collections/AbstractMap.kt",
    "src/kotlin/collections/AbstractSet.kt",
    "src/kotlin/collections/Collections.kt",
    "src/kotlin/collections/Iterables.kt",
    "src/kotlin/collections/Maps.kt",
    "src/kotlin/collections/Iterators.kt",
    "src/kotlin/collections/MapAccessors.kt",
    "src/kotlin/collections/SlidingWindow.kt",
    "src/kotlin/collections/MutableCollections.kt",
    "src/kotlin/collections/ReversedViews.kt",
    "src/kotlin/collections/Grouping.kt",
    "src/kotlin/collections/IndexedValue.kt",
    "src/kotlin/collections/MapWithDefault.kt",
    "src/kotlin/collections/Sequence.kt",
    "src/kotlin/collections/SequenceBuilder.kt",
    "src/kotlin/collections/Sets.kt",
    "src/kotlin/comparisons/Comparisons.kt",
    "src/kotlin/comparisons/compareTo.kt",
    "src/kotlin/annotations/OptIn.kt",
    "src/kotlin/annotations/Multiplatform.kt",
    "src/kotlin/annotations/ExperimentalStdlibApi.kt",
    "src/kotlin/annotations/Inference.kt",
    "src/kotlin/annotations/Throws.kt",
    "src/kotlin/annotations/WasExperimental.kt",
    "src/kotlin/annotations/ReturnValue.kt",
    "src/kotlin/annotations/ConsistentCopyVisibility.kt",
    "src/kotlin/annotations/VersionOverloads.kt",
    "src/kotlin/properties/Interfaces.kt",
    "src/kotlin/properties/ObservableProperty.kt",
    "src/kotlin/properties/PropertyReferenceDelegates.kt",
    "src/kotlin/text/CharacterCodingException.kt",
    "src/kotlin/io/encoding/ExperimentalEncodingApi.kt",
    "src/kotlin/uuid/ExperimentalUuidApi.kt",
    "src/kotlin/experimental/ExperimentalNativeApi.kt",
    "src/kotlin/concurrent/Volatile.kt",
    "src/kotlin/concurrent/atomics/ExperimentalAtomicApi.kt",
    "src/kotlin/contextParameters/ExperimentalContextParameters.kt",
    "src/kotlin/ranges/Range.kt",
    "src/kotlin/ranges/Ranges.kt",
    "src/kotlin/ranges/Progressions.kt",
    "src/kotlin/ranges/ProgressionIterators.kt",
    "src/kotlin/AutoCloseable.kt",
    "src/kotlin/contextParameters/Context.kt",
    "src/kotlin/contextParameters/ContextOf.kt",
    "src/kotlin/properties/Delegates.kt",
    "src/kotlin/Function.kt",
    "src/kotlin/random/URandom.kt",
    "src/kotlin/enums/EnumEntries.kt",
    "src/kotlin/Library.kt",
    "src/kotlin/uuid/Uuid.kt",
    "src/kotlin/Unit.kt",
    "src/kotlin/Throwable.kt",
    "src/kotlin/text/regex/MatchResult.kt",
    "src/kotlin/text/regex/RegexExtensions.kt",
    "src/kotlin/CharCode.kt",
    "src/kotlin/Boolean.kt",
    "src/kotlin/Nothing.kt",
    "src/kotlin/Enum.kt",
    "src/kotlin/Number.kt",
    "src/kotlin/Comparable.kt",
    "src/kotlin/Iterator.kt",
    "src/kotlin/CharSequence.kt",
    "src/kotlin/Any.kt",
    "src/kotlin/experimental/ExpectRefinement.kt",
    "src/kotlin/experimental/ExperimentalObjCEnum.kt",
    "src/kotlin/experimental/ExperimentalObjCName.kt",
    "src/kotlin/experimental/ExperimentalObjCRefinement.kt",
    "src/kotlin/reflect/KVariance.kt",
    "src/kotlin/reflect/KTypeProjection.kt",
    "src/kotlin/reflect/KClassifier.kt",
    "src/kotlin/reflect/KTypeParameter.kt",
    "src/kotlin/reflect/KType.kt",
    "src/kotlin/reflect/KCallable.kt",
    "src/kotlin/reflect/KFunction.kt",
    "src/kotlin/reflect/KProperty.kt",
    "src/kotlin/reflect/KClass.kt",
    "src/kotlin/reflect/KClasses.kt",
    "src/kotlin/reflect/typeOf.kt",
    "src/kotlin/Array.kt",
    "src/kotlin/Collections.kt",
    "src/kotlin/String.kt",
    "src/kotlin/Char.kt",
    "src/kotlin/Arrays.kt",
    "src/kotlin/ArrayIntrinsics.kt",
    "common/src/generated/_OneToManyTitlecaseMappings.kt",
    "common/src/generated/_Comparisons.kt",
    "common/src/generated/_UCollections.kt",
    "common/src/generated/_UComparisons.kt",
    "common/src/generated/_URanges.kt",
    "common/src/generated/_USequences.kt",
    "common/src/generated/_Arrays.kt",
    "common/src/generated/_UArrays.kt",
    "common/src/kotlin/ExceptionsH.kt",
    "common/src/kotlin/MathH.kt",
    "common/src/kotlin/TextH.kt",
    "common/src/kotlin/SequencesH.kt",
    "common/src/kotlin/collections/CollectionsH.kt",
    "src/kotlin/coroutines/cancellation/CancellationExceptionH.kt",
    "src/kotlin/collections/ArrayDeque.kt",
    "src/kotlin/collections/UArraySorting.kt",
    "src/kotlin/collections/Sequences.kt",
    "src/kotlin/ranges/PrimitiveRanges.kt",
    "src/kotlin/util/KotlinVersion.kt",
    "src/kotlin/collections/PrimitiveIterators.kt",
    "src/kotlin/collections/Arrays.kt",
    "common/src/kotlin/JsAnnotationsH.kt",
    "common/src/kotlin/JvmAnnotationsH.kt",
    "src/kotlin/annotations/NativeAnnotations.kt",
    "src/kotlin/annotations/NativeConcurrentAnnotations.kt",
    "src/kotlin/Primitives.kt",
    "src/kotlin/random/Random.kt",
    "src/kotlin/random/XorWowRandom.kt",
    "src/kotlin/text/HexFormat.kt",
    "src/kotlin/text/CharCategory.kt",
    "src/kotlin/collections/AbstractIterator.kt",
    "src/kotlin/text/Appendable.kt",
    "src/kotlin/text/Char.kt",
    "src/kotlin/text/StringNumberConversions.kt",
    "src/kotlin/text/Strings.kt",
    "src/kotlin/text/Indent.kt",
    "src/kotlin/text/Typography.kt",
    "src/kotlin/contracts/ContractBuilder.kt",
    "src/kotlin/contracts/Effect.kt",
    "src/kotlin/annotation/Annotations.kt",
    "src/kotlin/Annotation.kt",
    "src/kotlin/Annotations.kt",
    "src/kotlin/internal/Annotations.kt",
    "src/kotlin/internal/AnnotationsBuiltin.kt",
    "src/kotlin/internal/progressionUtil.kt",
    "src/kotlin/internal/serializationUtil.kt",
    "src/kotlin/experimental/bitwiseOperations.kt",
    "src/kotlin/experimental/inferenceMarker.kt",
];

/// klio-authored platform `actual` source files shipped in the same
/// `SOURCES` section, paths relative to the `klio-stdlib` crate root.
const KLIO_STDLIB_ACTUAL_FILES: &[&str] = &[
    "kotlin-time/Actuals.kt",
    "kotlin-coroutines/Actuals.kt",
    "kotlin-coroutines/Intrinsics.kt",
    "kotlin-collections/CollectionsActuals.kt",
    "kotlin-io/Closeable.kt",
    "kotlin-io/Serializable.kt",
    "kotlin-util/Lazy.kt",
];

/// Locate the local upstream Kotlin checkout's `libraries/stdlib`
/// directory (the same one the stdlib-gen miner and the parity harness
/// depend on). The workspace root is two levels up from the
/// `klio-stdlib` crate dir.
fn upstream_stdlib_root() -> Result<PathBuf, PackError> {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let ws_root = crate_dir
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| PackError::Io("cannot locate workspace root from klio-stdlib".into()))?;
    let root = ws_root.join("kotlin").join("libraries").join("stdlib");
    if !root.is_dir() {
        return Err(PackError::Io(format!(
            "upstream Kotlin checkout missing: expected stdlib sources at {} \
             (the curated stdlib SOURCES path and the parity harness both \
             require the local `kotlin/` checkout)",
            root.display()
        )));
    }
    Ok(root)
}

/// Read the curated upstream commonMain files plus the klio-authored
/// `actual` files into a [`SourceBundle`]. Fails hard (matching the
/// parity harness's hard dependency on the checkout) when an expected
/// file is absent.
fn build_curated_sources() -> Result<SourceBundle, PackError> {
    let upstream = upstream_stdlib_root()?;
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut files: Vec<SourceFile> = Vec::new();

    for rel in CURATED_UPSTREAM_SOURCES {
        let abs = upstream.join(rel);
        let bytes = std::fs::read(&abs).map_err(|e| {
            PackError::Io(format!(
                "curated stdlib source {} unreadable: {e}",
                abs.display()
            ))
        })?;
        files.push(SourceFile {
            rel_path: format!("stdlib/kotlin/libraries/stdlib/{rel}"),
            bytes,
        });
    }

    for rel in KLIO_STDLIB_ACTUAL_FILES {
        let abs = crate_dir.join(rel);
        let bytes = std::fs::read(&abs).map_err(|e| {
            PackError::Io(format!(
                "klio stdlib actual source {} unreadable: {e}",
                abs.display()
            ))
        })?;
        files.push(SourceFile {
            rel_path: format!("stdlib/klio/{rel}"),
            bytes,
        });
    }

    Ok(SourceBundle { files })
}

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

    let mut sym_entries: Vec<SymbolRecord> = generated::stdlib_symbols()
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
            platform_actual: false,
        });
    }
    bindings.sort_by(|a, b| a.fqn.cmp(&b.fqn));
    let binding_bytes = encode(&BindingManifest { bindings })?;

    // Curated upstream commonMain + klio actuals, shipped so the loader
    // can parse + register them when a program imports a package these
    // sources provide (today: `kotlin.time`). The mined SYMBOLS /
    // BINDINGS sections above are still what gets statically linked;
    // this SOURCES section carries the Kotlin the interpreter parses.
    let sources_bytes = encode(&build_curated_sources()?)?;

    let mut writer = PackWriter::new();
    writer.add_raw(section_names::MANIFEST, manifest_bytes);
    writer.add_section(
        section_names::SYMBOLS,
        symbol_bytes,
        if compress_symbols { Compression::Zstd } else { Compression::None },
    );
    writer.add_raw(section_names::BINDINGS, binding_bytes);
    writer.add_section(section_names::SOURCES, sources_bytes, Compression::Zstd);
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
