//! Typed payloads carried in well-known pack sections. A section stores the
//! encoded bytes of one of these values inside the `format.SectionDirectory`
//! envelope.
//!
//! Representations are stable for a given `format.FORMAT_VERSION`; an
//! incompatible schema change bumps that constant.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");
const types = @import("types");

const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
pub const PackError = errors.PackError;

/// Top-level pack metadata. Always present, always uncompressed.
pub const PackManifest = struct {
    /// Library identifier (`stdlib`, `kotlinx.coroutines`), keying the pack
    /// inside the host registry.
    library_id: []const u8,
    /// Semantic version of the packaged library.
    library_version: []const u8,
    /// ABI version for native bindings, bumped when the `StdlibFn` signature
    /// changes. Readers reject packs with an ABI they do not understand.
    abi_version: u32,
    /// Packages whose top-level entities are implicitly visible once loaded.
    implicit_packages: [][]const u8 = &.{},
    /// Other packs this one depends on, by `library_id`, walked by the loader
    /// in topological order.
    dependencies: []PackDependency = &.{},
    /// Features active when a consumer requests none. Empty means only
    /// ungated ("core") source loads.
    default_features: [][]const u8 = &.{},
    /// Named features this pack provides. A source file whose `rel_path`
    /// matches a feature's `sources` loads only while that feature is active;
    /// a file matched by no feature is core and always loads.
    features: []FeatureDef = &.{},

    pub fn eql(self: PackManifest, other: PackManifest) bool {
        if (!std.mem.eql(u8, self.library_id, other.library_id)) return false;
        if (!std.mem.eql(u8, self.library_version, other.library_version)) return false;
        if (self.abi_version != other.abi_version) return false;
        if (!eqlStrSlice(self.implicit_packages, other.implicit_packages)) return false;
        if (self.dependencies.len != other.dependencies.len) return false;
        for (self.dependencies, other.dependencies) |a, b| {
            if (!a.eql(b)) return false;
        }
        if (!eqlStrSlice(self.default_features, other.default_features)) return false;
        if (self.features.len != other.features.len) return false;
        for (self.features, other.features) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *PackManifest, allocator: Allocator) void {
        allocator.free(self.library_id);
        allocator.free(self.library_version);
        freeStrSlice(allocator, self.implicit_packages);
        for (self.dependencies) |*d| d.deinit(allocator);
        allocator.free(self.dependencies);
        freeStrSlice(allocator, self.default_features);
        for (self.features) |*f| f.deinit(allocator);
        allocator.free(self.features);
        self.* = undefined;
    }
};

pub const PackDependency = struct {
    library_id: []const u8,
    /// Minimum semantic version; empty accepts any version.
    min_version: []const u8,
    /// Features of the dependency to activate.
    features: [][]const u8 = &.{},
    /// Whether the dependency's own `default_features` also activate.
    default_features: bool,

    pub fn eql(self: PackDependency, other: PackDependency) bool {
        return std.mem.eql(u8, self.library_id, other.library_id) and
            std.mem.eql(u8, self.min_version, other.min_version) and
            eqlStrSlice(self.features, other.features) and
            self.default_features == other.default_features;
    }

    pub fn deinit(self: *PackDependency, allocator: Allocator) void {
        allocator.free(self.library_id);
        allocator.free(self.min_version);
        freeStrSlice(allocator, self.features);
        self.* = undefined;
    }
};

/// One named feature: the source paths it gates, the packs it pulls in, and
/// the sibling features it enables.
pub const FeatureDef = struct {
    name: []const u8 = "",
    /// `rel_path` prefix patterns, matched like `[[source]]` includes, for the
    /// files this feature gates.
    sources: [][]const u8 = &.{},
    /// `library_id`s pulled in only while this feature is active.
    deps: [][]const u8 = &.{},
    /// Sibling features this one transitively activates.
    requires: [][]const u8 = &.{},

    pub fn eql(self: FeatureDef, other: FeatureDef) bool {
        return std.mem.eql(u8, self.name, other.name) and
            eqlStrSlice(self.sources, other.sources) and
            eqlStrSlice(self.deps, other.deps) and
            eqlStrSlice(self.requires, other.requires);
    }

    pub fn deinit(self: *FeatureDef, allocator: Allocator) void {
        allocator.free(self.name);
        freeStrSlice(allocator, self.sources);
        freeStrSlice(allocator, self.deps);
        freeStrSlice(allocator, self.requires);
        self.* = undefined;
    }
};

/// Symbol index for the pack. One entry per public declaration.
pub const SymbolIndex = struct {
    entries: []SymbolRecord = &.{},

    pub const empty: SymbolIndex = .{ .entries = &.{} };

    pub fn eql(self: SymbolIndex, other: SymbolIndex) bool {
        if (self.entries.len != other.entries.len) return false;
        for (self.entries, other.entries) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *SymbolIndex, allocator: Allocator) void {
        for (self.entries) |*e| e.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Kind of a declared symbol. Mirrors `stdlib.SymbolKind`, duplicated here so
/// the schema does not depend on the stdlib module.
pub const SymbolKind = enum(u8) {
    Function = 0,
    Property = 1,
    Class = 2,
    Interface = 3,
    Object = 4,
    TypeAlias = 5,
};

/// Kotlin modifier bits attached to a symbol. Bit positions match
/// `stdlib.Modifiers`, so the two round-trip without a translation table.
pub const ModifierBits = packed struct(u32) {
    PUBLIC: bool = false,
    INTERNAL: bool = false,
    PROTECTED: bool = false,
    PRIVATE: bool = false,
    OPEN: bool = false,
    ABSTRACT: bool = false,
    FINAL: bool = false,
    SEALED: bool = false,
    INLINE: bool = false,
    INFIX: bool = false,
    OPERATOR: bool = false,
    TAILREC: bool = false,
    EXPECT: bool = false,
    ACTUAL: bool = false,
    EXTERNAL: bool = false,
    SUSPEND: bool = false,
    OVERRIDE: bool = false,
    DATA: bool = false,
    VALUE: bool = false,
    ENUM: bool = false,
    ANNOTATION: bool = false,
    COMPANION: bool = false,
    CONST: bool = false,
    _padding: u9 = 0,

    pub const empty: ModifierBits = .{};

    pub fn bits(self: ModifierBits) u32 {
        return @bitCast(self);
    }

    pub fn fromBits(value: u32) ModifierBits {
        return @bitCast(value);
    }

    pub fn eql(self: ModifierBits, other: ModifierBits) bool {
        return self.bits() == other.bits();
    }
};

/// One declared symbol, round-tripping `stdlib.SymbolEntry` without
/// information loss.
pub const SymbolRecord = struct {
    /// Fully qualified name (`kotlin.collections.listOf`).
    fqn: []const u8,
    /// Package path (`kotlin.collections`).
    package: []const u8,
    /// Simple name (`listOf`).
    name: []const u8,
    kind: SymbolKind,
    /// Extension receiver type as text, if any.
    receiver: ?[]const u8,
    /// Raw textual signature (trimmed source line).
    signature: []const u8,
    /// Parameter names in declaration order; empty for non-functions.
    param_names: [][]const u8 = &.{},
    modifiers: ModifierBits,
    /// Upstream source location, for go-to-definition.
    source: ?SourceLoc,

    pub fn eql(self: SymbolRecord, other: SymbolRecord) bool {
        if (!std.mem.eql(u8, self.fqn, other.fqn)) return false;
        if (!std.mem.eql(u8, self.package, other.package)) return false;
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (self.kind != other.kind) return false;
        if (!eqlOptStr(self.receiver, other.receiver)) return false;
        if (!std.mem.eql(u8, self.signature, other.signature)) return false;
        if (!eqlStrSlice(self.param_names, other.param_names)) return false;
        if (!self.modifiers.eql(other.modifiers)) return false;
        if ((self.source == null) != (other.source == null)) return false;
        if (self.source) |s| {
            if (!s.eql(other.source.?)) return false;
        }
        return true;
    }

    pub fn deinit(self: *SymbolRecord, allocator: Allocator) void {
        allocator.free(self.fqn);
        allocator.free(self.package);
        allocator.free(self.name);
        if (self.receiver) |r| allocator.free(r);
        allocator.free(self.signature);
        freeStrSlice(allocator, self.param_names);
        if (self.source) |*s| s.deinit(allocator);
        self.* = undefined;
    }
};

pub const SourceLoc = struct {
    path: []const u8,
    line: u32,
    column: u32,

    pub fn eql(self: SourceLoc, other: SourceLoc) bool {
        return std.mem.eql(u8, self.path, other.path) and
            self.line == other.line and
            self.column == other.column;
    }

    pub fn deinit(self: *SourceLoc, allocator: Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Map of FQN -> native binding for the host to install at load time.
pub const BindingManifest = struct {
    bindings: []Binding = &.{},

    pub const empty: BindingManifest = .{ .bindings = &.{} };

    pub fn eql(self: BindingManifest, other: BindingManifest) bool {
        if (self.bindings.len != other.bindings.len) return false;
        for (self.bindings, other.bindings) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *BindingManifest, allocator: Allocator) void {
        for (self.bindings) |*b| b.deinit(allocator);
        allocator.free(self.bindings);
        self.* = undefined;
    }
};

pub const Binding = struct {
    /// Kotlin FQN this binding satisfies (`kotlin.io.println`).
    fqn: []const u8,
    kind: BindingKind,
    /// Key the loader resolves to a host function pointer. Conventionally the
    /// FQN, kept as a separate field so one host function can serve several
    /// Kotlin names.
    host_symbol: []const u8,
    /// True when the binding always wins over an interpreted body for this
    /// FQN; false when it is a fast path and the interpreter may still fall
    /// through to a Kotlin implementation shipped in the `ast` section.
    overrides_interpreter: bool,
    purity: Purity,
    min_arity: u8,
    max_arity: u8,
    /// True when this binding is the platform `actual` for an `expect`
    /// declaration in the library's common sources. The interpreter treats an
    /// `expect`-shaped declaration as non-instantiable until such a binding
    /// is installed.
    platform_actual: bool = false,

    pub fn eql(self: Binding, other: Binding) bool {
        return std.mem.eql(u8, self.fqn, other.fqn) and
            self.kind == other.kind and
            std.mem.eql(u8, self.host_symbol, other.host_symbol) and
            self.overrides_interpreter == other.overrides_interpreter and
            self.purity == other.purity and
            self.min_arity == other.min_arity and
            self.max_arity == other.max_arity and
            self.platform_actual == other.platform_actual;
    }

    pub fn deinit(self: *Binding, allocator: Allocator) void {
        allocator.free(self.fqn);
        allocator.free(self.host_symbol);
        self.* = undefined;
    }
};

pub const BindingKind = enum(u8) {
    Function = 0,
    Property = 1,
    ClassCtor = 2,
    EnumEntry = 3,
};

pub const Purity = enum(u8) {
    Pure = 0,
    Effectful = 1,
    Suspend = 2,
};

/// Kotlin source files shipped inside the pack. The interpreter parses these
/// at install time and registers the resulting declarations as if the user
/// had written them.
pub const SourceBundle = struct {
    files: []SourceFile = &.{},

    pub const empty: SourceBundle = .{ .files = &.{} };

    pub fn eql(self: SourceBundle, other: SourceBundle) bool {
        if (self.files.len != other.files.len) return false;
        for (self.files, other.files) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *SourceBundle, allocator: Allocator) void {
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub const SourceFile = struct {
    /// Path relative to the library root, such as
    /// `common/src/main/kotlin/kotlinx/coroutines/Job.kt`. Keys diagnostic
    /// spans and go-to-definition.
    rel_path: []const u8,
    /// UTF-8 source bytes.
    bytes: []const u8,

    pub fn eql(self: SourceFile, other: SourceFile) bool {
        return std.mem.eql(u8, self.rel_path, other.rel_path) and
            std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn deinit(self: *SourceFile, allocator: Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Per-source package headers and import paths, precomputed at pack build
/// from the parsed ASTs. A loader that needs only the import graph and
/// package set skips lexing and parsing the carried sources entirely.
pub const ImportsBundle = struct {
    files: []ImportsFile = &.{},

    pub const empty: ImportsBundle = .{ .files = &.{} };

    pub fn eql(self: ImportsBundle, other: ImportsBundle) bool {
        if (self.files.len != other.files.len) return false;
        for (self.files, other.files) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *ImportsBundle, allocator: Allocator) void {
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub const ImportsFile = struct {
    /// Path relative to the library root; matches the `sources` entry so
    /// feature gating applies identically to both sections.
    rel_path: []const u8,
    /// Dotted package header; empty when the file declares none.
    pkg: []const u8,
    /// Dotted import paths in declaration order, aliases dropped and wildcard
    /// stars omitted: the strings a source parse contributes to the loader's
    /// import fixed point.
    imports: [][]const u8,

    pub fn eql(self: ImportsFile, other: ImportsFile) bool {
        return std.mem.eql(u8, self.rel_path, other.rel_path) and
            std.mem.eql(u8, self.pkg, other.pkg) and
            eqlStrSlice(self.imports, other.imports);
    }

    pub fn deinit(self: *ImportsFile, allocator: Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.pkg);
        freeStrSlice(allocator, self.imports);
        self.* = undefined;
    }
};

/// Frozen front-end output. When present, the interpreter skips the
/// install-time parse and feeds the carried `KotlinFile` straight to
/// `register_pack_classes`; `sources` still carries the raw bytes for
/// diagnostic spans and re-parse fallback.
pub const AstBundle = struct {
    files: []AstFile = &.{},

    pub const empty: AstBundle = .{ .files = &.{} };

    pub fn deinit(self: *AstBundle, allocator: Allocator) void {
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub const AstFile = struct {
    rel_path: []const u8,
    kotlin_file: ast.KotlinFile,

    pub fn deinit(self: *AstFile, allocator: Allocator) void {
        allocator.free(self.rel_path);
        self.* = undefined;
    }
};

/// Frozen type-check output, keyed by source span so the loader rebuilds the
/// interpreter's `expr_types` map without re-running the type checker. Only
/// the per-expression `Type` map is carried.
pub const TypeckBundle = struct {
    /// `(Span, Type)` pairs: a sorted slice rather than a hash map, so
    /// round-trips stay byte-identical.
    entries: []TypeckEntry = &.{},

    pub const empty: TypeckBundle = .{ .entries = &.{} };

    pub fn deinit(self: *TypeckBundle, allocator: Allocator) void {
        for (self.entries) |*e| e.ty.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const TypeckEntry = struct {
    span: span.Span,
    ty: types.Type,
};

/// Encode a value into bytes ready for the pack writer. The byte-level
/// serializer lives in `write.zig`.
pub fn encode(
    comptime T: type,
    allocator: Allocator,
    value: *const T,
    result: *PackError,
) Allocator.Error!?std.ArrayList(u8) {
    const write = @import("write.zig");
    return write.encode(T, allocator, value, result);
}

/// Decode a section payload into a `T`. The byte-level deserializer lives in
/// `read.zig`.
pub fn decode(
    comptime T: type,
    allocator: Allocator,
    bytes: []const u8,
    result: *PackError,
) Allocator.Error!?T {
    const read = @import("read.zig");
    return read.decode(T, allocator, bytes, result);
}

fn eqlOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    return std.mem.eql(u8, a.?, b.?);
}

fn eqlStrSlice(a: [][]const u8, b: [][]const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn freeStrSlice(allocator: Allocator, slice: [][]const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

test "ModifierBits bit positions match the expected layout" {
    try std.testing.expectEqual(@as(u32, 1 << 0), (ModifierBits{ .PUBLIC = true }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 3), (ModifierBits{ .PRIVATE = true }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 15), (ModifierBits{ .SUSPEND = true }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 22), (ModifierBits{ .CONST = true }).bits());
    const combined = ModifierBits{ .PUBLIC = true, .OPEN = true };
    try std.testing.expectEqual(@as(u32, (1 << 0) | (1 << 4)), combined.bits());
    try std.testing.expect(ModifierBits.fromBits(1 << 0).PUBLIC);
}

test "repr(u8) discriminants are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(SymbolKind.Function));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(SymbolKind.TypeAlias));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(BindingKind.EnumEntry));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Purity.Suspend));
}

test "symbol record structural equality" {
    const a = SymbolRecord{
        .fqn = "kotlin.io.println",
        .package = "kotlin.io",
        .name = "println",
        .kind = .Function,
        .receiver = null,
        .signature = "public fun println(message: Any?): Unit",
        .param_names = @constCast(&[_][]const u8{"message"}),
        .modifiers = .{ .PUBLIC = true },
        .source = .{ .path = "Console.kt", .line = 42, .column = 1 },
    };
    const b = a;
    try std.testing.expect(a.eql(b));
    var c = a;
    c.kind = .Property;
    try std.testing.expect(!a.eql(c));
}

test "manifest round trip through pack" {
    const pack = @import("pack.zig");
    const alloc = std.testing.allocator;
    var err: PackError = undefined;

    var implicit = [_][]const u8{ "kotlin", "kotlin.collections" };
    const manifest = PackManifest{
        .library_id = "stdlib",
        .library_version = "0.1.0",
        .abi_version = 1,
        .implicit_packages = implicit[0..],
        .dependencies = &.{},
        .default_features = &.{},
        .features = &.{},
    };

    var bytes = (try encode(PackManifest, alloc, &manifest, &err)).?;
    defer bytes.deinit(alloc);

    var w = pack.PackWriter.init(alloc);
    defer w.deinit();
    _ = try w.addRaw(pack.section_names.MANIFEST, bytes.items);
    var packed_bytes = (try w.finish(&err)).?;
    defer packed_bytes.deinit(alloc);

    const owned = try alloc.dupe(u8, packed_bytes.items);
    var reader = (try pack.PackReader.fromBytes(alloc, owned, &err)).?;
    defer reader.deinit();
    const payload = (try reader.readSection(pack.section_names.MANIFEST, &err)).?;

    var decoded = (try decode(PackManifest, alloc, payload.slice(), &err)).?;
    defer decoded.deinit(alloc);
    try std.testing.expect(decoded.eql(manifest));
}

test "symbol record round trip" {
    const alloc = std.testing.allocator;
    var err: PackError = undefined;

    var params = [_][]const u8{"message"};
    const index = SymbolIndex{
        .entries = @constCast(&[_]SymbolRecord{.{
            .fqn = "kotlin.io.println",
            .package = "kotlin.io",
            .name = "println",
            .kind = .Function,
            .receiver = null,
            .signature = "public fun println(message: Any?): Unit",
            .param_names = params[0..],
            .modifiers = .{ .PUBLIC = true },
            .source = .{
                .path = "kotlin/libraries/stdlib/src/kotlin/io/Console.kt",
                .line = 42,
                .column = 1,
            },
        }}),
    };

    var bytes = (try encode(SymbolIndex, alloc, &index, &err)).?;
    defer bytes.deinit(alloc);
    var decoded = (try decode(SymbolIndex, alloc, bytes.items, &err)).?;
    defer decoded.deinit(alloc);
    try std.testing.expect(decoded.eql(index));
}

test "binding manifest round trip" {
    const alloc = std.testing.allocator;
    var err: PackError = undefined;

    const manifest = BindingManifest{
        .bindings = @constCast(&[_]Binding{.{
            .fqn = "kotlin.io.println",
            .kind = .Function,
            .host_symbol = "kotlin.io.println",
            .overrides_interpreter = true,
            .purity = .Effectful,
            .min_arity = 0,
            .max_arity = 1,
            .platform_actual = false,
        }}),
    };

    var bytes = (try encode(BindingManifest, alloc, &manifest, &err)).?;
    defer bytes.deinit(alloc);
    var decoded = (try decode(BindingManifest, alloc, bytes.items, &err)).?;
    defer decoded.deinit(alloc);
    try std.testing.expect(decoded.eql(manifest));
}
