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

/// The stdlib source manifest (curated upstream files, klio actuals, and
/// their repo-relative roots) lives in `stdlib_sources.zig` so the top-level
/// build.zig can import the same lists; re-exported here for consumers.
pub const stdlib_sources = @import("stdlib_sources.zig");
pub const CURATED_UPSTREAM_SOURCES = stdlib_sources.CURATED_UPSTREAM_SOURCES;
pub const KLIO_STDLIB_ACTUAL_FILES = stdlib_sources.KLIO_STDLIB_ACTUAL_FILES;
pub const UPSTREAM_STDLIB_ROOT = stdlib_sources.UPSTREAM_STDLIB_ROOT;
pub const KLIO_STDLIB_DIR = stdlib_sources.KLIO_STDLIB_DIR;

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
        var bytes: []const u8 = upstream.readFileAlloc(io, rel, a, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.* = .{ .Io = "curated stdlib source unreadable" };
                return null;
            },
        };
        if (std.mem.eql(u8, rel, stdlib_sources.KOTLIN_VERSION_FILE)) {
            bytes = (try stampKotlinVersion(a, bytes)) orelse {
                result.* = .{ .Io = "KotlinVersion placeholder not found; review KOTLIN_RELEASE in stdlib_sources.zig against the pinned kotlin/ tag" };
                return null;
            };
        }
        const rel_path = try std.fmt.allocPrint(a, "stdlib/kotlin/libraries/stdlib/{s}", .{rel});
        try files.append(a, .{ .rel_path = rel_path, .bytes = bytes });
    }

    var klio_dir = cwd.openDir(io, KLIO_STDLIB_DIR, .{}) catch {
        result.* = .{ .Io = "klio-stdlib directory missing: expected actuals at kotlin-klio" };
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

/// Rewrites the `KotlinVersion(major, minor, 255)` build placeholder in
/// `KotlinVersion.kt` to the pinned release triple, mirroring the rewrite
/// kotlinc's build performs on the same source. Returns null when the
/// placeholder is absent (a version bump changed the file shape).
fn stampKotlinVersion(a: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const needle = stdlib_sources.KOTLIN_VERSION_PLACEHOLDER;
    const idx = std.mem.indexOf(u8, bytes, needle) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, bytes[0..idx]);
    try out.appendSlice(a, stdlib_sources.KOTLIN_VERSION_STAMPED);
    try out.appendSlice(a, bytes[idx + needle.len ..]);
    return try out.toOwnedSlice(a);
}

test stampKotlinVersion {
    const a = std.testing.allocator;
    const src = "fun get(): KotlinVersion = KotlinVersion(2, 4, 255) // stamped";
    const got = (try stampKotlinVersion(a, src)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "fun get(): KotlinVersion = KotlinVersion(2, 4, 0) // stamped",
        got,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), try stampKotlinVersion(a, "no placeholder here"));
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
