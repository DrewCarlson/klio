//! The value codec the base image is written in: postcard style (varints,
//! length-prefixed sequences, in-order struct fields) plus a shared-graph
//! protocol.
//!
//! - Every slice is a define/backref. The first encode of an `(address, length)`
//!   writes its elements inline and registers it; a later encode writes a
//!   backref. The decoder's registry is in define order, so sharing survives.
//! - A closed set of AST node types is watched: each registers in traversal
//!   order as it encodes and decodes, and a pointer to one encodes as a registry
//!   reference, so edges into a decoded tree land on its nodes, interior
//!   addresses included.
//! - `[]const u8` decodes as a borrow, so the buffer must outlive the value.

const std = @import("std");

const ir = @import("ir");
const ast = @import("ast");

const span = @import("span");

const Allocator = std.mem.Allocator;
const Span = span.Span;
const FileId = span.FileId;
const FuncId = ir.FuncId;

/// Bump on any change to the encoded layout or to the types it reaches. A
/// mismatch refuses the load and the caller rebakes.
pub const FORMAT_VERSION: u32 = 94;

// Watched AST node types: pointed at from the IR.

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

fn isForestField(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "is_forest_field");
}

/// Encode a `ForestField`: tag 0 plus `(decl, ord)` for a reference into a
/// lifted-declaration forest, else tag 1 plus the node inline.
fn encodeForestField(comptime T: type, e: *Encoder, value: *const T) Allocator.Error!void {
    const Child = T.Child;
    switch (value.*) {
        .ref => |r| {
            try e.varint(0);
            try e.varint(r.decl);
            try e.varint(r.ord);
        },
        .ptr => |p| {
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
        out.* = .{ .ref = .{ .decl = decl, .ord = ord } };
    } else {
        const ptr = try d.a.create(Child);
        try decodeInto(Child, d, ptr);
        out.* = .{ .ptr = ptr };
    }
}

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

    /// Clear the shared-graph registries, keeping the buffer, so the next value
    /// encodes self-contained.
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

/// Encode one value by const pointer, so registered addresses are the originals.
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
        // order, so an image baked on one host is consumable on any other.
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
                    // Tag 1: the empty slice, no registry entry.
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
        .array => |arr| for (value) |*elem| try encodeValue(arr.child, e, elem),
        else => @compileError("unsupported type in image encode: " ++ @typeName(T)),
    }
}

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

/// Decode one value in place through `out`, so every watched node and defined
/// slice registers at its final address.
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
                // Optional pointers and slices pack `null` into the pointer bits
                // with no tag, so decode into a temporary and assign whole.
                .pointer => {
                    var tmp: o.child = undefined;
                    try decodeInto(o.child, d, &tmp);
                    out.* = tmp;
                },
                // Non-pointer optionals carry a tag; a non-null wrapper set first
                // gives `&out.*.?` the stable address registration needs.
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
        .array => |arr| for (out) |*elem| try decodeInto(arr.child, d, elem),
        else => @compileError("unsupported type in image decode: " ++ @typeName(T)),
    }
}

/// Decodes a function's `blocks`, encoded on their own by `encodeBytes`, at
/// `offset` in `section`, into `a`. The module keeps the result on its `Func`,
/// so every call decodes.
pub fn decodeFuncBlocks(a: Allocator, section: []const u8, offset: u32) ?[]ir.Block {
    var d = Decoder{ .a = a, .buf = section, .pos = offset };
    var blocks: []ir.Block = undefined;
    decodeInto([]ir.Block, &d, &blocks) catch return null;
    return blocks;
}

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

/// Encodes one value of any type the codec handles, self-contained, into an
/// owned `gpa` buffer. `decodeBytes` reads it back.
pub fn encodeBytes(comptime T: type, gpa: Allocator, value: *const T) Allocator.Error![]u8 {
    var e = Encoder.init(gpa);
    defer e.deinit();
    try encodeValue(T, &e, value);
    return e.out.toOwnedSlice(gpa);
}

pub const CodecError = DecodeError;

/// Decodes one `T` from the front of `bytes` into `a`. Its `[]const u8`
/// values point into `bytes`, which must outlive them.
pub fn decodeBytes(comptime T: type, a: Allocator, bytes: []const u8) CodecError!T {
    var d = Decoder{ .a = a, .buf = bytes };
    var out: T = undefined;
    try decodeInto(T, &d, &out);
    return out;
}

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

test "codec round-trips fixed arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const A = struct { ids: [3]?u32, name: []const u8 };
    const v: A = .{ .ids = .{ 7, null, 9 }, .name = "x" };
    const bytes = try encodeBytes(A, testing.allocator, &v);
    defer testing.allocator.free(bytes);
    const back = try decodeBytes(A, arena.allocator(), bytes);
    try testing.expectEqual(@as(?u32, 7), back.ids[0]);
    try testing.expectEqual(@as(?u32, null), back.ids[1]);
    try testing.expectEqual(@as(?u32, 9), back.ids[2]);
    try testing.expectEqualStrings("x", back.name);
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

    const extra = ir.FuncExtra{ .lambda_receiver_ty = "String" };
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
        .extra = &extra,
    };
    const bytes = try encodeOne(ir.Func, a, &func);
    const got = try decodeOne(ir.Func, a, bytes);
    defer if (got.extra) |e| a.destroy(e);
    try testing.expect(got.lambda_receiver_shape_known);
    try testing.expect(got.lambda_has_receiver);
    try testing.expectEqualStrings("String", got.x().lambda_receiver_ty.?);
}

test "codec resolves watched AST pointers to the decoded tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    try testing.expect(got.ref == &got.decls[0].Function);
}

test "codec carries node ids and a call's labels and type arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fun f() { g(x = 1); h<Int>(2); "$y" }
    const sp = Span.init(FileId.from(0), 0, 0);
    var g_segs = [_]ast.Ident{.{ .name = "g", .span = sp }};
    var h_segs = [_]ast.Ident{.{ .name = "h", .span = sp }};
    var g_callee = ast.Expr{ .Path = .{ .segments = &g_segs, .span = sp } };
    var h_callee = ast.Expr{ .Path = .{ .segments = &h_segs, .span = sp } };
    var g_args = [_]ast.Expr{.{ .IntLit = .{ .value = 1, .kind = .Int, .span = sp } }};
    var h_args = [_]ast.Expr{.{ .IntLit = .{ .value = 2, .kind = .Int, .span = sp } }};
    var g_names = [_]?[]const u8{"x"};
    var h_types = [_]ast.TypeRef{.{ .name = .{ .name = "Int", .span = sp }, .nullable = false, .span = sp, .type_args = &.{}, .function = null, .definitely_non_null = false }};
    const g_extra = ast.CallExtra{ .arg_names = &g_names };
    const h_extra = ast.CallExtra{ .arg_names = ast.positionalNames(1).?, .type_args = &h_types };
    var parts = [_]ast.StringPart{.{ .ShortInterp = .{ .name = "y", .span = sp } }};
    var stmts = [_]ast.Stmt{
        .{ .Expr = .{ .Call = .{ .callee = &g_callee, .args = &g_args, .extra = &g_extra, .is_infix = false, .span = sp } } },
        .{ .Expr = .{ .Call = .{ .callee = &h_callee, .args = &h_args, .extra = &h_extra, .is_infix = false, .span = sp } } },
        .{ .Expr = .{ .StringTemplate = .{ .parts = &parts, .span = sp } } },
    };
    var decls = [_]ast.Decl{.{ .Function = .{
        .name = .{ .name = "f", .span = sp },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = .{ .Block = .{ .stmts = &stmts, .span = sp } },
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
    } }};
    var file = ast.KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = sp };
    ast.assignIds(&file);

    const bytes = try encodeOne(ast.KotlinFile, a, &file);
    const got = try decodeOne(ast.KotlinFile, a, bytes);
    try testing.expectEqual(file.node_count, got.node_count);
    try testing.expect(try ast.checkIds(testing.allocator, &got, .{ .require_all = true }) == null);
    const want_ids = try ast.node_ids.collect(testing.allocator, &file);
    defer testing.allocator.free(want_ids);
    const got_ids = try ast.node_ids.collect(testing.allocator, &got);
    defer testing.allocator.free(got_ids);
    try testing.expectEqual(want_ids.len, got_ids.len);
    for (want_ids, got_ids) |w, g| try testing.expectEqual(w.id, g.id);

    const body = got.decls[0].Function.body.?.Block.stmts;
    try testing.expectEqualStrings("x", body[0].Expr.Call.argNames()[0].?);
    try testing.expectEqual(@as(usize, 1), body[1].Expr.Call.argNames().len);
    try testing.expectEqualStrings("Int", body[1].Expr.Call.typeArgs()[0].name.name);
    try testing.expectEqual(parts[0].ShortInterp.id, body[2].Expr.StringTemplate.parts[0].ShortInterp.id);
}

test "codec resolves an external pointer aliasing a boxed Param default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sp = Span.init(FileId.from(0), 0, 0);
    var def_expr = ast.Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = sp } };
    var params = [_]ast.Param{.{
        .name = .{ .name = "x", .span = sp },
        .ty = .{ .name = .{ .name = "Int", .span = sp }, .nullable = false, .span = sp, .type_args = &.{}, .function = null, .definitely_non_null = false },
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
    const Holder = struct { decls: []ast.Decl, ref: *const ast.Expr };
    const v = Holder{ .decls = &decls, .ref = &def_expr };
    const bytes = try encodeOne(Holder, a, &v);
    const got = try decodeOne(Holder, a, bytes);
    try testing.expect(got.ref == got.decls[0].Function.params[0].default.?);
    try testing.expectEqual(@as(i128, 7), got.ref.IntLit.value);
}

test "codec floats are little-endian IEEE-754 bits on the wire" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1.5f64 = 0x3FF8000000000000, written little-endian whatever the host.
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
