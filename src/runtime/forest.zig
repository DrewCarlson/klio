//! Lazy stdlib-AST-forest resolver.
//!
//! The baked image holds each top-level `lifted_decls[i]` as a self-contained
//! section (a fresh node registry; the deferred-`FunctionBody` pattern
//! generalised to a whole decl). Instead of materialising the whole forest at
//! load, `built`/`module` store `ForestRef`s — `(decl, ord)` — into the forest,
//! and resolve them here on first runtime touch: the owning decl is decoded
//! once (memoised), and `ord` indexes its decode-order node registry.
//!
//! The decode function is injected by the image loader (`setSection`) so this
//! low runtime module needs no dependency on the codec, mirroring the
//! deferred-body decoder hook in `ir/lower/inline_state.zig`.

const std = @import("std");
const ast = @import("ast");
const SpinMutex = @import("objcell.zig").SpinMutex;

/// A reference to a watched AST node in the lazy forest: `decl` selects the
/// top-level decl section, `ord` is the node's index in that decl's
/// decode-order registry (stable: decode replays the bake traversal exactly).
pub const ForestRef = struct { decl: u32, ord: u32 };

/// A pointer to a forest AST node that is either eager (`ptr`, set by the build
/// / runtime-class / fallback paths into live AST) or lazy (`ref`, set by the
/// image load — resolved on first `get()`). Lets one field serve both the
/// image-backed base and the freshly-built base.
pub fn ForestField(comptime T: type) type {
    return union(enum) {
        ptr: *const T,
        ref: ForestRef,

        const Self = @This();
        /// Marker + element type read by the image codec to encode/decode this
        /// union as a forest reference (or an inline fallback) rather than via
        /// the generic union path.
        pub const is_forest_field = true;
        pub const Child = T;

        pub fn fromPtr(p: *const T) Self {
            return .{ .ptr = p };
        }
        pub fn fromRef(r: ForestRef) Self {
            return .{ .ref = r };
        }
        /// Resolve to the node pointer, decoding+memoising the owning decl on
        /// first lazy access.
        pub fn get(self: Self) *const T {
            return switch (self) {
                .ptr => |p| p,
                .ref => |r| @ptrFromInt(resolveNode(r).?),
            };
        }
    };
}

/// A decoded decl plus its node-ordinal table (`nodes[ord]` = node address).
pub const DeclReg = struct { decl: *const ast.Decl, nodes: []const usize };

const DecodeFn = *const fn (std.mem.Allocator, []const u8, u32) ?DeclReg;

/// One loaded image's forest: its per-decl section, offsets, the process-
/// lifetime arena decoded decls live in, the decode hook, and the memo.
const Section = struct {
    bytes: []const u8,
    offsets: []const u32,
    arena: std.mem.Allocator,
    decode: DecodeFn,
    memo: []?DeclReg,
};

/// A ref's `decl` index carries its owning image's slot in the top byte
/// (`(slot << SLOT_SHIFT) | local`), so bases loaded from several images
/// coexist in one process — the parity harness loads both stdlib gate
/// variants; the CLI loads one. Slot 0's refs are numerically identical to
/// the single-image encoding, and refs are rebased from image-local form at
/// image load, never at bake.
pub const SLOT_SHIFT: u5 = 24;
const LOCAL_MASK: u32 = (@as(u32, 1) << SLOT_SHIFT) - 1;
const MAX_SECTIONS = 64;

var sections: [MAX_SECTIONS]?Section = @splat(null);
var next_slot: u32 = 0;
var mutex: SpinMutex = .{};

/// Claim the next image slot. The loader reserves before decoding its root so
/// refs can be rebased as they decode, and fills the slot once the section
/// tables are known. Null when the registry is full — the load then fails and
/// the caller falls back to the source build.
pub fn reserveSlot() ?u32 {
    mutex.lock();
    defer mutex.unlock();
    if (next_slot >= MAX_SECTIONS) return null;
    const s = next_slot;
    next_slot += 1;
    return s;
}

/// The `decl`-index base for refs owned by `slot`.
pub fn slotBase(slot: u32) u32 {
    return slot << SLOT_SHIFT;
}

/// Install a reserved slot's forest section, offset table, arena, and decode
/// function. Allocates the memo table (one entry per decl).
pub fn fillSlot(slot: u32, sec: []const u8, offs: []const u32, a: std.mem.Allocator, decode: DecodeFn) void {
    std.debug.assert(offs.len <= LOCAL_MASK);
    const m: []?DeclReg = a.alloc(?DeclReg, offs.len) catch &.{};
    for (m) |*e| e.* = null;
    mutex.lock();
    defer mutex.unlock();
    sections[slot] = .{ .bytes = sec, .offsets = offs, .arena = a, .decode = decode, .memo = m };
}

/// Reserve + fill in one step for callers that need no rebase window (tests,
/// single-image tools). Returns the slot's decl-index base.
pub fn setSection(sec: []const u8, offs: []const u32, a: std.mem.Allocator, decode: DecodeFn) u32 {
    const slot = reserveSlot() orelse return 0;
    fillSlot(slot, sec, offs, a, decode);
    return slotBase(slot);
}

/// Whether any forest section is installed (some lazy path is active).
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

/// Resolve a forest ref to the raw node address, decoding+memoising the owning
/// decl on first touch. Null on a malformed image / out-of-range ref.
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
