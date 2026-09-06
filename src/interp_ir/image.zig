//! Baked stdlib image: serialize a lowered `StdlibBase` to bytes and load
//! it back without re-running the lowering driver.
//!
//! The wire format is the pack codec's postcard style (varints,
//! length-prefixed sequences, in-order struct fields) extended with a
//! shared-graph protocol so the snapshot's pointer structure survives a
//! round trip:
//!
//! - Every slice is a define/backref: the first encode of a given
//!   `(address, length)` writes its elements inline and registers it; a
//!   later encode of the same slice writes a backref. The decoder keeps a
//!   registry in define order, so a backref resolves to the exact slice
//!   the first define produced and sharing (lifted classes share member
//!   slices with their declaring class) is preserved.
//! - A closed set of AST node types is *watched*: every watched value is
//!   registered (in traversal order) as it is encoded/decoded, and a
//!   pointer to a watched node encodes as a reference to that registry.
//!   This is what lets `Inst.BuildObject.ast`, `ClassDef.methods[].decl`,
//!   `StdlibBase.inline_ids` and friends point INTO the decoded
//!   `lifted_decls` tree, interior addresses included, exactly as they do
//!   in a freshly lowered base.
//! - `[]const u8` decodes as a borrow of the image buffer, so strings cost
//!   nothing to materialize. The buffer must outlive the loaded base; the
//!   CLI keeps it on the same process-lifetime arena as the base itself.
//!
//! What is serialized: the SourceMap files, the post-lift AST decls, the
//! lowered `ir.Module` (registry flattened to index/pair tables), its
//! owner-scoped member groups and linked numeric method dispatch table,
//! every `BuiltModule` side table, the runtime `ClassDef` graph (ObjRef
//! edges as def-table indexes), and the `StdlibBase` gate sets. What is
//! rebuilt at load: hash-map spines, `func_name_index`, ObjRef cells, and
//! the run-mutable `ClassDef` cells (companion/object singletons, captured
//! envs) that `cloneBuiltForRun` resets per run anyway.
//!
//! `bake` refuses (returns null) when the base holds anything outside the
//! serializable build-time surface (e.g. a SAM-converted method value);
//! callers then simply keep the unbaked path.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const FF = runtime.forest.ForestField;
const span = @import("span");

const build = @import("build.zig");
const prune = @import("prune.zig");

const Allocator = std.mem.Allocator;
const SourceMap = span.SourceMap;
const Span = span.Span;
const FileId = span.FileId;
const Module = ir.Module;
const FuncId = ir.FuncId;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Env = runtime.Env;
const Value = runtime.Value;
const TypeShape = runtime.TypeShape;
const StdlibBase = build.StdlibBase;
const BuiltModule = build.BuiltModule;

/// Bump on ANY change to the encoded layout or to the types it reaches
/// (AST, IR, ClassDef shapes). A version mismatch refuses to load and the
/// caller rebakes.
pub const FORMAT_VERSION: u32 = 56;

pub const MAGIC = "KIMG";
const TRAILER = "GMIK";

// -------------------------------------------------------------------------
// Watched AST node types: externally referenced by pointer from the IR,
// the ClassDef graph, or the base's inline-fn registry.
// -------------------------------------------------------------------------

const watched_types = [_]type{
    ast.Expr,
    ast.Block,
    ast.Function,
    ast.Class,
    ast.Property,
    ast.Accessor,
    ast.SecondaryCtor,
};

fn isWatched(comptime T: type) bool {
    inline for (watched_types) |W| {
        if (T == W) return true;
    }
    return false;
}

/// A `forest.ForestField(T)` union — the codec encodes it as a forest reference
/// (or an inline fallback) instead of via the generic union path.
fn isForestField(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "is_forest_field");
}

/// Bake-time map from a forest AST node address to its `(decl, ord)` reference,
/// built while emitting the per-decl sections. Set for the duration of the final
/// `ImageRoot` encode so a `ForestField.ptr` into the forest encodes lazily.
/// Null outside a bake (and in the self-contained per-decl/body encodes, which
/// must stay inline).
var bake_forest_map: ?*const std.AutoHashMap(usize, runtime.forest.ForestRef) = null;

/// Decl-index base of the forest slot reserved for the image currently being
/// loaded. Refs are baked image-local; `decodeForestField` adds this while the
/// root payload decodes (zero outside a load — the self-contained per-decl /
/// per-func sections carry no lazy refs, so runtime decodes are unaffected).
var load_forest_rebase: u32 = 0;

/// Encode a `ForestField`: tag 0 + `(decl, ord)` when the pointer resolves to a
/// forest node (the lazy path), else tag 1 + the node encoded inline (synthetic
/// nodes outside `lifted_decls`, and any encode with no forest map installed —
/// e.g. the per-decl sections themselves). `.ref` re-encodes verbatim.
fn encodeForestField(comptime T: type, e: *Encoder, value: *const T) Allocator.Error!void {
    const Child = T.Child;
    switch (value.*) {
        .ref => |r| {
            try e.varint(0);
            try e.varint(r.decl);
            try e.varint(r.ord);
        },
        .ptr => |p| {
            if (bake_forest_map) |map| {
                if (map.get(@intFromPtr(p))) |r| {
                    try e.varint(0);
                    try e.varint(r.decl);
                    try e.varint(r.ord);
                    return;
                }
            }
            try e.varint(1);
            try encodeValue(Child, e, p);
        },
    }
}

fn decodeForestField(comptime T: type, d: *Decoder, out: *T) DecodeError!void {
    const Child = T.Child;
    const tag = try d.varint();
    if (tag == 0) {
        const decl: u32 = @intCast(try d.varint());
        const ord: u32 = @intCast(try d.varint());
        out.* = .{ .ref = .{ .decl = decl + load_forest_rebase, .ord = ord } };
    } else {
        const ptr = try d.a.create(Child);
        try decodeInto(Child, d, ptr);
        out.* = .{ .ptr = ptr };
    }
}

// -------------------------------------------------------------------------
// Encoder
// -------------------------------------------------------------------------

const NodeKey = struct { addr: usize, ty: usize };
const SliceKey = struct { addr: usize, len: usize, ty: usize };

fn typeId(comptime T: type) usize {
    return @intFromPtr(@typeName(T).ptr);
}

const Encoder = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    nodes: std.AutoHashMap(NodeKey, u32),
    node_count: u32 = 0,
    slices: std.AutoHashMap(SliceKey, u32),
    slice_count: u32 = 0,

    fn init(gpa: Allocator) Encoder {
        return .{
            .gpa = gpa,
            .nodes = std.AutoHashMap(NodeKey, u32).init(gpa),
            .slices = std.AutoHashMap(SliceKey, u32).init(gpa),
        };
    }

    fn deinit(self: *Encoder) void {
        self.out.deinit(self.gpa);
        self.nodes.deinit();
        self.slices.deinit();
    }

    /// Clear the shared-graph registries (keeping the output buffer) so the
    /// next value encodes self-contained — every node/slice defined inline,
    /// no backref into anything written before. Used to bake each deferred
    /// body as an independently decodable unit appended to one buffer.
    fn resetRegistry(self: *Encoder) void {
        self.nodes.clearRetainingCapacity();
        self.slices.clearRetainingCapacity();
        self.node_count = 0;
        self.slice_count = 0;
    }

    fn byte(self: *Encoder, b: u8) Allocator.Error!void {
        try self.out.append(self.gpa, b);
    }

    fn bytes(self: *Encoder, b: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.gpa, b);
    }

    fn varint(self: *Encoder, value: u64) Allocator.Error!void {
        var v = value;
        while (true) {
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) {
                try self.byte(b);
                break;
            }
            try self.byte(b | 0x80);
        }
    }
};

fn encodeInt(comptime T: type, e: *Encoder, value: T) Allocator.Error!void {
    const info = @typeInfo(T).int;
    if (info.bits <= 8) {
        try e.byte(@bitCast(value));
        return;
    }
    if (info.signedness == .signed) {
        const wide: i64 = value;
        const zz: u64 = @bitCast((wide << 1) ^ (wide >> 63));
        try e.varint(zz);
    } else {
        try e.varint(@intCast(value));
    }
}

/// Encode one value, traversing by const pointer so registered addresses
/// are the original object addresses (interior pointers included).
fn encodeValue(comptime T: type, e: *Encoder, value: *const T) Allocator.Error!void {
    if (comptime isForestField(T)) {
        try encodeForestField(T, e, value);
        return;
    }
    if (comptime isWatched(T)) {
        const key = NodeKey{ .addr = @intFromPtr(value), .ty = typeId(T) };
        const gop = try e.nodes.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = e.node_count;
        e.node_count += 1;
    }
    const info = @typeInfo(T);
    switch (info) {
        .bool => try e.byte(if (value.*) 1 else 0),
        .int => try encodeInt(T, e, value.*),
        // Floats are written as their IEEE-754 bit pattern in little-endian
        // byte order, so an image baked on one host is byte-consumable on any
        // other (all supported targets are little-endian; this removes the
        // native-order dependence outright).
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const raw: Bits = @bitCast(value.*);
            try e.bytes(&std.mem.toBytes(std.mem.nativeToLittle(Bits, raw)));
        },
        .@"enum" => |en| try e.varint(@as(u64, @intCast(@as(en.tag_type, @intFromEnum(value.*))))),
        .optional => |o| {
            if (value.*) |*payload| {
                try e.byte(1);
                try encodeValue(o.child, e, payload);
            } else {
                try e.byte(0);
            }
        },
        .pointer => |p| switch (p.size) {
            .one => {
                if (comptime isWatched(p.child)) {
                    const key = NodeKey{ .addr = @intFromPtr(value.*), .ty = typeId(p.child) };
                    if (e.nodes.get(key)) |id| {
                        try e.varint(@as(u64, id) + 1);
                    } else {
                        try e.varint(0);
                        try encodeValue(p.child, e, value.*);
                    }
                } else {
                    try encodeValue(p.child, e, value.*);
                }
            },
            .slice => {
                const s = value.*;
                if (s.len == 0) {
                    // Tag 1: the empty slice — no registry entry.
                    try e.varint(1);
                    return;
                }
                const key = SliceKey{ .addr = @intFromPtr(s.ptr), .len = s.len, .ty = typeId(p.child) };
                if (e.slices.get(key)) |id| {
                    try e.varint(@as(u64, id) + 2);
                    return;
                }
                try e.varint(0);
                try e.slices.put(key, e.slice_count);
                e.slice_count += 1;
                try e.varint(s.len);
                if (p.child == u8) {
                    try e.bytes(s);
                } else {
                    for (s) |*elem| try encodeValue(p.child, e, elem);
                }
            },
            else => @compileError("unsupported pointer kind in image encode: " ++ @typeName(T)),
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                try encodeInt(s.backing_integer.?, e, @bitCast(value.*));
            } else {
                inline for (s.fields) |f| {
                    try encodeValue(f.type, e, &@field(value.*, f.name));
                }
            }
        },
        .@"union" => |u| {
            const Tag = std.meta.Tag(T);
            const tag: Tag = value.*;
            const tag_int = @intFromEnum(tag);
            try e.varint(@intCast(tag_int));
            inline for (u.fields, 0..) |f, idx| {
                if (idx == tag_int) {
                    if (f.type != void) {
                        try encodeValue(f.type, e, &@field(value.*, f.name));
                    }
                }
            }
        },
        .void => {},
        else => @compileError("unsupported type in image encode: " ++ @typeName(T)),
    }
}

// -------------------------------------------------------------------------
// Decoder
// -------------------------------------------------------------------------

const DecodeError = error{ OutOfMemory, Malformed };

const SliceEntry = struct { addr: usize, len: usize };

const Decoder = struct {
    a: Allocator,
    buf: []const u8,
    pos: usize = 0,
    nodes: std.ArrayList(usize) = .empty,
    slices: std.ArrayList(SliceEntry) = .empty,

    fn take(self: *Decoder, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Malformed;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn byte(self: *Decoder) DecodeError!u8 {
        return (try self.take(1))[0];
    }

    fn varint(self: *Decoder) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            if (shift >= 63) return error.Malformed;
            shift += 7;
        }
        return result;
    }
};

fn decodeInt(comptime T: type, d: *Decoder) DecodeError!T {
    const info = @typeInfo(T).int;
    if (info.bits <= 8) {
        return @bitCast(try d.byte());
    }
    if (info.signedness == .signed) {
        const zz = try d.varint();
        const u: u64 = zz;
        const decoded: i64 = @bitCast((u >> 1) ^ (~(u & 1) +% 1));
        return std.math.cast(T, decoded) orelse error.Malformed;
    }
    const v = try d.varint();
    return std.math.cast(T, v) orelse error.Malformed;
}

fn enumFromIntAny(comptime T: type, raw: anytype) DecodeError!T {
    const en = @typeInfo(T).@"enum";
    const tag = std.math.cast(en.tag_type, raw) orelse return error.Malformed;
    if (en.is_exhaustive) {
        return std.enums.fromInt(T, tag) orelse error.Malformed;
    }
    return @enumFromInt(tag);
}

var decode_stats: std.StringHashMapUnmanaged(struct { bytes: u64, count: u64 }) = .empty;
var decode_stats_on: bool = false;
fn decStat(comptime T: type, n: usize) void {
    if (!decode_stats_on) return;
    const key = @typeName(T);
    const gop = decode_stats.getOrPut(std.heap.page_allocator, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ .bytes = 0, .count = 0 };
    gop.value_ptr.bytes += @as(u64, @sizeOf(T)) * n;
    gop.value_ptr.count += n;
}
pub fn dumpDecodeStats() void {
    if (!decode_stats_on) return;
    const E = struct { name: []const u8, bytes: u64, count: u64 };
    var list: std.ArrayListUnmanaged(E) = .empty;
    var it = decode_stats.iterator();
    while (it.next()) |kv| list.append(std.heap.page_allocator, .{ .name = kv.key_ptr.*, .bytes = kv.value_ptr.bytes, .count = kv.value_ptr.count }) catch {};
    std.mem.sort(E, list.items, {}, struct {
        fn lt(_: void, a: E, b: E) bool {
            return a.bytes > b.bytes;
        }
    }.lt);
    var n: usize = 0;
    for (list.items) |e| {
        if (n >= 25) break;
        n += 1;
        std.debug.print("[decode-stats] {d: >9} B  {d: >7} x  {s}\n", .{ e.bytes, e.count, e.name });
    }
}

/// Decode one value in place. Decoding writes through `out` so the final
/// resting address of every watched node / defined slice is registered,
/// mirroring the encoder's traversal exactly.
fn decodeInto(comptime T: type, d: *Decoder, out: *T) DecodeError!void {
    if (comptime isForestField(T)) {
        try decodeForestField(T, d, out);
        return;
    }
    if (comptime isWatched(T)) {
        try d.nodes.append(d.a, @intFromPtr(out));
    }
    const info = @typeInfo(T);
    switch (info) {
        .bool => out.* = (try d.byte()) != 0,
        .int => out.* = try decodeInt(T, d),
        .float => {
            // Mirrors the encoder: IEEE-754 bit pattern, little-endian.
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const s = try d.take(@sizeOf(T));
            out.* = @bitCast(std.mem.littleToNative(Bits, std.mem.bytesToValue(Bits, s)));
        },
        .@"enum" => out.* = try enumFromIntAny(T, try d.varint()),
        .optional => |o| {
            const tag = try d.byte();
            if (tag == 0) {
                out.* = null;
            } else switch (@typeInfo(o.child)) {
                // Optional pointers/slices pack `null` into the pointer
                // bits: there is no separate tag to pre-set, so writing an
                // undefined payload and unwrapping would read undefined.
                // Decode into a temporary and assign whole. (Pointer
                // optionals never hold watched VALUES inline -- pointees
                // are allocated and registered independently -- so the
                // temporary costs no identity.)
                .pointer => {
                    var tmp: o.child = undefined;
                    try decodeInto(o.child, d, &tmp);
                    out.* = tmp;
                },
                // Non-pointer optionals carry a separate tag; setting a
                // non-null wrapper gives `&out.*.?` a stable payload
                // address, which watched-node registration needs (e.g.
                // `ast.Property.getter: ?Accessor` is referenced by
                // interior pointer from `ClassDef.body_properties`).
                else => {
                    out.* = @as(o.child, undefined);
                    try decodeInto(o.child, d, &out.*.?);
                },
            }
        },
        .pointer => |p| switch (p.size) {
            .one => {
                const Child = p.child;
                if (comptime isWatched(Child)) {
                    const tag = try d.varint();
                    if (tag == 0) {
                        decStat(Child, 1);
                        const ptr = try d.a.create(Child);
                        try decodeInto(Child, d, ptr);
                        out.* = ptr;
                    } else {
                        const id: usize = @intCast(tag - 1);
                        if (id >= d.nodes.items.len) return error.Malformed;
                        out.* = @ptrFromInt(d.nodes.items[id]);
                    }
                } else {
                    decStat(Child, 1);
                    const ptr = try d.a.create(Child);
                    try decodeInto(Child, d, ptr);
                    out.* = ptr;
                }
            },
            .slice => {
                const tag = try d.varint();
                if (tag == 1) {
                    out.* = &.{};
                    return;
                }
                if (tag == 0) {
                    const len: usize = @intCast(try d.varint());
                    if (p.child == u8 and p.is_const) {
                        const s = try d.take(len);
                        try d.slices.append(d.a, .{ .addr = @intFromPtr(s.ptr), .len = len });
                        out.* = s;
                    } else {
                        decStat(p.child, len);
                        const arr = try d.a.alloc(p.child, len);
                        try d.slices.append(d.a, .{ .addr = @intFromPtr(arr.ptr), .len = len });
                        if (p.child == u8) {
                            @memcpy(arr, try d.take(len));
                        } else {
                            for (arr) |*elem| try decodeInto(p.child, d, elem);
                        }
                        out.* = arr;
                    }
                    return;
                }
                const id: usize = @intCast(tag - 2);
                if (id >= d.slices.items.len) return error.Malformed;
                const entry = d.slices.items[id];
                const many: [*]p.child = @ptrFromInt(entry.addr);
                out.* = many[0..entry.len];
            },
            else => @compileError("unsupported pointer kind in image decode: " ++ @typeName(T)),
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const raw = try decodeInt(s.backing_integer.?, d);
                out.* = @bitCast(raw);
            } else {
                inline for (s.fields) |f| {
                    try decodeInto(f.type, d, &@field(out.*, f.name));
                }
            }
        },
        .@"union" => |u| {
            const tag = try d.varint();
            var matched = false;
            inline for (u.fields, 0..) |f, idx| {
                if (idx == tag) {
                    matched = true;
                    if (f.type == void) {
                        out.* = @unionInit(T, f.name, {});
                    } else {
                        out.* = @unionInit(T, f.name, undefined);
                        try decodeInto(f.type, d, &@field(out.*, f.name));
                    }
                }
            }
            if (!matched) return error.Malformed;
        },
        .void => {},
        else => @compileError("unsupported type in image decode: " ++ @typeName(T)),
    }
}

// -------------------------------------------------------------------------
// Image schema: the StdlibBase flattened to codec-friendly tables.
// HashMap/ArrayList/ObjRef spines become index- or pair-keyed slices;
// everything else is the live type encoded as-is.
// -------------------------------------------------------------------------

fn KV(comptime K: type, comptime V: type) type {
    return struct { k: K, v: V };
}

const StrKV = KV([]const u8, []const u8);
const PairKey = struct { a: []const u8, b: []const u8 };
const PairFuncEntry = struct { a: []const u8, b: []const u8, func: FuncId };
const PairStrEntry = struct { a: []const u8, b: []const u8, v: []const u8 };
const PairU64Entry = struct { a: []const u8, b: []const u8, v: u64 };
const PairTypeEntry = struct { a: []const u8, b: []const u8, v: ir.TypeRef };
const NameTypeEntry = struct { name: []const u8, v: ir.TypeRef };
const NameFuncs = struct { name: []const u8, funcs: []const FuncId };
const NameOptFuncs = struct { name: []const u8, slots: []const ?FuncId };
/// A class name paired with the argument labels of its super-constructor call
/// (`: Base(objects = 2)` -> `[ "objects" ]`, positional args -> `null`). Kept
/// parallel to `parent_ctor_args` so an image-loaded class binds a named
/// super-constructor argument to the matching base parameter instead of
/// positionally (which would drop it onto an earlier defaulted parameter).
const NameArgNames = struct { name: []const u8, arg_names: []const ?[]const u8 };

const FileEntry = struct { path: []const u8, source: []const u8 };

const RegistryImage = struct {
    object_names: []const []const u8,
    companion_singletons: []StrKV,
    enclosing_class: []StrKV,
    func_type_params: []KV(FuncId, []const []const u8),
    func_type_param_bounds: []KV(FuncId, []const ir.ModuleRegistry.TypeParamBound),
    class_type_param_bounds: []KV([]const u8, []const ir.ModuleRegistry.TypeParamBound),
    top_level_delegated_props: []const []const u8,
    top_level_prop_getters: []KV([]const u8, FuncId),
    top_level_prop_setters: []KV([]const u8, FuncId),
    hierarchy_methods: []KV([]const u8, []const []const u8),
    class_member_names: []const []const u8,
    class_super_names: []KV([]const u8, []const []const u8),
    delegated_body_props: []PairKey,
    member_ext_owner_class: []KV(FuncId, []const u8),
    local_fn_defaults: []KV(FuncId, []const ?FuncId),
    abstract_member_defaults: []struct { a: []const u8, b: []const u8, slots: []const ?FuncId },
    type_aliases: []StrKV,
    type_alias_types: []KV([]const u8, ir.ModuleRegistry.TypeAliasShape),
    import_aliases: []struct {
        file: FileId,
        leaves: []struct { leaf: []const u8, paths: []ir.ModuleRegistry.ImportPath },
    },
    import_wildcards: []KV(FileId, []const []const u8),
    nested_object_aliases: []KV([]const u8, []StrKV),
    mangled_nested: []StrKV,
    class_const_inits: []struct { a: []const u8, b: []const u8, v: ir.Const },
    class_prop_type_heads: []PairStrEntry,
    class_prop_type_refs: []PairTypeEntry = &.{},
    top_level_prop_type_refs: []NameTypeEntry = &.{},
    ext_prop_type_heads: []PairStrEntry,
    iface_member_ext_recv: []PairStrEntry,
    iface_member_ctx_types: []PairStrEntry = &.{},
    abstract_member_arity: []PairU64Entry = &.{},
    private_fn_files: []KV(FuncId, FileId),
    file_packages: []KV(FileId, []const u8),
    file_modules: []KV(FileId, u32),
    top_level_const_vals: []KV([]const u8, ir.Const),
    member_method_fids: []KV([]const u8, FuncId),
    recv_fn_props: []PairStrEntry,
    private_shadow_props: []const []const u8,
    override_cell_props: []const []const u8,
    hierarchy_shadow_names: []struct { k: []const u8, names: []const []const u8, complete: bool },
};

const ModuleImage = struct {
    funcs: []ir.Func,
    classes: []ir.Class,
    consts: []ir.Const,
    top_level: []FuncId,
    class_index: []ir.ClassIndexEntry,
    func_index: []ir.FuncIndexEntry,
    package: ?[]const u8,
    tailrec_fn_names: []const []const u8,
    registry: RegistryImage,
    decl_user_params: []KV(u32, u32),
    decl_user_arity: []KV(u32, Module.DeclArity),
    decl_user_sig: []KV(u32, []ir.TypeRef),
    decl_sigs: []DeclSigLite,
    decl_span: []KV(u32, Span),
    member_decl_groups: []Module.MemberDeclGroup,
    method_dispatch: []Module.MethodDispatchEntry,
    /// Lazy IR: the self-contained `blocks` of AST-free functions, decoded on
    /// first execution. A deferred function carries its `offset + 1` into this
    /// section in `Func.deferred_offset` (its `blocks` is empty in the image).
    deferred_func_section: []const u8,
};

/// Executable-image projection of `Module.DeclSig`: runtime and extending
/// lowerers retain receiver identity, structural user parameters, arity,
/// ownership, callable kind, and executable-form flags.
pub const DeclSigLite = struct {
    fid: u32,
    enclosing_class: ?ir.ClassId,
    /// Receiver type head; empty = no declared receiver.
    recv_head: []const u8,
    recv_nullable: bool,
    required: u32,
    total: u32,
    has_vararg: bool,
    /// Full structural user-parameter signature. Virtual-slot linking on an
    /// image-loaded pack must make the same generic override associations as
    /// source lowering, so this is part of the executable image contract.
    sig: []const ir.TypeRef,
    kind: ir.FuncKind,
    visibility: ast.Visibility,
    is_inline: bool,
    is_suspend: bool,
    has_body: bool,
    /// Exact host ABI symbol; empty = ordinary source declaration.
    host_symbol: []const u8,
};

/// Build-time `Value` reachable from an enum entry or a primitive-zero
/// slot. Anything outside this set refuses the bake.
const ValueImage = union(enum) {
    Unit,
    Null,
    Bool: bool,
    Int: i32,
    Long: i64,
    Short: i16,
    Byte: i8,
    UInt: u32,
    ULong: u64,
    UShort: u16,
    UByte: u8,
    Double: f64,
    Float: f32,
    Char: u16,
    Str: []const u8,
    Instance: InstanceImage,
};

const InstanceImage = struct {
    class: u32,
    fields: []FieldImage,
    identity: u64,
};

const FieldImage = struct { name: []const u8, value: ValueImage };

const MethodImage = struct {
    name: []const u8,
    decl: FF(ast.Function),
    is_operator: bool,
    is_open: bool,
    is_override: bool,
    is_abstract: bool,
    delegate_field: ?[]const u8,
    ir_fn_id: ?u32,
};

const PropertyImage = struct {
    name: []const u8,
    mutable: bool,
    init: ?FF(ast.Expr),
    getter: ?FF(ast.Accessor),
    setter: ?FF(ast.Accessor),
    delegate: ?FF(ast.Expr),
    is_abstract: bool,
    is_lateinit: bool,
    primitive_zero: ?ValueImage,
    anchors: runtime.PropertyAnchors,
    has_backing: bool = true,
    type_head: ?[]const u8 = null,
};

const ClassParamImage = struct {
    property: ?bool,
    name: []const u8,
    default: ?FF(ast.Expr),
    declared_type: ?[]const u8,
    declared_shape: ?TypeShape,
    anchors: runtime.PropertyAnchors,
};

const DelegateImage = struct {
    interface_name: []const u8,
    interface: ?u32,
    expr: FF(ast.Expr),
    field_key: []const u8,
};

const ClassDefImage = struct {
    name: []const u8,
    fqn: []const u8,
    annotation_names: []const []const u8,
    annotation_records: []const runtime.AnnotationRecord,
    type_params: []const []const u8,
    primary_params: []ClassParamImage,
    methods: []MethodImage,
    body_properties: []PropertyImage,
    init_blocks: []const FF(ast.Block),
    init_block_property_positions: []usize,
    is_data: bool,
    is_value: bool,
    is_object: bool,
    is_enum: bool,
    is_annotation: bool,
    is_sealed: bool,
    supertype_names: []const []const u8,
    parent: ?u32,
    interfaces: []u32,
    is_interface: bool,
    is_fun_interface: bool,
    parent_ctor_args: []const FF(ast.Expr),
    is_open: bool,
    is_abstract: bool,
    is_inner: bool,
    is_anonymous: bool,
    secondary_ctors: []const FF(ast.SecondaryCtor),
    enum_entries: []struct { name: []const u8, value: ValueImage, annotation_records: []const runtime.AnnotationRecord },
    enclosing: ?u32,
    nested_classes: []struct { name: []const u8, idx: u32 },
    supertype_delegates: []DelegateImage,
    delegate_forwarders: []MethodImage,
};

const BuiltImage = struct {
    body_prop_inits: []PairFuncEntry,
    instance_prop_getters: []PairFuncEntry,
    instance_prop_setters: []PairFuncEntry,
    instance_prop_private: []PairFuncEntry = &.{},
    parent_ctor_args: []NameFuncs,
    parent_ctor_arg_names: []NameArgNames = &.{},
    init_blocks: []NameFuncs,
    top_level_props: []build.NameFunc,
    extension_props: []PairFuncEntry,
    nullable_ext_props: []build.StrFunc = &.{},
    extension_prop_setters: []PairFuncEntry,
    extension_prop_delegates: []PairFuncEntry = &.{},
    object_names: []const []const u8,
    companion_singletons: []StrKV,
    enum_entry_arg_inits: []build.EnumEntryArgInit,
    secondary_ctors: []struct { name: []const u8, entries: []build.SecondaryCtorEntry },
    primary_ctor_default_thunks: []NameOptFuncs,
    class_delegates: []struct { name: []const u8, entries: []build.StrFunc },
    func_defaults: []KV(u32, []const ?FuncId),
    enclosing_class: []StrKV,
    enum_entry_methods: []struct { a: []const u8, b: []const u8, module: ModuleImage, func: FuncId },
    enum_entry_synth_class: []PairStrEntry,
    func_type_params: []KV(u32, []const []const u8),
    top_level_delegated_props: []const []const u8,
    delegated_body_props: []PairKey,
    class_defs: []ClassDefImage,
    class_table: []KV([]const u8, u32),
};

const ImageRoot = struct {
    /// SourceMap files in FileId order; the base occupies [0..len).
    files: []FileEntry,
    /// Post-lift dependency decls. Encoded first: this walk defines the
    /// AST node registry every later pointer backrefs into.
    lifted_decls: []ast.Decl,
    module: ModuleImage,
    built: BuiltImage,
    decl_names: []const []const u8,
    root_decl_names: []const []const u8,
    packages: []const []const u8,
    param_type_names: []const []const u8,
    type_names: []const []const u8,
    inline_ids: []InlineIdImage,
    /// Simple-name -> base inline-fn forest refs, the lazy replacement for the
    /// load-time `collectInline` walk over `lifted_decls`.
    inline_by_name: []InlineNamesImage = &.{},
    /// Class simple-name -> base class forest ref (lazy `file_classes` seed).
    file_classes: []ClassRefImage = &.{},
    /// Base top-level property scope data (lazy `notePropScope` replay).
    top_props: []TopPropImage = &.{},
    fn_returns: []FnReturnImage = &.{},
    ext_returns: []ExtReturnImage = &.{},
    eager_calls: []EagerCallImage = &.{},
    enum_id_next: u64,
    /// CLI replay data: packages registered while loading the dependency
    /// sources and the host-binding FQNs installed alongside them.
    known_packages: []const []const u8,
    binding_fqns: []const []const u8,
    /// Self-contained encodings of deferred `inline` function bodies (marked in
    /// the skeleton by `span.DEFERRED_BODY_FILE`). Each entry is a
    /// `FunctionBody` encoded with a fresh node/slice registry, so it decodes
    /// standalone from its byte offset.
    deferred_bodies: []const u8,
    /// Per-decl self-contained encodings of `lifted_decls`, parallel to
    /// `lifted_decl_offsets` (decl `i` lives at `lifted_decl_offsets[i]`). Backs
    /// the lazy forest: a decl decodes on first runtime touch from this section
    /// instead of materialising the whole forest eagerly. Mirrors the post-
    /// deferral form of `lifted_decls` (inline bodies are markers).
    lifted_decl_section: []const u8 = &.{},
    lifted_decl_offsets: []const u32 = &.{},
    /// Per-func self-contained header encodings, decoded on first `funcById`.
    func_header_section: []const u8 = &.{},
    func_header_offsets: []const u32 = &.{},
    /// Ids of bodyless funcs (no blocks, not deferred) — the lazy link input.
    bodyless_func_ids: []const u32 = &.{},
    /// Distinct first fqn segments of the funcs (for packageHeadDeclared).
    func_fqn_heads: []const []const u8 = &.{},
    /// `main`'s FuncId + 1 for a whole-program image (`klio bundle`);
    /// 0 for a dependency base.
    main_func: u64 = 0,
};

const DEFERRED_MAGIC: u32 = span.DEFERRED_BODY_FILE;

/// Decode one deferred `FunctionBody` from `section` at `offset` (the value the
/// marker block's `span.start` carried), allocating into `a`. The body was
/// baked self-contained (fresh registry), so a fresh decoder reads it
/// standalone. Returns null on a malformed section (a corrupt image).
pub fn decodeDeferredBody(a: Allocator, section: []const u8, offset: u32) ?ast.FunctionBody {
    var d = Decoder{ .a = a, .buf = section, .pos = offset };
    var body: ast.FunctionBody = undefined;
    decodeInto(ast.FunctionBody, &d, &body) catch return null;
    return body;
}

/// Decode one whole top-level `ast.Decl` from the per-decl section at `offset`,
/// allocating into `a`. Each decl is baked self-contained (fresh registry — the
/// deferred-body pattern generalised to a whole decl), so a fresh decoder reads
/// it standalone. Backs the lazy forest: a decl decodes on first runtime touch
/// instead of materialising the whole forest at load. Returns null on a
/// malformed section.
pub fn decodeLiftedDecl(a: Allocator, section: []const u8, offset: u32) ?ast.Decl {
    var d = Decoder{ .a = a, .buf = section, .pos = offset };
    var decl: ast.Decl = undefined;
    decodeInto(ast.Decl, &d, &decl) catch return null;
    return decl;
}

/// Decode a whole top-level decl plus its node-ordinal registry (the
/// decode-order watched-node address table), for the lazy forest resolver. The
/// registry lets a `ForestRef{decl, ord}` in `built`/`module` resolve to the
/// exact node by ordinal. Allocates into `a` (the process-lifetime base arena).
pub fn decodeLiftedDeclReg(a: Allocator, section: []const u8, offset: u32) ?runtime.forest.DeclReg {
    var d = Decoder{ .a = a, .buf = section, .pos = offset };
    const decl = a.create(ast.Decl) catch return null;
    decodeInto(ast.Decl, &d, decl) catch return null;
    const nodes = d.nodes.toOwnedSlice(a) catch return null;
    return .{ .decl = decl, .nodes = nodes };
}

/// Process-global memo for `decodeFuncBlocks`. A deferred func body is immutable
/// and identical for a given `(section, offset)`, but the per-`Func`
/// `deferred_offset` flag that gates `ensureFuncBody` is reset whenever the
/// module's func table is rebuilt (a per-program `cloneForExtend`, a fresh Vm
/// for a `runBlocking` body), so a long-running server re-enters
/// `decodeFuncBlocks` for the same offset on every request and the decoded
/// blocks — allocated into the process-lifetime `deferred_func_arena` — pile up
/// unfreed. Memoising by `(section, offset)` decodes each body exactly once ever:
/// the cache is bounded by the reachable-func set, not by request count.
const BlockCacheKey = struct { section: [*]const u8, offset: u32, len: usize, sig: u64 };

/// Content fingerprint for a cache key: the section length plus the raw
/// bytes at the decode offset. A freed section's ADDRESS can be reused by a
/// later pack image (six installed packs made `"A".repeat` run another
/// pack's one-arg body via a stale (ptr, offset) hit); the fingerprint makes
/// such a reuse miss instead.
fn blockCacheSig(section: []const u8, offset: u32) u64 {
    var sig: u64 = 0;
    const avail = section.len -| offset;
    const n: usize = @min(8, avail);
    var buf = [_]u8{0} ** 8;
    if (n != 0) @memcpy(buf[0..n], section[offset..][0..n]);
    sig = std.mem.readInt(u64, &buf, .little);
    return sig;
}
var block_cache: std.AutoHashMapUnmanaged(BlockCacheKey, []ir.Block) = .empty;
var block_cache_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

inline fn blockCacheLock() void {
    while (block_cache_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}
inline fn blockCacheUnlock() void {
    block_cache_lock.store(false, .release);
}

/// Decode one func HEADER from the per-func section at `offset` (blocks stay
/// body-deferred). Self-contained (fresh registry), allocating into `a`.
pub fn decodeFuncHeader(a: Allocator, section: []const u8, offset: u32) ?ir.Func {
    var d = Decoder{ .a = a, .buf = section, .pos = offset };
    var f: ir.Func = undefined;
    decodeInto(ir.Func, &d, &f) catch return null;
    return f;
}

/// Decode a deferred function's `blocks` from the lazy-IR section at `offset`,
/// allocating into `a`. Self-contained (fresh registry), like the AST bodies.
/// Memoised: a repeated `(section, offset)` returns the first decode's blocks
/// rather than re-decoding into the never-freed `deferred_func_arena`.
pub fn decodeFuncBlocks(a: Allocator, section: []const u8, offset: u32) ?[]ir.Block {
    const key = BlockCacheKey{ .section = section.ptr, .offset = offset, .len = section.len, .sig = blockCacheSig(section, offset) };
    blockCacheLock();
    if (block_cache.get(key)) |cached| {
        blockCacheUnlock();
        return cached;
    }
    blockCacheUnlock();

    var d = Decoder{ .a = a, .buf = section, .pos = offset };
    var blocks: []ir.Block = undefined;
    decodeInto([]ir.Block, &d, &blocks) catch return null;

    blockCacheLock();
    defer blockCacheUnlock();
    // Re-check under the lock: a racing thread may have decoded the same key
    // while this one was decoding. Keep the winner; the loser's blocks are
    // arena-backed and reclaimed with the process.
    if (block_cache.get(key)) |cached| return cached;
    block_cache.put(std.heap.page_allocator, key, blocks) catch {};
    return blocks;
}

/// Whether a function's `blocks` must stay eager (cannot be deferred to the
/// self-contained lazy-IR section). Now always false: the AST-referencing insts
/// carry their AST self-contained — `RegisterClass.class`/`BuildObject.ast` are
/// `ForestField` (encode as a forest ref, or inline when no forest map is
/// installed, as in the deferred-body section), and `AstLambda.body_ast` is an
/// inline `ast.Block` value — so every body decodes standalone on first call.
fn funcRefsAst(func: *const ir.Func) bool {
    _ = func;
    return false;
}

const InlineIdImage = struct { id: u32, f: FF(ast.Function) };
const InlineNamesImage = struct { k: []const u8, v: []const runtime.forest.ForestRef };
const ClassRefImage = struct { k: []const u8, v: runtime.forest.ForestRef };
const TopPropImage = struct { name: []const u8, fqn: []const u8, package: []const u8, type_head: []const u8 = "" };

/// A top-level function's simple name and the class head it returns, baked
/// while the funcs are still decoded. The checker needs it to type a call's
/// result on a cached image, where the funcs themselves never materialise.
const FnReturnImage = struct { name: []const u8, head: []const u8 };

/// An extension's return class head under `<receiver head>\x00<name>`.
const ExtReturnImage = struct { key: []const u8, head: []const u8 };

/// A base call site and the FuncId the checker resolved it to, baked so a
/// cached run has the answer without re-parsing the base.
const EagerCallImage = struct { call: Span, fid: u32 };

// -------------------------------------------------------------------------
// Bake: StdlibBase -> bytes
// -------------------------------------------------------------------------

/// Extra CLI-side state replayed at load time.
pub const BakeExtras = struct {
    known_packages: []const []const u8 = &.{},
    binding_fqns: []const []const u8 = &.{},
};

/// Serialize `base` (and the SourceMap its spans resolve through) to an
/// owned byte buffer. Returns null when the base holds state outside the
/// serializable surface; callers keep the unbaked path. `gpa` is used for
/// scratch and the returned buffer.
pub fn bake(
    gpa: Allocator,
    base: *const StdlibBase,
    map: *const SourceMap,
    extras: BakeExtras,
) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = (try rootFromBase(a, base, map, extras)) orelse return null;

    // Defer `inline`, object-free function bodies into a self-contained side
    // section, replacing each in the skeleton with a marker block whose span
    // encodes its offset. The mutation is on the live base (shared with the
    // current run), so the bodies are restored after the encode.
    var body_enc = Encoder.init(gpa);
    defer body_enc.deinit();
    const Saved = struct { f: *ast.Function, body: ast.FunctionBody };
    var saved: std.ArrayList(Saved) = .empty;
    defer saved.deinit(a);
    {
        var deferrable: std.ArrayList(*ast.Function) = .empty;
        defer deferrable.deinit(a);
        try prune.collectDeferrable(a, root.lifted_decls, &deferrable);
        for (deferrable.items) |f| {
            const real = f.body.?;
            const offset: u32 = @intCast(body_enc.out.items.len);
            body_enc.resetRegistry();
            try encodeValue(ast.FunctionBody, &body_enc, &real);
            try saved.append(a, .{ .f = f, .body = real });
            f.body = .{ .Block = .{ .stmts = &.{}, .span = .{
                .file = @enumFromInt(DEFERRED_MAGIC),
                .start = offset,
                .end = 0,
            } } };
        }
    }
    root.deferred_bodies = body_enc.out.items;

    // Defer AST-free function `blocks` into a second self-contained section,
    // recording each function's `offset + 1` in `deferred_offset` and emptying
    // its live blocks. Restored after the encode, like the AST bodies.
    var fn_blk_enc = Encoder.init(gpa);
    defer fn_blk_enc.deinit();
    var fn_saved: std.ArrayList(struct { f: *ir.Func, blocks: []ir.Block }) = .empty;
    defer fn_saved.deinit(a);
    {
        for (root.module.funcs) |*f| {
            if (f.blocks.len == 0 or funcRefsAst(f)) continue;
            const offset: u32 = @intCast(fn_blk_enc.out.items.len);
            fn_blk_enc.resetRegistry();
            try encodeValue([]ir.Block, &fn_blk_enc, &f.blocks);
            try fn_saved.append(a, .{ .f = f, .blocks = f.blocks });
            f.deferred_offset = offset + 1;
            f.blocks = &.{};
        }
        root.module.deferred_func_section = fn_blk_enc.out.items;
    }

    // Per-func HEADER sections: each func encoded self-contained (blocks already
    // body-deferred, so the header carries only its deferred_offset marker),
    // decoded on first `funcById`. Also bake the bodyless-id list + fqn-head set
    // (the lazy-friendly link/packageHeadDeclared inputs), then null the eager
    // funcs so the whole table no longer materialises at load.
    var fn_hdr_enc = Encoder.init(gpa);
    defer fn_hdr_enc.deinit();
    {
        const offs = try a.alloc(u32, root.module.funcs.len);
        var bodyless: std.ArrayList(u32) = .empty;
        var heads = std.StringHashMap(void).init(gpa);
        defer heads.deinit();
        for (root.module.funcs, 0..) |*f, i| {
            offs[i] = @intCast(fn_hdr_enc.out.items.len + 1);
            fn_hdr_enc.resetRegistry();
            try encodeValue(ir.Func, &fn_hdr_enc, f);
            if (f.deferred_offset == 0 and f.blocks.len == 0) try bodyless.append(a, @intCast(i));
            // Only a DOTTED fqn contributes a package head. A dotless
            // name is not package-qualified: recording it whole would
            // make every bare stdlib func name (`done`, `run`, …) a
            // "package", flattening any user `x.member` read whose `x`
            // collides into an unresolvable dotted global.
            if (std.mem.indexOfScalar(u8, f.fqn, '.')) |dot| {
                const h = f.fqn[0..dot];
                if (h.len != 0) try heads.put(h, {});
            }
        }
        root.func_header_section = fn_hdr_enc.out.items;
        root.func_header_offsets = offs;
        root.bodyless_func_ids = try bodyless.toOwnedSlice(a);
        var head_list: std.ArrayList([]const u8) = .empty;
        var hit = heads.keyIterator();
        while (hit.next()) |k| try head_list.append(a, k.*);
        root.func_fqn_heads = try head_list.toOwnedSlice(a);
        root.module.funcs = &.{};
    }

    // Per-decl self-contained sections: each top-level decl encoded with a
    // fresh registry so the loader can decode it standalone on first touch
    // (the lazy forest). Emitted after the body/IR deferral above so the
    // sections capture the final baked decl form (marker bodies). Additive: the
    // eager `lifted_decls` stay in the payload until the lazy path is the
    // default; the loader picks one.
    var decl_enc = Encoder.init(gpa);
    defer decl_enc.deinit();
    // Map every forest node's address to its `(decl, ord)` reference as each
    // decl's self-contained section is emitted, so a `ForestField.ptr` into the
    // forest encodes as a lazy ref (the decoder reads the same ordinals back).
    var forest_map = std.AutoHashMap(usize, runtime.forest.ForestRef).init(gpa);
    defer forest_map.deinit();
    {
        const offsets = try a.alloc(u32, root.lifted_decls.len);
        for (root.lifted_decls, 0..) |*d, i| {
            offsets[i] = @intCast(decl_enc.out.items.len);
            decl_enc.resetRegistry();
            try encodeValue(ast.Decl, &decl_enc, d);
            var it = decl_enc.nodes.iterator();
            while (it.next()) |kv| {
                try forest_map.put(kv.key_ptr.addr, .{ .decl = @intCast(i), .ord = kv.value_ptr.* });
            }
        }
        root.lifted_decl_section = decl_enc.out.items;
        root.lifted_decl_offsets = offsets;
    }

    // Bake the base inline-fn name index as forest refs, so load installs it
    // without walking lifted_decls (the lazy replacement for collectInline).
    {
        var by_name = std.StringHashMap(std.ArrayList(FF(ast.Function))).init(gpa);
        defer {
            var dit = by_name.valueIterator();
            while (dit.next()) |v| v.deinit(gpa);
            by_name.deinit();
        }
        for (root.lifted_decls) |*d| try build.collectInline(gpa, d, &by_name);
        var list: std.ArrayList(InlineNamesImage) = .empty;
        var it = by_name.iterator();
        while (it.next()) |e| {
            const refs = try a.alloc(runtime.forest.ForestRef, e.value_ptr.items.len);
            var n: usize = 0;
            for (e.value_ptr.items) |ff| {
                if (forest_map.get(@intFromPtr(ff.get()))) |r| {
                    refs[n] = r;
                    n += 1;
                }
            }
            if (n != 0) try list.append(a, .{ .k = e.key_ptr.*, .v = refs[0..n] });
        }
        root.inline_by_name = try list.toOwnedSlice(a);
    }

    // Bake the base class index (simple-name -> class forest ref), the lazy
    // replacement for seeding `file_classes` from lifted_decls at load.
    {
        var list: std.ArrayList(ClassRefImage) = .empty;
        for (root.lifted_decls) |*d| {
            if (d.* == .Class) {
                if (forest_map.get(@intFromPtr(&d.Class))) |r|
                    try list.append(a, .{ .k = d.Class.name.name, .v = r });
            }
        }
        root.file_classes = try list.toOwnedSlice(a);
    }

    // Bake the base top-level property scope data from the base's registry (it
    // was populated by notePropScope when the base was first built), so load
    // replays it without walking lifted_decls.
    {
        var list: std.ArrayList(TopPropImage) = .empty;
        const mg = base.built.module.borrow();
        defer mg.deinit();
        var it = mg.get().registry.top_level_prop_pkgs.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |pd| {
                try list.append(a, .{
                    .name = e.key_ptr.*,
                    .fqn = pd.fqn,
                    .package = pd.package,
                    .type_head = mg.get().topLevelPropHeadFor(pd.fqn) orelse "",
                });
            }
        }
        root.top_props = try list.toOwnedSlice(a);
    }

    // Bake top-level function return heads. Only an unambiguous answer is
    // kept: a name with two declarations returning different classes tells
    // the checker nothing, and a wrong head is worse than none.
    {
        const mg = base.built.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        var classes = std.StringHashMap(void).init(gpa);
        defer classes.deinit();
        for (m.classes.items) |*c| classes.put(c.name, {}) catch {};
        var rets = std.StringHashMap([]const u8).init(gpa);
        defer rets.deinit();
        var ambiguous = std.StringHashMap(void).init(gpa);
        defer ambiguous.deinit();
        for (m.funcs.items) |*f| {
            if (f.kind != .plain) continue;
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
            var head = std.mem.trimEnd(u8, f.return_ty.name, "?");
            if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
            if (head.len == 0 or !classes.contains(head)) continue;
            if (ambiguous.contains(f.name)) continue;
            const gop = rets.getOrPut(f.name) catch continue;
            if (gop.found_existing) {
                if (!std.mem.eql(u8, gop.value_ptr.*, head)) {
                    _ = rets.remove(f.name);
                    ambiguous.put(f.name, {}) catch {};
                }
            } else gop.value_ptr.* = head;
        }
        var out: std.ArrayList(FnReturnImage) = .empty;
        var rit = rets.iterator();
        while (rit.next()) |e| try out.append(a, .{ .name = e.key_ptr.*, .head = e.value_ptr.* });
        root.fn_returns = try out.toOwnedSlice(a);

        var ekeys = std.StringHashMap([]const u8).init(gpa);
        defer ekeys.deinit();
        var eamb = std.StringHashMap(void).init(gpa);
        defer eamb.deinit();
        for (m.funcs.items) |*f| {
            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
            if (f.name.len == 0) continue;
            var rh = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
            if (std.mem.indexOfScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
            if (std.mem.lastIndexOfScalar(u8, rh, '.')) |d| rh = rh[d + 1 ..];
            var head = std.mem.trimEnd(u8, f.return_ty.name, "?");
            if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
            if (rh.len == 0 or head.len == 0 or !classes.contains(head)) continue;
            const key = std.fmt.allocPrint(a, "{s}\x00{s}", .{ rh, f.name }) catch continue;
            if (eamb.contains(key)) continue;
            const gop = ekeys.getOrPut(key) catch continue;
            if (gop.found_existing) {
                if (!std.mem.eql(u8, gop.value_ptr.*, head)) {
                    _ = ekeys.remove(key);
                    eamb.put(key, {}) catch {};
                }
            } else gop.value_ptr.* = head;
        }
        var eout: std.ArrayList(ExtReturnImage) = .empty;
        var eit2 = ekeys.iterator();
        while (eit2.next()) |e| try eout.append(a, .{ .key = e.key_ptr.*, .head = e.value_ptr.* });
        root.ext_returns = try eout.toOwnedSlice(a);
    }

    // Eager call resolutions the caller collected from the base's own
    // sources, which exist only here.
    {
        var out: std.ArrayList(EagerCallImage) = .empty;
        for (base.eager_calls) |ec| try out.append(a, .{ .call = ec.call, .fid = ec.fid });
        root.eager_calls = try out.toOwnedSlice(a);
    }

    // Drop the eager forest from the payload: the per-decl sections (lazy
    // `ForestField.get()`) plus the baked `inline_by_name` / `file_classes` /
    // `top_props` indices now cover everything load reads, so the whole AST
    // forest no longer materialises at startup. Any still-raw forest pointer in
    // built/module finds no global-registry entry and inline-encodes (correct).
    root.lifted_decls = &.{};

    var e = Encoder.init(gpa);
    defer e.deinit();

    try e.bytes(MAGIC);
    try e.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u32, FORMAT_VERSION)));
    // Payload-length slot, filled below.
    const len_slot = e.out.items.len;
    try e.bytes(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const payload_start = e.out.items.len;
    bake_forest_map = &forest_map;
    defer bake_forest_map = null;
    try encodeValue(ImageRoot, &e, root);
    const payload_len: u64 = e.out.items.len - payload_start;
    @memcpy(e.out.items[len_slot .. len_slot + 8], &std.mem.toBytes(std.mem.nativeToLittle(u64, payload_len)));
    try e.bytes(TRAILER);

    // Restore the live base's bodies and func blocks before handing back bytes.
    for (saved.items) |s| s.f.body = s.body;
    for (fn_saved.items) |s| {
        s.f.blocks = s.blocks;
        s.f.deferred_offset = 0;
    }

    return try e.out.toOwnedSlice(e.gpa);
}

fn rootFromBase(
    a: Allocator,
    base: *const StdlibBase,
    map: *const SourceMap,
    extras: BakeExtras,
) Allocator.Error!?*ImageRoot {
    const root = try a.create(ImageRoot);

    // Source files.
    {
        const files = try a.alloc(FileEntry, map.files.items.len);
        for (map.files.items, 0..) |*sf, i| {
            files[i] = .{ .path = sf.path, .source = sf.source };
        }
        root.files = files;
    }

    root.lifted_decls = @constCast(base.lifted_decls);

    {
        const mg = base.built.module.borrow();
        defer mg.deinit();
        if (!try moduleToImage(a, mg.get(), &root.module)) return null;
    }

    if (!try builtToImage(a, &base.built, &root.built)) return null;

    root.decl_names = try setToSlice(a, &base.decl_names);
    root.root_decl_names = try setToSlice(a, &base.root_decl_names);
    root.packages = try setToSlice(a, &base.packages);
    root.param_type_names = try setToSlice(a, &base.param_type_names);
    root.type_names = try setToSlice(a, &base.type_names);

    {
        const ids = try a.alloc(InlineIdImage, base.inline_ids.len);
        for (base.inline_ids, 0..) |entry, i| {
            ids[i] = .{ .id = entry.id, .f = entry.f };
        }
        root.inline_ids = ids;
    }
    root.enum_id_next = base.enum_id_next;
    root.known_packages = extras.known_packages;
    root.binding_fqns = extras.binding_fqns;
    root.main_func = if (base.built.main) |m| @as(u64, m.int()) + 1 else 0;
    return root;
}

fn setToSlice(a: Allocator, set: *const std.StringHashMap(void)) Allocator.Error![]const []const u8 {
    var out = try a.alloc([]const u8, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    return out;
}

fn moduleToImage(a: Allocator, m: *const Module, out: *ModuleImage) Allocator.Error!bool {
    if (m.resolve_diags.items.len != 0) return false;
    out.funcs = m.funcs.items;
    out.classes = m.classes.items;
    out.consts = m.consts.items;
    out.top_level = m.top_level.items;
    out.class_index = m.class_index.items;
    out.func_index = m.func_index.items;
    out.package = m.package;
    out.tailrec_fn_names = m.tailrec_fn_names.items;
    // The lazy-IR deferral runs in `bake` after this; default to eager.
    out.deferred_func_section = &.{};

    out.decl_user_params = try autoMapToSlice(u32, u32, a, &m.decl_user_params);
    out.decl_user_arity = try autoMapToSlice(u32, Module.DeclArity, a, &m.decl_user_arity);
    out.decl_user_sig = try autoMapToSlice(u32, []ir.TypeRef, a, &m.decl_user_sig);
    {
        var lites: std.ArrayList(DeclSigLite) = .empty;
        var it = m.decl_sigs.iterator();
        while (it.next()) |e| {
            const ds = e.value_ptr.*;
            try lites.append(a, .{
                .fid = e.key_ptr.*,
                .enclosing_class = ds.enclosing_class,
                .recv_head = if (ds.receiver_ty) |rt| rt.name else "",
                .recv_nullable = if (ds.receiver_ty) |rt| rt.nullable else false,
                .required = @intCast(ds.arity.required),
                .total = @intCast(ds.arity.total),
                .has_vararg = ds.arity.has_vararg,
                .sig = ds.sig,
                .kind = ds.kind,
                .visibility = ds.visibility,
                .is_inline = ds.is_inline,
                .is_suspend = ds.is_suspend,
                .has_body = ds.has_body,
                .host_symbol = ds.host_symbol orelse "",
            });
        }
        out.decl_sigs = try lites.toOwnedSlice(a);
    }
    out.decl_span = try autoMapToSlice(u32, Span, a, &m.decl_span);
    out.member_decl_groups = try m.memberDeclGroups(a);
    out.method_dispatch = try m.methodDispatchEntries(a);

    const r = &m.registry;
    out.registry = .{
        .object_names = r.object_names.items,
        .companion_singletons = try strMapToSlice([]const u8, a, &r.companion_singletons),
        .enclosing_class = try strMapToSlice([]const u8, a, &r.enclosing_class),
        .func_type_params = blk: {
            var list = try a.alloc(KV(FuncId, []const []const u8), r.func_type_params.count());
            var it = r.func_type_params.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.items };
            }
            break :blk list;
        },
        .func_type_param_bounds = try autoMapToSlice(FuncId, []const ir.ModuleRegistry.TypeParamBound, a, &r.func_type_param_bounds),
        .class_type_param_bounds = try strMapToSliceKV([]const ir.ModuleRegistry.TypeParamBound, a, &r.class_type_param_bounds),
        .top_level_delegated_props = try setToSlice(a, &r.top_level_delegated_props),
        .top_level_prop_getters = try strMapToSlice(FuncId, a, &r.top_level_prop_getters),
        .top_level_prop_setters = try strMapToSlice(FuncId, a, &r.top_level_prop_setters),
        .hierarchy_methods = blk: {
            var list = try a.alloc(KV([]const u8, []const []const u8), r.hierarchy_methods.count());
            var it = r.hierarchy_methods.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .k = entry.key_ptr.*, .v = try setToSlice(a, entry.value_ptr) };
            }
            break :blk list;
        },
        .class_member_names = try setToSlice(a, &r.class_member_names),
        .class_super_names = try strMapToSliceKV([]const []const u8, a, &r.class_super_names),
        .delegated_body_props = blk: {
            var list = try a.alloc(PairKey, r.delegated_body_props.count());
            var it = r.delegated_body_props.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b };
            }
            break :blk list;
        },
        .member_ext_owner_class = try autoMapToSlice(FuncId, []const u8, a, &r.member_ext_owner_class),
        .local_fn_defaults = blk: {
            var list = try a.alloc(KV(FuncId, []const ?FuncId), r.local_fn_defaults.count());
            var it = r.local_fn_defaults.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.items };
            }
            break :blk list;
        },
        .abstract_member_defaults = blk: {
            const E = @TypeOf(out.registry.abstract_member_defaults[0]);
            var list = try a.alloc(E, r.abstract_member_defaults.count());
            var it = r.abstract_member_defaults.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .slots = entry.value_ptr.items };
            }
            break :blk list;
        },
        .type_aliases = try strMapToSlice([]const u8, a, &r.type_aliases),
        .type_alias_types = try strMapToSliceKV(
            ir.ModuleRegistry.TypeAliasShape,
            a,
            &r.type_alias_types,
        ),
        .import_aliases = blk: {
            const E = @TypeOf(out.registry.import_aliases[0]);
            const L = @TypeOf(out.registry.import_aliases[0].leaves[0]);
            var list = try a.alloc(E, r.import_aliases.count());
            var it = r.import_aliases.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                var leaves = try a.alloc(L, entry.value_ptr.count());
                var lit = entry.value_ptr.iterator();
                var j: usize = 0;
                while (lit.next()) |le| : (j += 1) {
                    leaves[j] = .{ .leaf = le.key_ptr.*, .paths = le.value_ptr.items };
                }
                list[i] = .{ .file = entry.key_ptr.*, .leaves = leaves };
            }
            break :blk list;
        },
        .import_wildcards = blk: {
            var list = try a.alloc(KV(FileId, []const []const u8), r.import_wildcards.count());
            var it = r.import_wildcards.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.items };
            }
            break :blk list;
        },
        .nested_object_aliases = blk: {
            var list = try a.alloc(KV([]const u8, []StrKV), r.nested_object_aliases.count());
            var it = r.nested_object_aliases.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .k = entry.key_ptr.*, .v = try strMapToSlice([]const u8, a, entry.value_ptr) };
            }
            break :blk list;
        },
        .mangled_nested = try strMapToSlice([]const u8, a, &r.mangled_nested),
        .class_const_inits = blk: {
            const E = @TypeOf(out.registry.class_const_inits[0]);
            var list = try a.alloc(E, r.class_const_inits.count());
            var it = r.class_const_inits.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .v = entry.value_ptr.* };
            }
            break :blk list;
        },
        .class_prop_type_heads = try pairMapToSlice(a, &r.class_prop_type_heads),
        .class_prop_type_refs = blk_cptr: {
            var rows = try a.alloc(PairTypeEntry, r.class_prop_type_refs.count());
            var it = r.class_prop_type_refs.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                rows[i] = .{ .a = e.key_ptr.a, .b = e.key_ptr.b, .v = e.value_ptr.* };
            }
            break :blk_cptr rows;
        },
        .top_level_prop_type_refs = blk_tptr: {
            var rows = try a.alloc(NameTypeEntry, r.top_level_prop_type_refs.count());
            var it = r.top_level_prop_type_refs.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                rows[i] = .{ .name = e.key_ptr.*, .v = e.value_ptr.* };
            }
            break :blk_tptr rows;
        },
        .ext_prop_type_heads = try pairMapToSlice(a, &r.ext_prop_type_heads),
        .iface_member_ext_recv = try pairMapToSlice(a, &r.iface_member_ext_recv),
        .iface_member_ctx_types = try pairMapToSlice(a, &r.iface_member_ctx_types),
        .abstract_member_arity = blk: {
            var out2 = try a.alloc(PairU64Entry, r.abstract_member_arity.count());
            var it2 = r.abstract_member_arity.iterator();
            var idx2: usize = 0;
            while (it2.next()) |entry| : (idx2 += 1) {
                out2[idx2] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .v = entry.value_ptr.* };
            }
            break :blk out2;
        },
        .private_fn_files = try autoMapToSlice(FuncId, FileId, a, &r.private_fn_files),
        .file_packages = try autoMapToSlice(FileId, []const u8, a, &r.file_packages),
        .file_modules = try autoMapToSlice(FileId, u32, a, &r.file_modules),
        .top_level_const_vals = try strMapToSlice(ir.Const, a, &r.top_level_const_vals),
        .member_method_fids = try strMapToSlice(FuncId, a, &r.member_method_fids),
        .recv_fn_props = try pairMapToSlice(a, &r.recv_fn_props),
        .private_shadow_props = try setToSlice(a, &r.private_shadow_props),
        .override_cell_props = try setToSlice(a, &r.override_cell_props),
        .hierarchy_shadow_names = blk: {
            const E = @TypeOf(out.registry.hierarchy_shadow_names[0]);
            var list = try a.alloc(E, r.hierarchy_shadow_names.count());
            var it = r.hierarchy_shadow_names.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                list[i] = .{
                    .k = entry.key_ptr.*,
                    .names = try setToSlice(a, &entry.value_ptr.names),
                    .complete = entry.value_ptr.complete,
                };
            }
            break :blk list;
        },
    };
    return true;
}

/// `StrPairMap([]const u8)` -> flat (a, b, v) triples for the image.
fn pairMapToSlice(a: Allocator, m: anytype) Allocator.Error![]PairStrEntry {
    var out = try a.alloc(PairStrEntry, m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .v = entry.value_ptr.* };
    }
    return out;
}

fn autoMapToSlice(comptime K: type, comptime V: type, a: Allocator, m: *const std.AutoHashMap(K, V)) Allocator.Error![]KV(K, V) {
    var out = try a.alloc(KV(K, V), m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.* };
    }
    return out;
}

fn strMapToSlice(comptime V: type, a: Allocator, m: *const std.StringHashMap(V)) Allocator.Error![]KV([]const u8, V) {
    var out = try a.alloc(KV([]const u8, V), m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.* };
    }
    return out;
}

const strMapToSliceKV = strMapToSlice;

fn builtToImage(a: Allocator, b: *const BuiltModule, out: *BuiltImage) Allocator.Error!bool {
    // The ClassDef graph first: every def reachable from the table gets an
    // index, so edges and enum-entry instances can refer by index.
    var def_index = std.AutoHashMap(usize, u32).init(a);
    var defs: std.ArrayList(ObjRef(ClassDef)) = .empty;
    {
        var worklist: std.ArrayList(ObjRef(ClassDef)) = .empty;
        var it = b.classes.valueIterator();
        while (it.next()) |def| try worklist.append(a, def.*);
        var head: usize = 0;
        while (head < worklist.items.len) : (head += 1) {
            const def = worklist.items[head];
            const key = @intFromPtr(def.cell);
            const gop = try def_index.getOrPut(key);
            if (gop.found_existing) continue;
            gop.value_ptr.* = @intCast(defs.items.len);
            try defs.append(a, def);
            const g = def.borrow();
            defer g.deinit();
            const cd = g.get();
            if (cd.parent) |p| try worklist.append(a, p);
            for (cd.interfaces) |iface| try worklist.append(a, iface);
            for (cd.nested_classes) |nc| try worklist.append(a, nc.class);
            {
                const eg = cd.enclosing_class.borrow();
                const enc = eg.get().*;
                eg.deinit();
                if (enc) |ec| try worklist.append(a, ec);
            }
            for (cd.supertype_delegates) |sd| {
                if (sd.interface) |iface| try worklist.append(a, iface);
            }
            for (cd.enum_entries) |entry| {
                if (!try collectValueClasses(a, &worklist, entry.value)) return false;
            }
        }
    }

    const class_defs = try a.alloc(ClassDefImage, defs.items.len);
    for (defs.items, 0..) |def, i| {
        if (!try classDefToImage(a, def, &def_index, &class_defs[i])) return false;
    }
    out.class_defs = class_defs;
    {
        var table = try a.alloc(KV([]const u8, u32), b.classes.count());
        var it = b.classes.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            table[i] = .{ .k = entry.key_ptr.*, .v = def_index.get(@intFromPtr(entry.value_ptr.cell)).? };
        }
        out.class_table = table;
    }

    out.body_prop_inits = try pairFuncToSlice(a, &b.body_prop_inits);
    out.instance_prop_getters = try pairFuncToSlice(a, &b.instance_prop_getters);
    out.instance_prop_setters = try pairFuncToSlice(a, &b.instance_prop_setters);
    out.instance_prop_private = try pairFuncToSlice(a, &b.instance_prop_private);
    out.parent_ctor_args = try nameFuncsToSlice(a, &b.parent_ctor_args);
    out.parent_ctor_arg_names = try nameArgNamesToSlice(a, &b.parent_ctor_arg_names);
    out.init_blocks = try nameFuncsToSlice(a, &b.init_blocks);
    out.top_level_props = b.top_level_props.items;
    out.extension_props = try pairFuncToSlice(a, &b.extension_props);
    {
        var list: std.ArrayList(build.StrFunc) = .empty;
        var it = b.nullable_ext_props.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |fid| try list.append(a, .{ .name = e.key_ptr.*, .func = fid });
        }
        out.nullable_ext_props = try list.toOwnedSlice(a);
    }
    out.extension_prop_setters = try pairFuncToSlice(a, &b.extension_prop_setters);
    out.extension_prop_delegates = try pairFuncToSlice(a, &b.extension_prop_delegates);
    out.object_names = b.object_names.items;
    out.companion_singletons = try strMapToSlice([]const u8, a, &b.companion_singletons);
    out.enum_entry_arg_inits = b.enum_entry_arg_inits.items;
    out.secondary_ctors = blk: {
        const E = @TypeOf(out.secondary_ctors[0]);
        var list = try a.alloc(E, b.secondary_ctors.count());
        var it = b.secondary_ctors.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .name = entry.key_ptr.*, .entries = entry.value_ptr.* };
        }
        break :blk list;
    };
    out.primary_ctor_default_thunks = blk: {
        var list = try a.alloc(NameOptFuncs, b.primary_ctor_default_thunks.count());
        var it = b.primary_ctor_default_thunks.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .name = entry.key_ptr.*, .slots = entry.value_ptr.* };
        }
        break :blk list;
    };
    out.class_delegates = blk: {
        const E = @TypeOf(out.class_delegates[0]);
        var list = try a.alloc(E, b.class_delegates.count());
        var it = b.class_delegates.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .name = entry.key_ptr.*, .entries = entry.value_ptr.* };
        }
        break :blk list;
    };
    out.func_defaults = blk: {
        var list = try a.alloc(KV(u32, []const ?FuncId), b.func_defaults.count());
        var it = b.func_defaults.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.* };
        }
        break :blk list;
    };
    out.enclosing_class = try strMapToSlice([]const u8, a, &b.enclosing_class);
    out.enum_entry_methods = blk: {
        const E = @TypeOf(out.enum_entry_methods[0]);
        var list = try a.alloc(E, b.enum_entry_methods.count());
        var it = b.enum_entry_methods.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            const mg = entry.value_ptr.module.borrow();
            defer mg.deinit();
            list[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .module = undefined, .func = entry.value_ptr.func };
            if (!try moduleToImage(a, mg.get(), &list[i].module)) return false;
        }
        break :blk list;
    };
    out.enum_entry_synth_class = blk: {
        var list = try a.alloc(PairStrEntry, b.enum_entry_synth_class.count());
        var it = b.enum_entry_synth_class.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .v = entry.value_ptr.* };
        }
        break :blk list;
    };
    out.func_type_params = blk: {
        var list = try a.alloc(KV(u32, []const []const u8), b.func_type_params.count());
        var it = b.func_type_params.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .k = entry.key_ptr.*, .v = entry.value_ptr.* };
        }
        break :blk list;
    };
    out.top_level_delegated_props = try setToSlice(a, &b.top_level_delegated_props);
    out.delegated_body_props = blk: {
        var list = try a.alloc(PairKey, b.delegated_body_props.count());
        var it = b.delegated_body_props.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            list[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b };
        }
        break :blk list;
    };
    return true;
}

fn pairFuncToSlice(a: Allocator, m: *const build.PairFuncMap) Allocator.Error![]PairFuncEntry {
    var out = try a.alloc(PairFuncEntry, m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .a = entry.key_ptr.a, .b = entry.key_ptr.b, .func = entry.value_ptr.* };
    }
    return out;
}

fn nameFuncsToSlice(a: Allocator, m: *const std.StringHashMap([]FuncId)) Allocator.Error![]NameFuncs {
    var out = try a.alloc(NameFuncs, m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .name = entry.key_ptr.*, .funcs = entry.value_ptr.* };
    }
    return out;
}

fn nameArgNamesToSlice(a: Allocator, m: *const std.StringHashMap([]const ?[]const u8)) Allocator.Error![]NameArgNames {
    var out = try a.alloc(NameArgNames, m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .name = entry.key_ptr.*, .arg_names = entry.value_ptr.* };
    }
    return out;
}

/// Queue the ClassDefs reachable from a build-time enum-entry value, and
/// verify the value is within the serializable surface.
fn collectValueClasses(a: Allocator, worklist: *std.ArrayList(ObjRef(ClassDef)), v: Value) Allocator.Error!bool {
    switch (v) {
        .Unit, .Null, .Bool, .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Char, .String => return true,
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const s = g.get();
            if (s.outer != null or s.native_state != null) return false;
            try worklist.append(a, s.class);
            for (s.fields.items) |f| {
                if (!try collectValueClasses(a, worklist, f.value)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn valueToImage(a: Allocator, def_index: *const std.AutoHashMap(usize, u32), v: Value) Allocator.Error!?ValueImage {
    switch (v) {
        .Unit => return .Unit,
        .Null => return .Null,
        .Bool => |x| return .{ .Bool = x },
        .Int => |x| return .{ .Int = x },
        .Long => |x| return .{ .Long = x },
        .Short => |x| return .{ .Short = x },
        .Byte => |x| return .{ .Byte = x },
        .UInt => |x| return .{ .UInt = x },
        .ULong => |x| return .{ .ULong = x },
        .UShort => |x| return .{ .UShort = x },
        .UByte => |x| return .{ .UByte = x },
        .Double => |x| return .{ .Double = x },
        .Float => |x| return .{ .Float = x },
        .Char => |x| return .{ .Char = x },
        .String => |sref| {
            const g = sref.borrow();
            defer g.deinit();
            return .{ .Str = g.get().bytes };
        },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const s = g.get();
            if (s.outer != null or s.native_state != null) return null;
            const cls = def_index.get(@intFromPtr(s.class.cell)) orelse return null;
            const fields = try a.alloc(FieldImage, s.fields.items.len);
            for (s.fields.items, 0..) |f, i| {
                const fv = (try valueToImage(a, def_index, f.value)) orelse return null;
                fields[i] = .{ .name = f.name, .value = fv };
            }
            return .{ .Instance = .{ .class = cls, .fields = fields, .identity = s.identity } };
        },
        else => return null,
    }
}

fn methodToImage(m: *const runtime.MethodDef, out: *MethodImage) bool {
    if (m.sam_lambda != null) return false;
    out.* = .{
        .name = m.name,
        .decl = m.decl,
        .is_operator = m.is_operator,
        .is_open = m.is_open,
        .is_override = m.is_override,
        .is_abstract = m.is_abstract,
        .delegate_field = m.delegate_field,
        .ir_fn_id = m.ir_fn_id,
    };
    return true;
}

fn classDefToImage(
    a: Allocator,
    def: ObjRef(ClassDef),
    def_index: *const std.AutoHashMap(usize, u32),
    out: *ClassDefImage,
) Allocator.Error!bool {
    const g = def.borrow();
    defer g.deinit();
    const cd = g.get();

    const primary = try a.alloc(ClassParamImage, cd.primary_params.len);
    for (cd.primary_params, 0..) |p, i| {
        primary[i] = .{
            .property = p.property,
            .name = p.name,
            .default = p.default,
            .declared_type = p.declared_type,
            .declared_shape = p.declared_shape,
            .anchors = p.anchors,
        };
    }

    const methods = try a.alloc(MethodImage, cd.methods.len);
    for (cd.methods, 0..) |*m, i| {
        if (!methodToImage(m, &methods[i])) return false;
    }
    const forwarders = try a.alloc(MethodImage, cd.delegate_forwarders.len);
    for (cd.delegate_forwarders, 0..) |*m, i| {
        if (!methodToImage(m, &forwarders[i])) return false;
    }

    const props = try a.alloc(PropertyImage, cd.body_properties.len);
    for (cd.body_properties, 0..) |p, i| {
        var zero: ?ValueImage = null;
        if (p.primitive_zero) |z| {
            zero = (try valueToImage(a, def_index, z)) orelse return false;
        }
        props[i] = .{
            .name = p.name,
            .mutable = p.mutable,
            .init = p.init,
            .getter = p.getter,
            .setter = p.setter,
            .delegate = p.delegate,
            .is_abstract = p.is_abstract,
            .is_lateinit = p.is_lateinit,
            .primitive_zero = zero,
            .anchors = p.anchors,
            .has_backing = p.has_backing,
            .type_head = p.type_head,
        };
    }

    const ifaces = try a.alloc(u32, cd.interfaces.len);
    for (cd.interfaces, 0..) |iface, i| {
        ifaces[i] = def_index.get(@intFromPtr(iface.cell)) orelse return false;
    }

    const EntryImage = @TypeOf(out.enum_entries[0]);
    const entries = try a.alloc(EntryImage, cd.enum_entries.len);
    for (cd.enum_entries, 0..) |entry, i| {
        const v = (try valueToImage(a, def_index, entry.value)) orelse return false;
        entries[i] = .{ .name = entry.name, .value = v, .annotation_records = entry.annotation_records };
    }

    const NestedImage = @TypeOf(out.nested_classes[0]);
    const nested = try a.alloc(NestedImage, cd.nested_classes.len);
    for (cd.nested_classes, 0..) |nc, i| {
        nested[i] = .{ .name = nc.name, .idx = def_index.get(@intFromPtr(nc.class.cell)) orelse return false };
    }

    const delegates = try a.alloc(DelegateImage, cd.supertype_delegates.len);
    for (cd.supertype_delegates, 0..) |sd, i| {
        var iface_idx: ?u32 = null;
        if (sd.interface) |iface| {
            iface_idx = def_index.get(@intFromPtr(iface.cell)) orelse return false;
        }
        delegates[i] = .{
            .interface_name = sd.interface_name,
            .interface = iface_idx,
            .expr = sd.expr,
            .field_key = sd.field_key,
        };
    }

    var enclosing: ?u32 = null;
    {
        const eg = cd.enclosing_class.borrow();
        const enc = eg.get().*;
        eg.deinit();
        if (enc) |ec| {
            enclosing = def_index.get(@intFromPtr(ec.cell)) orelse return false;
        }
    }

    out.* = .{
        .name = cd.name,
        .fqn = cd.fqn,
        .annotation_names = cd.annotation_names,
        .annotation_records = cd.annotation_records,
        .type_params = cd.type_params,
        .primary_params = primary,
        .methods = methods,
        .body_properties = props,
        .init_blocks = cd.init_blocks,
        .init_block_property_positions = @constCast(cd.init_block_property_positions),
        .is_data = cd.is_data,
        .is_value = cd.is_value,
        .is_object = cd.is_object,
        .is_enum = cd.is_enum,
        .is_annotation = cd.is_annotation,
        .is_sealed = cd.is_sealed,
        .supertype_names = cd.supertype_names,
        .parent = if (cd.parent) |p| (def_index.get(@intFromPtr(p.cell)) orelse return false) else null,
        .interfaces = ifaces,
        .is_interface = cd.is_interface,
        .is_fun_interface = cd.is_fun_interface,
        .parent_ctor_args = @constCast(cd.parent_ctor_args),
        .is_open = cd.is_open,
        .is_abstract = cd.is_abstract,
        .is_inner = cd.is_inner,
        .is_anonymous = cd.is_anonymous,
        .secondary_ctors = @constCast(cd.secondary_ctors),
        .enum_entries = entries,
        .enclosing = enclosing,
        .nested_classes = nested,
        .supertype_delegates = delegates,
        .delegate_forwarders = forwarders,
    };
    return true;
}

// -------------------------------------------------------------------------
// Load: bytes -> StdlibBase
// -------------------------------------------------------------------------

pub const Loaded = struct {
    base: *StdlibBase,
    map: *SourceMap,
    known_packages: []const []const u8,
    binding_fqns: []const []const u8,
};

/// Why the most recent `load` on this thread returned null; empty when it
/// succeeded. Trace/diagnostic only.
threadlocal var load_failure: []const u8 = "";

pub fn lastLoadFailure() []const u8 {
    return load_failure;
}

/// Reconstruct a `StdlibBase` from image bytes. `a` must be a
/// process-lifetime arena; `bytes` must stay alive as long as the base
/// (decoded strings borrow from it). Returns null on any format/version
/// mismatch or malformed input — callers rebake.
pub fn load(a: Allocator, bytes: []const u8) Allocator.Error!?Loaded {
    load_failure = "";
    if (bytes.len < MAGIC.len + 4 + 8 + TRAILER.len) {
        load_failure = "short header";
        return null;
    }
    if (!std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) {
        load_failure = "bad magic";
        return null;
    }
    const version = std.mem.readInt(u32, bytes[MAGIC.len..][0..4], .little);
    if (version != FORMAT_VERSION) {
        load_failure = "format version mismatch";
        return null;
    }
    const payload_len = std.mem.readInt(u64, bytes[MAGIC.len + 4 ..][0..8], .little);
    const payload_start = MAGIC.len + 4 + 8;
    const expect_total = payload_start + payload_len + TRAILER.len;
    if (expect_total != bytes.len) {
        load_failure = "length mismatch";
        return null;
    }
    if (!std.mem.eql(u8, bytes[bytes.len - TRAILER.len ..], TRAILER)) {
        load_failure = "bad trailer";
        return null;
    }

    decode_stats_on = if (@import("builtin").link_libc) (runtime.envSetOnce("KLIO_DECODE_STATS")) else false;
    // Reserve this image's forest slot before decoding: every `ForestRef`
    // in the payload is image-local and rebases onto the slot as it
    // decodes, so bases from several images coexist in one process.
    const slot = runtime.forest.reserveSlot() orelse {
        load_failure = "forest slot registry full";
        return null;
    };
    load_forest_rebase = runtime.forest.slotBase(slot);
    defer load_forest_rebase = 0;
    const snap0 = runtime.allocTrackSnapshot();
    var d = Decoder{ .a = a, .buf = bytes[payload_start .. payload_start + payload_len] };
    const root = a.create(ImageRoot) catch return error.OutOfMemory;
    decodeInto(ImageRoot, &d, root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => {
            load_failure = "malformed payload";
            return null;
        },
    };
    if (d.pos != d.buf.len) {
        load_failure = "trailing payload bytes";
        return null;
    }
    runtime.allocTrackReportPhase("image.decode", snap0);
    dumpDecodeStats();

    const snap1 = runtime.allocTrackSnapshot();
    const loaded = try baseFromRoot(a, root, slot);
    runtime.allocTrackReportPhase("image.baseFromRoot", snap1);
    if (loaded == null) load_failure = "inconsistent tables";
    return loaded;
}

fn baseFromRoot(a: Allocator, root: *const ImageRoot, slot: u32) Allocator.Error!?Loaded {
    // Install the lazy-forest resolver first: building the base below resolves
    // forest refs (e.g. `inline_ids`), so the section/offset table and decode
    // hook must be live before any `ForestField.get()`.
    runtime.forest.fillSlot(slot, root.lifted_decl_section, root.lifted_decl_offsets, a, decodeLiftedDeclReg);
    const rebase = runtime.forest.slotBase(slot);

    const map = try a.create(SourceMap);
    map.* = SourceMap.init(a);
    // The image's file paths/sources are borrows of the process-lifetime mmap,
    // so register them borrowed: no whole-stdlib source dupe, no eager line
    // tables. Saves ~7 MB at startup.
    for (root.files) |f| {
        _ = map.addBorrowed(f.path, f.source) catch return error.OutOfMemory;
    }

    var module = Module.default(a);
    try moduleFromImage(a, &root.module, &module);
    // Install lazy func headers: the eager `funcs` slice is empty in the image;
    // a func decodes from its per-func section on first `funcById`.
    if (root.func_header_offsets.len != 0) {
        module.func_header_section = root.func_header_section;
        module.func_header_offsets = root.func_header_offsets;
        module.func_header_decode = decodeFuncHeader;
        module.func_cache = try a.alloc(?*ir.Func, root.func_header_offsets.len);
        @memset(module.func_cache, null);
        module.func_fqn_heads = root.func_fqn_heads;
        module.bodyless_func_ids = root.bodyless_func_ids;
    }
    const module_ref = try ObjRef(Module).init(a, module);
    var built = build.emptyBuiltShell(a, module_ref, null);
    if (!try builtFromImage(a, &root.built, &built)) return null;
    if (root.main_func != 0) built.main = FuncId.from(@intCast(root.main_func - 1));

    const base = try a.create(StdlibBase);
    base.* = .{
        .built = built,
        .lifted_decls = root.lifted_decls,
        .decl_names = try sliceToSet(a, root.decl_names),
        .root_decl_names = try sliceToSet(a, root.root_decl_names),
        .packages = try sliceToSet(a, root.packages),
        .param_type_names = try sliceToSet(a, root.param_type_names),
        .type_names = try sliceToSet(a, root.type_names),
        .inline_ids = blk: {
            const ids = try a.alloc(StdlibBase.InlineId, root.inline_ids.len);
            for (root.inline_ids, 0..) |entry, i| {
                ids[i] = .{ .id = entry.id, .f = entry.f };
            }
            break :blk ids;
        },
        // The name-index tables decode as plain `ForestRef` structs (not
        // `ForestField`s), so their image-local decl indexes rebase here.
        .inline_by_name = blk: {
            const out = try a.alloc(StdlibBase.InlineNames, root.inline_by_name.len);
            for (root.inline_by_name, 0..) |entry, i| {
                const refs = try a.alloc(runtime.forest.ForestRef, entry.v.len);
                for (entry.v, 0..) |r, j| refs[j] = .{ .decl = r.decl + rebase, .ord = r.ord };
                out[i] = .{ .k = entry.k, .v = refs };
            }
            break :blk out;
        },
        .file_classes = blk: {
            const out = try a.alloc(StdlibBase.ClassRef, root.file_classes.len);
            for (root.file_classes, 0..) |entry, i| {
                out[i] = .{ .k = entry.k, .v = .{ .decl = entry.v.decl + rebase, .ord = entry.v.ord } };
            }
            break :blk out;
        },
        .top_props = blk: {
            const out = try a.alloc(StdlibBase.TopProp, root.top_props.len);
            for (root.top_props, 0..) |entry, i| {
                out[i] = .{ .name = entry.name, .fqn = entry.fqn, .package = entry.package, .type_head = entry.type_head };
            }
            break :blk out;
        },
        .fn_returns = blk: {
            const out = try a.alloc(StdlibBase.FnReturn, root.fn_returns.len);
            for (root.fn_returns, 0..) |entry, i| {
                out[i] = .{ .name = entry.name, .head = entry.head };
            }
            break :blk out;
        },
        .ext_returns = blk: {
            const out = try a.alloc(StdlibBase.ExtReturn, root.ext_returns.len);
            for (root.ext_returns, 0..) |entry, i| {
                out[i] = .{ .key = entry.key, .head = entry.head };
            }
            break :blk out;
        },
        .eager_calls = blk: {
            const out = try a.alloc(StdlibBase.EagerCall, root.eager_calls.len);
            for (root.eager_calls, 0..) |entry, i| {
                out[i] = .{ .call = entry.call, .fid = entry.fid };
            }
            break :blk out;
        },
        .user_file_start = @intCast(root.files.len),
        .enum_id_next = root.enum_id_next,
        .deferred_bodies = root.deferred_bodies,
        .lifted_decl_section = root.lifted_decl_section,
        .lifted_decl_offsets = root.lifted_decl_offsets,
        .arena = a,
    };

    return .{
        .base = base,
        .map = map,
        .known_packages = root.known_packages,
        .binding_fqns = root.binding_fqns,
    };
}

fn sliceToSet(a: Allocator, items: []const []const u8) Allocator.Error!std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(a);
    try out.ensureTotalCapacity(@intCast(items.len));
    for (items) |k| try out.put(k, {});
    return out;
}

fn moduleFromImage(a: Allocator, img: *const ModuleImage, out: *Module) Allocator.Error!void {
    try out.funcs.appendSlice(a, img.funcs);
    // Lazy IR: a deferred function (its `deferred_offset` set in `img.funcs`)
    // materialises its blocks on first execution from this section.
    out.deferred_func_section = img.deferred_func_section;
    out.deferred_func_arena = a;
    out.deferred_func_decode = decodeFuncBlocks;
    try out.classes.appendSlice(a, img.classes);
    try out.consts.appendSlice(a, img.consts);
    try out.top_level.appendSlice(a, img.top_level);
    try out.class_index.appendSlice(a, img.class_index);
    try out.func_index.appendSlice(a, img.func_index);
    out.package = img.package;
    try out.tailrec_fn_names.appendSlice(a, img.tailrec_fn_names);

    for (img.decl_user_params) |kv| try out.decl_user_params.put(kv.k, kv.v);
    for (img.decl_user_arity) |kv| try out.decl_user_arity.put(kv.k, kv.v);
    for (img.decl_user_sig) |kv| try out.decl_user_sig.put(kv.k, kv.v);
    for (img.decl_sigs) |l| {
        const rt: ?ir.TypeRef = if (l.recv_head.len != 0)
            .{ .name = l.recv_head, .nullable = l.recv_nullable, .args = &.{} }
        else
            null;
        try out.decl_sigs.put(l.fid, .{
            .enclosing_class = l.enclosing_class,
            .receiver_ty = rt,
            .arity = .{ .required = l.required, .total = l.total, .has_vararg = l.has_vararg },
            .sig = l.sig,
            .kind = l.kind,
            .visibility = l.visibility,
            .is_inline = l.is_inline,
            .is_suspend = l.is_suspend,
            .has_body = l.has_body,
            .host_symbol = if (l.host_symbol.len != 0) l.host_symbol else null,
        });
    }
    for (img.decl_span) |kv| try out.decl_span.put(kv.k, kv.v);
    for (img.member_decl_groups) |group| {
        for (group.fids) |fid| try out.registerMemberDecl(a, group.owner_fqn, group.name, fid);
    }
    for (img.method_dispatch) |entry| {
        try out.registerMethodSlotTarget(entry.runtime_class, entry.slot, entry.target);
    }

    const r = &out.registry;
    const ri = &img.registry;
    try r.object_names.appendSlice(a, ri.object_names);
    for (ri.companion_singletons) |kv| try r.companion_singletons.put(kv.k, kv.v);
    for (ri.enclosing_class) |kv| try r.enclosing_class.put(kv.k, kv.v);
    for (ri.func_type_params) |kv| {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(a, kv.v);
        try r.func_type_params.put(kv.k, list);
    }
    for (ri.func_type_param_bounds) |kv| try r.func_type_param_bounds.put(kv.k, kv.v);
    for (ri.class_type_param_bounds) |kv| try r.class_type_param_bounds.put(kv.k, kv.v);
    for (ri.top_level_delegated_props) |k| try r.top_level_delegated_props.put(k, {});
    for (ri.top_level_prop_getters) |kv| try r.top_level_prop_getters.put(kv.k, kv.v);
    for (ri.top_level_prop_setters) |kv| try r.top_level_prop_setters.put(kv.k, kv.v);
    for (ri.hierarchy_methods) |kv| {
        try r.hierarchy_methods.put(kv.k, try sliceToSet(a, kv.v));
    }
    for (ri.class_member_names) |k| try r.class_member_names.put(k, {});
    for (ri.class_super_names) |kv| try r.class_super_names.put(kv.k, kv.v);
    for (ri.delegated_body_props) |p| try r.delegated_body_props.put(.{ .a = p.a, .b = p.b }, {});
    for (ri.member_ext_owner_class) |kv| try r.member_ext_owner_class.put(kv.k, kv.v);
    for (ri.local_fn_defaults) |kv| {
        var list: std.ArrayList(?FuncId) = .empty;
        try list.appendSlice(a, kv.v);
        try r.local_fn_defaults.put(kv.k, list);
    }
    for (ri.abstract_member_defaults) |entry| {
        var list: std.ArrayList(?FuncId) = .empty;
        try list.appendSlice(a, entry.slots);
        try r.abstract_member_defaults.put(.{ .a = entry.a, .b = entry.b }, list);
    }
    for (ri.type_aliases) |kv| try r.type_aliases.put(kv.k, kv.v);
    for (ri.type_alias_types) |kv| try r.type_alias_types.put(kv.k, kv.v);
    for (ri.import_aliases) |entry| {
        var inner = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
        for (entry.leaves) |le| {
            var list: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
            try list.appendSlice(a, le.paths);
            try inner.put(le.leaf, list);
        }
        try r.import_aliases.put(entry.file, inner);
    }
    for (ri.import_wildcards) |kv| {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(a, kv.v);
        try r.import_wildcards.put(kv.k, list);
    }
    for (ri.nested_object_aliases) |kv| {
        var inner = std.StringHashMap([]const u8).init(a);
        for (kv.v) |skv| try inner.put(skv.k, skv.v);
        try r.nested_object_aliases.put(kv.k, inner);
    }
    for (ri.mangled_nested) |kv| try r.mangled_nested.put(kv.k, kv.v);
    for (ri.class_const_inits) |entry| try r.class_const_inits.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.class_prop_type_heads) |entry| try r.class_prop_type_heads.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.class_prop_type_refs) |entry| try r.class_prop_type_refs.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.top_level_prop_type_refs) |entry| try r.top_level_prop_type_refs.put(entry.name, entry.v);
    for (ri.ext_prop_type_heads) |entry| try r.ext_prop_type_heads.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.iface_member_ext_recv) |entry| try r.iface_member_ext_recv.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.iface_member_ctx_types) |entry| try r.iface_member_ctx_types.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.abstract_member_arity) |entry| try r.abstract_member_arity.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (ri.private_fn_files) |kv| try r.private_fn_files.put(kv.k, kv.v);
    for (ri.file_packages) |kv| try r.file_packages.put(kv.k, kv.v);
    for (ri.file_modules) |kv| try r.file_modules.put(kv.k, kv.v);
    for (ri.top_level_const_vals) |kv| try r.top_level_const_vals.put(kv.k, kv.v);
    for (ri.member_method_fids) |kv| try r.member_method_fids.put(kv.k, kv.v);
    for (ri.recv_fn_props) |pk| try r.recv_fn_props.put(.{ .a = pk.a, .b = pk.b }, pk.v);
    for (ri.private_shadow_props) |k| try r.private_shadow_props.put(k, {});
    for (ri.override_cell_props) |k| try r.override_cell_props.put(k, {});
    for (ri.hierarchy_shadow_names) |entry| {
        try r.hierarchy_shadow_names.put(entry.k, .{
            .names = try sliceToSet(a, entry.names),
            .complete = entry.complete,
        });
    }

    try out.rebuildFuncNameIndex(a);
}

fn builtFromImage(a: Allocator, img: *const BuiltImage, out: *BuiltModule) Allocator.Error!bool {
    // ClassDef graph: shells first, then links — mirrors the two-phase
    // shape of `cloneClassTableForRun`.
    const defs = try a.alloc(ObjRef(ClassDef), img.class_defs.len);
    for (img.class_defs, 0..) |*ci, i| {
        defs[i] = try ObjRef(ClassDef).init(a, .{
            .name = ci.name,
            .fqn = ci.fqn,
            .annotation_names = ci.annotation_names,
            .annotation_records = ci.annotation_records,
            .type_params = ci.type_params,
            .primary_params = blk: {
                const params = try a.alloc(runtime.ClassParamDef, ci.primary_params.len);
                for (ci.primary_params, 0..) |p, j| {
                    params[j] = .{
                        .property = p.property,
                        .name = p.name,
                        .default = p.default,
                        .declared_type = p.declared_type,
                        .declared_shape = p.declared_shape,
                        .anchors = p.anchors,
                    };
                }
                break :blk params;
            },
            .methods = try methodsFromImage(a, ci.methods),
            .body_properties = blk: {
                const props = try a.alloc(runtime.PropertyDef, ci.body_properties.len);
                for (ci.body_properties, 0..) |p, j| {
                    props[j] = .{
                        .name = p.name,
                        .mutable = p.mutable,
                        .init = p.init,
                        .getter = p.getter,
                        .setter = p.setter,
                        .delegate = p.delegate,
                        .is_abstract = p.is_abstract,
                        .is_lateinit = p.is_lateinit,
                        .primitive_zero = if (p.primitive_zero) |z| try scalarFromImage(z) else null,
                        .anchors = p.anchors,
                        .has_backing = p.has_backing,
                        .type_head = p.type_head,
                    };
                }
                break :blk props;
            },
            .init_blocks = ci.init_blocks,
            .init_block_property_positions = ci.init_block_property_positions,
            .is_data = ci.is_data,
            .is_value = ci.is_value,
            .is_object = ci.is_object,
            .is_enum = ci.is_enum,
            .is_annotation = ci.is_annotation,
            .is_sealed = ci.is_sealed,
            .supertype_names = ci.supertype_names,
            .parent = null,
            .interfaces = &.{},
            .is_interface = ci.is_interface,
            .is_fun_interface = ci.is_fun_interface,
            .parent_ctor_args = ci.parent_ctor_args,
            .is_open = ci.is_open,
            .is_abstract = ci.is_abstract,
            .is_inner = ci.is_inner,
            .is_anonymous = ci.is_anonymous,
            .secondary_ctors = ci.secondary_ctors,
            .enum_entries = &.{},
            .companion = try ObjRef(?ObjRef(InstanceData)).init(a, null),
            .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(a, null),
            .nested_classes = &.{},
            .captured_env = try ObjRef(Env).init(a, Env.init(a)),
            .supertype_delegates = &.{},
            .delegate_forwarders = try methodsFromImage(a, ci.delegate_forwarders),
            .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(a, null),
        });
    }
    // Link pass.
    for (img.class_defs, 0..) |*ci, i| {
        const cg = defs[i].borrowMut();
        defer cg.deinit();
        const c = cg.get();
        if (ci.parent) |p| {
            if (p >= defs.len) return false;
            c.parent = defs[p].clone();
        }
        if (ci.interfaces.len != 0) {
            const ifaces = try a.alloc(ObjRef(ClassDef), ci.interfaces.len);
            for (ci.interfaces, 0..) |idx, j| {
                if (idx >= defs.len) return false;
                ifaces[j] = defs[idx].clone();
            }
            c.interfaces = ifaces;
        }
        if (ci.nested_classes.len != 0) {
            const nested = try a.alloc(ClassDef.NestedClass, ci.nested_classes.len);
            for (ci.nested_classes, 0..) |nc, j| {
                if (nc.idx >= defs.len) return false;
                nested[j] = .{ .name = nc.name, .class = defs[nc.idx].clone() };
            }
            c.nested_classes = nested;
        }
        if (ci.enclosing) |idx| {
            if (idx >= defs.len) return false;
            const eg = c.enclosing_class.borrowMut();
            eg.get().* = defs[idx].clone();
            eg.deinit();
        }
        if (ci.supertype_delegates.len != 0) {
            const delegates = try a.alloc(runtime.SupertypeDelegate, ci.supertype_delegates.len);
            for (ci.supertype_delegates, 0..) |sd, j| {
                var iface: ?ObjRef(ClassDef) = null;
                if (sd.interface) |idx| {
                    if (idx >= defs.len) return false;
                    iface = defs[idx].clone();
                }
                delegates[j] = .{
                    .interface_name = sd.interface_name,
                    .interface = iface,
                    .expr = sd.expr,
                    .field_key = sd.field_key,
                };
            }
            c.supertype_delegates = delegates;
        }
        if (ci.enum_entries.len != 0) {
            const entries = try a.alloc(ClassDef.EnumEntry, ci.enum_entries.len);
            for (ci.enum_entries, 0..) |entry, j| {
                const v = (try valueFromImage(a, defs, entry.value)) orelse return false;
                entries[j] = .{ .name = entry.name, .value = v, .annotation_records = entry.annotation_records };
            }
            c.enum_entries = entries;
        }
    }

    for (img.class_table) |kv| {
        if (kv.v >= defs.len) return false;
        try out.classes.put(kv.k, defs[kv.v].clone());
    }
    // The defs slice holds the construction handles; the table's clones
    // keep the cells alive (the arena owns the memory either way).
    for (defs) |*def| def.deinit();

    for (img.body_prop_inits) |entry| try out.body_prop_inits.put(.{ .a = entry.a, .b = entry.b }, entry.func);
    for (img.instance_prop_getters) |entry| {
        try out.instance_prop_getters.put(.{ .a = entry.a, .b = entry.b }, entry.func);
        try out.getter_prop_names.put(entry.b, {});
    }
    for (img.instance_prop_setters) |entry| try out.instance_prop_setters.put(.{ .a = entry.a, .b = entry.b }, entry.func);
    for (img.instance_prop_private) |entry| try out.instance_prop_private.put(.{ .a = entry.a, .b = entry.b }, entry.func);
    for (img.parent_ctor_args) |entry| try out.parent_ctor_args.put(entry.name, @constCast(entry.funcs));
    for (img.parent_ctor_arg_names) |entry| try out.parent_ctor_arg_names.put(entry.name, entry.arg_names);
    for (img.init_blocks) |entry| try out.init_blocks.put(entry.name, @constCast(entry.funcs));
    try out.top_level_props.appendSlice(a, img.top_level_props);
    for (img.extension_props) |entry| {
        try out.extension_props.put(.{ .a = entry.a, .b = entry.b }, entry.func);
        // Owner-qualified keys carry a NUL separator; rebuild the gate set.
        if (std.mem.indexOfScalar(u8, entry.a, 0) != null) {
            try out.owner_keyed_ext_names.put(entry.b, {});
        }
    }
    for (img.nullable_ext_props) |entry| try out.nullable_ext_props.put(entry.name, entry.func);
    for (img.extension_prop_setters) |entry| {
        try out.extension_prop_setters.put(.{ .a = entry.a, .b = entry.b }, entry.func);
        if (std.mem.indexOfScalar(u8, entry.a, 0) != null) {
            try out.owner_keyed_ext_names.put(entry.b, {});
        }
    }
    for (img.extension_prop_delegates) |entry| try out.extension_prop_delegates.put(.{ .a = entry.a, .b = entry.b }, entry.func);
    try out.object_names.appendSlice(a, img.object_names);
    for (img.companion_singletons) |kv| try out.companion_singletons.put(kv.k, kv.v);
    try out.enum_entry_arg_inits.appendSlice(a, img.enum_entry_arg_inits);
    for (img.secondary_ctors) |entry| try out.secondary_ctors.put(entry.name, entry.entries);
    for (img.primary_ctor_default_thunks) |entry| try out.primary_ctor_default_thunks.put(entry.name, @constCast(entry.slots));
    for (img.class_delegates) |entry| try out.class_delegates.put(entry.name, entry.entries);
    for (img.func_defaults) |kv| try out.func_defaults.put(kv.k, @constCast(kv.v));
    for (img.enclosing_class) |kv| try out.enclosing_class.put(kv.k, kv.v);
    for (img.enum_entry_methods) |*entry| {
        var sub = Module.default(a);
        try moduleFromImage(a, &entry.module, &sub);
        const sub_ref = try ObjRef(Module).init(a, sub);
        try out.enum_entry_methods.put(.{ .a = entry.a, .b = entry.b }, .{ .module = sub_ref, .func = entry.func });
    }
    for (img.enum_entry_synth_class) |entry| try out.enum_entry_synth_class.put(.{ .a = entry.a, .b = entry.b }, entry.v);
    for (img.func_type_params) |kv| try out.func_type_params.put(kv.k, @constCast(kv.v));
    for (img.top_level_delegated_props) |k| try out.top_level_delegated_props.put(k, {});
    for (img.delegated_body_props) |p| try out.delegated_body_props.put(.{ .a = p.a, .b = p.b }, {});
    return true;
}

fn methodsFromImage(a: Allocator, imgs: []const MethodImage) Allocator.Error![]runtime.MethodDef {
    const out = try a.alloc(runtime.MethodDef, imgs.len);
    for (imgs, 0..) |m, i| {
        out[i] = .{
            .name = m.name,
            // The image stores `decl` as a `ForestField` already (lazy `.ref`
            // for forest methods, inline `.ptr` for synthetic ones); copy it.
            .decl = m.decl,
            .is_operator = m.is_operator,
            .is_open = m.is_open,
            .is_override = m.is_override,
            .is_abstract = m.is_abstract,
            .sam_lambda = null,
            .delegate_field = m.delegate_field,
            .ir_fn_id = m.ir_fn_id,
        };
    }
    return out;
}

fn scalarFromImage(v: ValueImage) Allocator.Error!?Value {
    return switch (v) {
        .Unit => Value.Unit,
        .Null => Value.Null,
        .Bool => |x| Value{ .Bool = x },
        .Int => |x| Value{ .Int = x },
        .Long => |x| Value{ .Long = x },
        .Short => |x| Value{ .Short = x },
        .Byte => |x| Value{ .Byte = x },
        .UInt => |x| Value{ .UInt = x },
        .ULong => |x| Value{ .ULong = x },
        .UShort => |x| Value{ .UShort = x },
        .UByte => |x| Value{ .UByte = x },
        .Double => |x| Value{ .Double = x },
        .Float => |x| Value{ .Float = x },
        .Char => |x| Value{ .Char = x },
        else => null,
    };
}

fn valueFromImage(a: Allocator, defs: []const ObjRef(ClassDef), v: ValueImage) Allocator.Error!?Value {
    switch (v) {
        .Str => |s| return Value{ .String = try runtime.strInit(a, s) },
        .Instance => |inst| {
            if (inst.class >= defs.len) return null;
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            try fields.ensureTotalCapacity(a, inst.fields.len);
            for (inst.fields) |f| {
                const fv = (try valueFromImage(a, defs, f.value)) orelse return null;
                try fields.append(a, .{ .name = f.name, .value = fv });
            }
            const copy = try ObjRef(InstanceData).init(a, .{
                .class = defs[inst.class].clone(),
                .fields = fields,
                .outer = null,
                .identity = inst.identity,
                .native_state = null,
                // The buffer belongs to the adoption arena; runtime growth
                // must re-buffer instead of freeing it across allocators.
                .fields_foreign = true,
            });
            return Value{ .Instance = copy };
        },
        else => return scalarFromImage(v),
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

const TestNode = struct {
    name: []const u8,
    children: []TestNode,
    tag: TestTag,
    weight: ?f64,
};

const TestTag = union(enum) {
    None,
    Label: []const u8,
    Count: u32,
};

fn encodeOne(comptime T: type, gpa: Allocator, value: *const T) ![]u8 {
    var e = Encoder.init(gpa);
    defer e.deinit();
    try encodeValue(T, &e, value);
    return e.out.toOwnedSlice(gpa);
}

fn decodeOne(comptime T: type, a: Allocator, bytes: []const u8) !T {
    var d = Decoder{ .a = a, .buf = bytes };
    var out: T = undefined;
    try decodeInto(T, &d, &out);
    try testing.expectEqual(bytes.len, d.pos);
    return out;
}

test "codec round-trips nested structs, unions, optionals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var kids = [_]TestNode{
        .{ .name = "left", .children = &.{}, .tag = .{ .Count = 41 }, .weight = null },
        .{ .name = "right", .children = &.{}, .tag = .None, .weight = 2.5 },
    };
    const root = TestNode{
        .name = "root",
        .children = &kids,
        .tag = .{ .Label = "lbl" },
        .weight = -1.0,
    };
    const bytes = try encodeOne(TestNode, a, &root);
    const got = try decodeOne(TestNode, a, bytes);
    try testing.expectEqualStrings("root", got.name);
    try testing.expectEqual(@as(usize, 2), got.children.len);
    try testing.expectEqualStrings("left", got.children[0].name);
    try testing.expectEqual(@as(u32, 41), got.children[0].tag.Count);
    try testing.expectEqual(@as(?f64, null), got.children[0].weight);
    try testing.expectEqualStrings("lbl", got.tag.Label);
    try testing.expectEqual(@as(f64, 2.5), got.children[1].weight.?);
}

test "codec preserves shared slices as one decoded slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Shared = struct { first: []const u32, second: []const u32 };
    const data = [_]u32{ 7, 8, 9 };
    const v = Shared{ .first = &data, .second = &data };
    const bytes = try encodeOne(Shared, a, &v);
    const got = try decodeOne(Shared, a, bytes);
    try testing.expectEqualSlices(u32, &data, got.first);
    try testing.expect(got.first.ptr == got.second.ptr);
}

test "codec preserves explicit receiver-lambda shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const func = ir.Func{
        .id = FuncId.from(0),
        .name = "<lambda>",
        .fqn = "<lambda>",
        .params = &.{},
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .lambda_receiver_shape_known = true,
        .lambda_has_receiver = true,
        .lambda_receiver_ty = "String",
    };
    const bytes = try encodeOne(ir.Func, a, &func);
    const got = try decodeOne(ir.Func, a, bytes);
    try testing.expect(got.lambda_receiver_shape_known);
    try testing.expect(got.lambda_has_receiver);
    try testing.expectEqualStrings("String", got.lambda_receiver_ty.?);
}

test "codec preserves both receivers of an exact member extension call" {
    const a = testing.allocator;
    const inst = ir.Inst{ .CallMember = .{
        .dst = ir.Reg.from(1),
        .receiver = ir.Reg.from(2),
        .name = ir.ConstId.from(3),
        .args = ir.Reg.from(4),
        .n_args = 0,
        .resolved = ir.FuncId.from(5),
        .dispatch_receiver = ir.Reg.from(6),
    } };
    const bytes = try encodeOne(ir.Inst, a, &inst);
    defer a.free(bytes);
    const got = try decodeOne(ir.Inst, a, bytes);
    try testing.expect(got == .CallMember);
    try testing.expectEqual(ir.Reg.from(2), got.CallMember.receiver);
    try testing.expectEqual(ir.FuncId.from(5), got.CallMember.resolved.?);
    try testing.expectEqual(ir.Reg.from(6), got.CallMember.dispatch_receiver.?);
}

test "module image preserves linked identities with lazy function headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var source = Module.default(a);
    defer source.deinit(a);
    const element = try source.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Element",
        .fqn = "sample.Element",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = &.{"T"},
        .type_param_variance = &.{.Out},
        .receiver_abi = .specialized,
    });
    const abstract_all = FuncId.from(10);
    const element_all = FuncId.from(11);
    const min = FuncId.from(12);
    try source.registerMemberDecl(a, "sample.Modifier", "all", abstract_all);
    try source.registerMethodSlotTarget(
        element,
        ir.MethodSlotId.fromFunc(abstract_all),
        element_all,
    );
    try source.func_index.append(a, .{ .name = "min", .id = min });
    try source.decl_sigs.put(min.int(), .{
        .receiver_ty = .{ .name = "IntArray", .nullable = false, .args = &.{} },
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .kind = .top_level_extension,
        .has_body = true,
        .host_symbol = "kotlin.IntArray.min",
    });
    try source.registry.type_alias_types.put("Names", .{
        .type_params = &.{},
        .target = .{
            .name = "List",
            .nullable = false,
            .args = @constCast(&[_]ir.TypeRef{.{
                .name = "String",
                .nullable = false,
                .args = &.{},
            }}),
        },
    });
    try source.registry.file_modules.put(FileId.from(7), 3);

    var image: ModuleImage = undefined;
    try testing.expect(try moduleToImage(a, &source, &image));
    image.funcs = &.{};
    const bytes = try encodeOne(ModuleImage, a, &image);
    const decoded = try decodeOne(ModuleImage, a, bytes);

    var loaded = Module.default(a);
    defer loaded.deinit(a);
    try moduleFromImage(a, &decoded, &loaded);

    try testing.expectEqualSlices(
        FuncId,
        &.{abstract_all},
        loaded.memberDecls("sample.Modifier", "all"),
    );
    try testing.expectEqual(
        element_all,
        loaded.methodSlotTarget(element, ir.MethodSlotId.fromFunc(abstract_all)).?,
    );
    try testing.expect(loaded.extCouldApply(a, "IntArray", "min", 0));
    try testing.expect(!loaded.extCouldApply(a, "String", "min", 0));
    try testing.expectEqualStrings(
        "kotlin.IntArray.min",
        loaded.decl_sigs.get(min.int()).?.host_symbol.?,
    );
    try testing.expectEqual(ast.Variance.Out, loaded.classes.items[element.int()].type_param_variance[0]);
    try testing.expectEqual(runtime.ReceiverAbi.specialized, loaded.classes.items[element.int()].receiver_abi);
    const alias = loaded.registry.type_alias_types.get("Names").?;
    try testing.expectEqualStrings("List", alias.target.name);
    try testing.expectEqualStrings("String", alias.target.args[0].name);
    try testing.expectEqual(
        @as(u32, 3),
        loaded.registry.file_modules.get(FileId.from(7)).?,
    );
}

test "codec resolves watched AST pointers to the decoded tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A decl slice plus an external pointer at one of its interior
    // functions — the shape ClassDef method decls and inline-fn ids have.
    const sp = Span.init(FileId.from(0), 0, 0);
    const fn_decl = ast.Function{
        .name = .{ .name = "f", .span = sp },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = null,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = sp,
    };
    var decls = [_]ast.Decl{.{ .Function = fn_decl }};
    const Holder = struct { decls: []ast.Decl, ref: *const ast.Function };
    const v = Holder{ .decls = &decls, .ref = &decls[0].Function };
    const bytes = try encodeOne(Holder, a, &v);
    const got = try decodeOne(Holder, a, bytes);
    try testing.expectEqualStrings("f", got.ref.name.name);
    // The external pointer aliases the decoded decl, not a copy.
    try testing.expect(got.ref == &got.decls[0].Function);
}

test "codec resolves an external pointer aliasing a boxed Param default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sp = Span.init(FileId.from(0), 0, 0);
    var def_expr = ast.Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = sp } };
    var params = [_]ast.Param{.{
        .name = .{ .name = "x", .span = sp },
        .ty = .{ .name = .{ .name = "Int", .span = sp }, .nullable = false, .span = sp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .default = &def_expr,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = sp,
    }};
    const fn_decl = ast.Function{
        .name = .{ .name = "f", .span = sp },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &params,
        .return_type = null,
        .body = null,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = sp,
    };
    var decls = [_]ast.Decl{.{ .Function = fn_decl }};
    // `ref` aliases the param's default Expr by pointer — the shape
    // `ClassParamDef.default`/`parent_ctor_args` have into the AST forest.
    const Holder = struct { decls: []ast.Decl, ref: *const ast.Expr };
    const v = Holder{ .decls = &decls, .ref = &def_expr };
    const bytes = try encodeOne(Holder, a, &v);
    const got = try decodeOne(Holder, a, bytes);
    try testing.expect(got.ref == got.decls[0].Function.params[0].default.?);
    try testing.expectEqual(@as(i128, 7), got.ref.IntLit.value);
}

test "per-decl self-contained sections decode standalone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sp = Span.init(FileId.from(0), 0, 0);

    // Two top-level function decls; bake each self-contained (fresh registry)
    // into one buffer, recording offsets — exactly the per-decl section bake.
    const names = [_][]const u8{ "alpha", "beta" };
    var decls: [2]ast.Decl = undefined;
    for (&decls, names) |*d, nm| {
        d.* = .{ .Function = .{
            .name = .{ .name = nm, .span = sp },
            .receiver_type = null,
            .type_params = &.{},
            .where_bounds = &.{},
            .params = &.{},
            .return_type = null,
            .body = null,
            .is_open = false,
            .is_override = false,
            .is_abstract = false,
            .is_operator = false,
            .is_inline = false,
            .is_infix = false,
            .is_tailrec = false,
            .is_suspend = false,
            .is_expect = false,
            .is_actual = false,
            .visibility = .Public,
            .annotations = &.{},
            .span = sp,
        } };
    }
    var enc = Encoder.init(a);
    defer enc.deinit();
    var offsets: [2]u32 = undefined;
    for (&decls, 0..) |*d, i| {
        offsets[i] = @intCast(enc.out.items.len);
        enc.resetRegistry();
        try encodeValue(ast.Decl, &enc, d);
    }
    const section = enc.out.items;
    // Decode each standalone from its offset and check it round-trips.
    for (offsets, names) |off, nm| {
        const got = decodeLiftedDecl(a, section, off) orelse return error.TestUnexpectedResult;
        try testing.expect(got == .Function);
        try testing.expectEqualStrings(nm, got.Function.name.name);
    }
}

test "forest resolver resolves a ForestRef to the decoded node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sp = Span.init(FileId.from(0), 0, 0);

    // One decl: a function (the decl's watched node 0, registered first).
    var decl = ast.Decl{ .Function = .{
        .name = .{ .name = "f", .span = sp },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = .{ .Expr = .{ .IntLit = .{ .value = 5, .kind = .Int, .span = sp } } },
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = sp,
    } };
    var enc = Encoder.init(a);
    defer enc.deinit();
    enc.resetRegistry();
    try encodeValue(ast.Decl, &enc, &decl);
    // Capture the bake-time ForestRef for the function node (ordinal in the
    // decl's fresh registry) — node 0 is the Function (registered first).
    const fn_ord: u32 = enc.nodes.get(.{ .addr = @intFromPtr(&decl.Function), .ty = typeId(ast.Function) }).?;

    const offsets = [_]u32{0};
    const base = runtime.forest.setSection(enc.out.items, &offsets, a, decodeLiftedDeclReg);
    const got = runtime.forest.resolveFunction(.{ .decl = base, .ord = fn_ord }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("f", got.name.name);
    // A second resolve hits the memo (same decoded pointer).
    const got2 = runtime.forest.resolveFunction(.{ .decl = base, .ord = fn_ord }).?;
    try testing.expect(got == got2);
}

test "codec floats are little-endian IEEE-754 bits on the wire" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1.5f64 = 0x3FF8000000000000; the wire bytes must be the little-endian
    // bit pattern regardless of host byte order.
    const v: f64 = 1.5;
    const bytes = try encodeOne(f64, a, &v);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0xf8, 0x3f }, bytes);
    var d = Decoder{ .a = a, .buf = bytes };
    var out: f64 = undefined;
    try decodeInto(f64, &d, &out);
    try testing.expectEqual(v, out);
}

test "codec rejects truncated input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: []const u8 = "hello";
    const bytes = try encodeOne([]const u8, a, &v);
    var d = Decoder{ .a = a, .buf = bytes[0 .. bytes.len - 2] };
    var out: []const u8 = undefined;
    try testing.expectError(error.Malformed, decodeInto([]const u8, &d, &out));
}
