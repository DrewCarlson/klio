//! AST lifting helpers used by the IR module builder.
//!
//! These transform anonymous-object / nested-class / accessor-body
//! AST shapes before lowering. The full `build_module` lowering driver
//! is a separate workstream; the helpers here are filled in alongside
//! it. The pure `field` → `this.<backing>` rewrite is implemented; the
//! recursive class/object lifts are wired as the lowering driver grows.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const Allocator = std.mem.Allocator;
const Expr = ast.Expr;
const Block = ast.Block;
const Ident = ast.Ident;
const Class = ast.Class;
const ObjectDecl = ast.ObjectDecl;
const Decl = ast.Decl;
const Span = span.Span;
const FileId = span.FileId;

const dummySpan = Span.init(FileId.from(0), 0, 0);

/// Replace every bare `field` identifier in `expr` with
/// `this.__klio_field__<prop_name>`. Used by accessor-body lowering so
/// the IR thunk reads / writes the backing field on the receiver.
///
/// Returns a freshly-allocated rewritten expression owned by `allocator`.
pub fn substituteFieldWithThis(allocator: Allocator, prop_name: []const u8, expr: *const Expr) Allocator.Error!*Expr {
    const out = try allocator.create(Expr);
    out.* = expr.*;
    try walkField(allocator, out, prop_name);
    return out;
}

/// Rewrite a bare `field` reference to a synthetic `this.__klio_field__<prop>`
/// member access. The Vm's get_field / set_field detect the
/// `__klio_field__` prefix and skip the custom-getter/setter dispatch.
pub fn walkField(allocator: Allocator, e: *Expr, prop: []const u8) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "field")) {
                const backing = try std.fmt.allocPrint(allocator, "__klio_field__{s}", .{prop});
                const this_segs = try allocator.alloc(Ident, 1);
                this_segs[0] = .{ .name = "this", .span = dummySpan };
                const recv = try allocator.create(Expr);
                recv.* = .{ .Path = .{ .segments = this_segs, .span = dummySpan } };
                e.* = .{ .Member = .{
                    .receiver = recv,
                    .name = .{ .name = backing, .span = dummySpan },
                    .safe = false,
                    .span = dummySpan,
                } };
                return;
            }
        },
        .Call => |c| {
            try walkField(allocator, c.callee, prop);
            for (c.args) |*a| try walkField(allocator, a, prop);
        },
        .Member => |m| try walkField(allocator, m.receiver, prop),
        .Binary => |b| {
            try walkField(allocator, b.lhs, prop);
            try walkField(allocator, b.rhs, prop);
        },
        else => {},
    }
}

/// Recursively lift nested class declarations to top level so the IR's
/// flat class table resolves `NewInstance` lookups. Filled in alongside
/// the `build_module` lowering driver.
pub fn liftClassRecursive() void {}

/// Rewrite a `field` backing reference inside an accessor block. Filled
/// in alongside the lowering driver.
pub fn rewriteBlockField() void {}

/// Collect the qualified supertype names actually used in a class body.
/// Filled in alongside the lowering driver.
pub fn collectUsedQualifiedSupertypes() void {}

/// Collect the member names visible from an enclosing scope. Filled in
/// alongside the lowering driver.
pub fn collectEnclosingMemberNames() void {}

/// Synthesize a `Class` declaration from an `object` declaration so it
/// can be lowered through the normal class path. Filled in alongside the
/// lowering driver.
pub fn synthesizeClassFromObject() void {}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}
