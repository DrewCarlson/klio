//! Lazy stdlib-AST-forest resolver. The baked image holds each top-level
//! `lifted_decls[i]` as a self-contained section with its own node registry, so
//! `built`/`module` store `ForestRef`s and resolve them here on first touch:
//! the owning decl decodes once, memoised, and `ord` indexes its decode-order
//! registry. The decode hook is injected by the image loader.

const std = @import("std");
const ast = @import("ast");
const SpinMutex = @import("objcell.zig").SpinMutex;

/// `ord` indexes the decl's decode-order registry, stable because decode
/// replays the bake traversal.
pub const ForestRef = struct { decl: u32, ord: u32 };

/// Either eager (`ptr`, the build path) or lazy (`ref`, the image load).
pub fn ForestField(comptime T: type) type {
    return union(enum) {
        ptr: *const T,
        ref: ForestRef,

        const Self = @This();
        /// Read by the image codec to encode this union as a forest reference
        /// rather than through the generic union path.
        pub const is_forest_field = true;
        pub const Child = T;

        pub fn fromPtr(p: *const T) Self {
            return .{ .ptr = p };
        }
        pub fn fromRef(r: ForestRef) Self {
            return .{ .ref = r };
        }
        /// Decodes and memoises the owning decl on first lazy access.
        pub fn get(self: Self) *const T {
            return switch (self) {
                .ptr => |p| p,
                .ref => |r| @ptrFromInt(resolveNode(r).?),
            };
        }
    };
}

pub const DeclReg = struct { decl: *const ast.Decl, nodes: []const usize };

const DecodeFn = *const fn (std.mem.Allocator, []const u8, u32) ?DeclReg;

const Section = struct {
    bytes: []const u8,
    offsets: []const u32,
    arena: std.mem.Allocator,
    decode: DecodeFn,
    memo: []?DeclReg,
};

/// A ref's `decl` index carries its owning image's slot in the top byte, so
/// bases from several images coexist. Slot 0 matches the single-image encoding,
/// and refs are rebased at image load, never at bake.
pub const SLOT_SHIFT: u5 = 24;
const LOCAL_MASK: u32 = (@as(u32, 1) << SLOT_SHIFT) - 1;
const MAX_SECTIONS = 64;

var sections: [MAX_SECTIONS]?Section = @splat(null);
var next_slot: u32 = 0;
var mutex: SpinMutex = .{};

/// The loader reserves before decoding its root, so refs rebase as they decode.
/// Null when the registry is full, which fails the load back to a source build.
pub fn reserveSlot() ?u32 {
    mutex.lock();
    defer mutex.unlock();
    if (next_slot >= MAX_SECTIONS) return null;
    const s = next_slot;
    next_slot += 1;
    return s;
}

pub fn slotBase(slot: u32) u32 {
    return slot << SLOT_SHIFT;
}

/// Allocates the memo table, one entry per decl.
pub fn fillSlot(slot: u32, sec: []const u8, offs: []const u32, a: std.mem.Allocator, decode: DecodeFn) void {
    std.debug.assert(offs.len <= LOCAL_MASK);
    const m: []?DeclReg = a.alloc(?DeclReg, offs.len) catch &.{};
    for (m) |*e| e.* = null;
    mutex.lock();
    defer mutex.unlock();
    sections[slot] = .{ .bytes = sec, .offsets = offs, .arena = a, .decode = decode, .memo = m };
}

pub fn setSection(sec: []const u8, offs: []const u32, a: std.mem.Allocator, decode: DecodeFn) u32 {
    const slot = reserveSlot() orelse return 0;
    fillSlot(slot, sec, offs, a, decode);
    return slotBase(slot);
}

pub fn active() bool {
    return next_slot != 0;
}

fn ensureDecl(idx: u32) ?DeclReg {
    const slot = idx >> SLOT_SHIFT;
    const local = idx & LOCAL_MASK;
    if (slot >= MAX_SECTIONS) return null;
    const sec = if (sections[slot]) |*s| s else return null;
    if (local >= sec.memo.len) return null;
    if (sec.memo[local]) |dr| return dr;
    mutex.lock();
    defer mutex.unlock();
    if (sec.memo[local]) |dr| return dr; // lost the race; another thread decoded it
    const dr = sec.decode(sec.arena, sec.bytes, sec.offsets[local]) orelse return null;
    sec.memo[local] = dr;
    return dr;
}

pub fn resolveNode(ref: ForestRef) ?usize {
    const dr = ensureDecl(ref.decl) orelse return null;
    if (ref.ord >= dr.nodes.len) return null;
    return dr.nodes[ref.ord];
}

pub fn resolveExpr(ref: ForestRef) ?*const ast.Expr {
    return @ptrFromInt(resolveNode(ref) orelse return null);
}
pub fn resolveFunction(ref: ForestRef) ?*const ast.Function {
    return @ptrFromInt(resolveNode(ref) orelse return null);
}
pub fn resolveAccessor(ref: ForestRef) ?*const ast.Accessor {
    return @ptrFromInt(resolveNode(ref) orelse return null);
}
pub fn resolveBlock(ref: ForestRef) ?*const ast.Block {
    return @ptrFromInt(resolveNode(ref) orelse return null);
}
pub fn resolveSecondaryCtor(ref: ForestRef) ?*const ast.SecondaryCtor {
    return @ptrFromInt(resolveNode(ref) orelse return null);
}
