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

var section: []const u8 = &.{};
var offsets: []const u32 = &.{};
var arena: std.mem.Allocator = undefined;
var decode_fn: ?DecodeFn = null;
var memo: []?DeclReg = &.{};
var mutex: SpinMutex = .{};

/// Install the loaded image's forest section, offset table, the process-
/// lifetime arena decoded decls live in, and the decode function. Allocates the
/// memo table (one slot per decl). Safe to call with an empty section (the
/// resolver then never resolves — the eager path is in use).
pub fn setSection(sec: []const u8, offs: []const u32, a: std.mem.Allocator, decode: DecodeFn) void {
    section = sec;
    offsets = offs;
    arena = a;
    decode_fn = decode;
    memo = a.alloc(?DeclReg, offs.len) catch &.{};
    for (memo) |*m| m.* = null;
}

/// Whether a forest section is installed (the lazy path is active).
pub fn active() bool {
    return decode_fn != null and offsets.len != 0;
}

fn ensureDecl(idx: u32) ?DeclReg {
    if (idx >= memo.len) return null;
    if (memo[idx]) |dr| return dr;
    mutex.lock();
    defer mutex.unlock();
    if (memo[idx]) |dr| return dr; // lost the race; another thread decoded it
    const decode = decode_fn orelse return null;
    const dr = decode(arena, section, offsets[idx]) orelse return null;
    memo[idx] = dr;
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
