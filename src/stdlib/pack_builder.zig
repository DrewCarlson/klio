//! Build a `.klio-pack` byte stream describing the stdlib surface. Used by
//! `klio pack stdlib` and by the embedded-pack build path.
//!
//! Emits `manifest`, `symbols`, `bindings`, and `sources` sections. The
//! Zig std has no zstd encoder, so every section is stored uncompressed; the
//! `compress_symbols` flag is accepted for source compatibility but has no
//! effect.

const std = @import("std");
const pack = @import("pack");

const root = @import("stdlib.zig");
const schema = pack.schema;
const PackError = pack.PackError;
const PackWriter = pack.PackWriter;
const section_names = pack.section_names;

/// The library version embedded in the pack manifest. The Rust build stamped
/// this from `CARGO_PKG_VERSION`; here it is the in-tree stdlib version.
pub const LIBRARY_VERSION: []const u8 = "0.1.0";

/// Curated set of upstream stdlib commonMain `.kt` files the embedded stdlib
/// pack ships verbatim as a `SOURCES` section, so the interpreter consumes
/// the real upstream Kotlin instead of (or alongside) the mined surface.
///
/// Each entry is a path relative to `kotlin/libraries/stdlib` in the local
/// upstream Kotlin checkout.
pub const CURATED_UPSTREAM_SOURCES = [_][]const u8{
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
    // `AtomicArrays.common.kt` is omitted: experimental array atomics with no
    // klio actual whose bare names collided with kotlinx.atomicfu types. The
    // scalar atomics stay.
    "src/kotlin/concurrent/atomics/Atomics.common.kt",
    "src/kotlin/util/Lazy.kt",
    "common/src/kotlin/KotlinH.kt",
    "common/src/kotlin/ioH.kt",
    "src/kotlin/text/StringBuilder.kt",
    "src/kotlin/text/HexExtensions.kt",
    "src/kotlin/text/UHexExtensions.kt",
    "src/kotlin/io/encoding/Base64.kt",
    "src/kotlin/coroutines/CoroutinesH.kt",
    "src/kotlin/coroutines/CoroutinesIntrinsicsH.kt",
    "src/kotlin/coroutines/intrinsics/Intrinsics.kt",
    "common/src/kotlin/collections/AbstractMutableCollection.kt",
    "common/src/kotlin/collections/AbstractMutableList.kt",
    "common/src/kotlin/collections/AbstractMutableMap.kt",
    "common/src/kotlin/collections/AbstractMutableSet.kt",
    "common/src/kotlin/collections/ArrayList.kt",
    "common/src/kotlin/collections/HashMap.kt",
    "common/src/kotlin/collections/HashSet.kt",
    "common/src/kotlin/collections/LinkedHashMap.kt",
    "common/src/kotlin/collections/LinkedHashSet.kt",
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
};

/// klio-authored platform `actual` source files shipped in the same `SOURCES`
/// section, paths relative to the `crates/klio-stdlib` directory.
pub const KLIO_STDLIB_ACTUAL_FILES = [_][]const u8{
    "kotlin-time/Actuals.kt",
    "kotlin-coroutines/Actuals.kt",
    "kotlin-coroutines/Intrinsics.kt",
    "kotlin-collections/CollectionsActuals.kt",
    "kotlin-io/Closeable.kt",
    "kotlin-io/Serializable.kt",
    "kotlin-io/encoding/Base64Actuals.kt",
    "kotlin-internal/SerializationActuals.kt",
    "kotlin-util/LazyActuals.kt",
};

/// The local upstream Kotlin checkout's `libraries/stdlib` directory, relative
/// to the workspace root (the process cwd when the pack is built).
const UPSTREAM_STDLIB_ROOT = "kotlin/libraries/stdlib";
/// The `crates/klio-stdlib` directory holding the klio-authored actuals.
const KLIO_STDLIB_DIR = "crates/klio-stdlib";

/// Build a deterministic pack for the in-process Kotlin standard library.
///
/// `compress_symbols` is accepted for source compatibility with the Rust
/// builder; this build has no zstd encoder so every section is stored
/// uncompressed. On failure `result` is set and `null` is returned.
pub fn buildStdlibPack(
    allocator: std.mem.Allocator,
    compress_symbols: bool,
    result: *PackError,
) std.mem.Allocator.Error!?std.ArrayList(u8) {
    _ = compress_symbols;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // -- manifest --
    var implicit = try a.alloc([]const u8, root.IMPLICITLY_IMPORTED_PACKAGES.len);
    for (root.IMPLICITLY_IMPORTED_PACKAGES, 0..) |p, i| implicit[i] = p;
    const manifest = schema.PackManifest{
        .library_id = "stdlib",
        .library_version = LIBRARY_VERSION,
        .abi_version = 1,
        .implicit_packages = implicit,
        .dependencies = &.{},
        .default_features = &.{},
        .features = &.{},
    };
    const manifest_bytes = (try schema.encode(schema.PackManifest, a, &manifest, result)) orelse return null;

    // -- symbols --
    const syms = root.generated.stdlibSymbols();
    var sym_entries = try a.alloc(schema.SymbolRecord, syms.len);
    for (syms, 0..) |*e, i| sym_entries[i] = symbolEntryToRecord(e);
    std.mem.sort(schema.SymbolRecord, sym_entries, {}, lessRecordByFqn);
    const symbol_index = schema.SymbolIndex{ .entries = sym_entries };
    const symbol_bytes = (try schema.encode(schema.SymbolIndex, a, &symbol_index, result)) orelse return null;

    // -- bindings --
    var bindings: std.ArrayList(schema.Binding) = .empty;
    var seen = std.StringHashMap(void).init(a);
    var names = root.allSymbolNames();
    while (names.next()) |fqn| {
        if (root.implementation(fqn) == null) continue;
        const gop = try seen.getOrPut(fqn);
        if (gop.found_existing) continue;
        const arity: usize = if (root.paramNames(fqn)) |p| p.len else 0;
        const max_arity: u8 = std.math.cast(u8, arity) orelse std.math.maxInt(u8);
        try bindings.append(a, .{
            .fqn = fqn,
            .kind = .Function,
            .host_symbol = fqn,
            .overrides_interpreter = true,
            .purity = .Effectful,
            .min_arity = max_arity,
            .max_arity = max_arity,
            .platform_actual = false,
        });
    }
    std.mem.sort(schema.Binding, bindings.items, {}, lessBindingByFqn);
    const binding_manifest = schema.BindingManifest{ .bindings = bindings.items };
    const binding_bytes = (try schema.encode(schema.BindingManifest, a, &binding_manifest, result)) orelse return null;

    // -- sources --
    const sources = (try buildCuratedSources(a, result)) orelse return null;
    const sources_bytes = (try schema.encode(schema.SourceBundle, a, &sources, result)) orelse return null;

    // -- assemble --
    var writer = PackWriter.init(allocator);
    defer writer.deinit();
    _ = try writer.addRaw(section_names.MANIFEST, manifest_bytes.items);
    _ = try writer.addRaw(section_names.SYMBOLS, symbol_bytes.items);
    _ = try writer.addRaw(section_names.BINDINGS, binding_bytes.items);
    _ = try writer.addRaw(section_names.SOURCES, sources_bytes.items);
    return try writer.finish(result);
}

/// Read the curated upstream commonMain files plus the klio-authored `actual`
/// files into a `SourceBundle`. Fails as data when an expected file is absent.
fn buildCuratedSources(a: std.mem.Allocator, result: *PackError) std.mem.Allocator.Error!?schema.SourceBundle {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList(schema.SourceFile) = .empty;

    var upstream = cwd.openDir(io, UPSTREAM_STDLIB_ROOT, .{}) catch {
        result.* = .{ .Io = "upstream Kotlin checkout missing: expected stdlib sources at kotlin/libraries/stdlib" };
        return null;
    };
    defer upstream.close(io);

    for (CURATED_UPSTREAM_SOURCES) |rel| {
        const bytes = upstream.readFileAlloc(io, rel, a, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.* = .{ .Io = "curated stdlib source unreadable" };
                return null;
            },
        };
        const rel_path = try std.fmt.allocPrint(a, "stdlib/kotlin/libraries/stdlib/{s}", .{rel});
        try files.append(a, .{ .rel_path = rel_path, .bytes = bytes });
    }

    var klio_dir = cwd.openDir(io, KLIO_STDLIB_DIR, .{}) catch {
        result.* = .{ .Io = "klio-stdlib directory missing: expected actuals at crates/klio-stdlib" };
        return null;
    };
    defer klio_dir.close(io);

    for (KLIO_STDLIB_ACTUAL_FILES) |rel| {
        const bytes = klio_dir.readFileAlloc(io, rel, a, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.* = .{ .Io = "klio stdlib actual source unreadable" };
                return null;
            },
        };
        const rel_path = try std.fmt.allocPrint(a, "stdlib/klio/{s}", .{rel});
        try files.append(a, .{ .rel_path = rel_path, .bytes = bytes });
    }

    return .{ .files = files.items };
}

fn symbolEntryToRecord(e: *const root.SymbolEntry) schema.SymbolRecord {
    const kind: schema.SymbolKind = switch (e.kind) {
        .Function => .Function,
        .Property => .Property,
        .Class => .Class,
        .Interface => .Interface,
        .Object => .Object,
        .TypeAlias => .TypeAlias,
    };
    return .{
        .fqn = e.fqn,
        .package = e.package,
        .name = e.name,
        .kind = kind,
        .receiver = e.receiver,
        .signature = e.signature,
        .param_names = @constCast(e.param_names),
        .modifiers = schema.ModifierBits.fromBits(e.modifiers.bits),
        .source = .{ .path = e.source.path, .line = e.source.line, .column = e.source.column },
    };
}

fn lessRecordByFqn(_: void, x: schema.SymbolRecord, y: schema.SymbolRecord) bool {
    return std.mem.order(u8, x.fqn, y.fqn) == .lt;
}

fn lessBindingByFqn(_: void, x: schema.Binding, y: schema.Binding) bool {
    return std.mem.order(u8, x.fqn, y.fqn) == .lt;
}

const testing = std.testing;

test "symbol entry to record preserves fqn and kind" {
    const params = [_][]const u8{"message"};
    const e = root.SymbolEntry{
        .fqn = "kotlin.io.println",
        .package = "kotlin.io",
        .name = "println",
        .kind = .Function,
        .receiver = null,
        .signature = "public fun println(message: Any?): Unit",
        .param_names = &params,
        .modifiers = .{ .bits = root.Modifiers.PUBLIC },
        .source = .{ .path = "Console.kt", .line = 42, .column = 1 },
        .impl_fn = null,
    };
    const r = symbolEntryToRecord(&e);
    try testing.expectEqualStrings("kotlin.io.println", r.fqn);
    try testing.expectEqual(schema.SymbolKind.Function, r.kind);
    try testing.expect(r.modifiers.PUBLIC);
    try testing.expectEqual(@as(usize, 1), r.param_names.len);
}
