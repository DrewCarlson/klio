//! Deep copies of AST subtrees, for a pass that writes into a tree its caller
//! still reads. Strings and label lists stay shared, as do the shared
//! positional call boxes; every other pointer and slice is copied. Ids are
//! copied as they are, so the copy must replace the original in its file.

const std = @import("std");
const ast = @import("ast.zig");
const span_mod = @import("span");

const Allocator = std.mem.Allocator;

pub fn clone(allocator: Allocator, comptime T: type, v: *const T) Allocator.Error!T {
    var out: T = v.*;
    try copyChildren(allocator, T, &out);
    return out;
}

fn copyChildren(a: Allocator, comptime T: type, v: *T) Allocator.Error!void {
    if (comptime isLeaf(T)) return;
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| try copyChildren(a, f.type, &@field(v.*, f.name)),
        .@"union" => switch (v.*) {
            inline else => |*payload| try copyChildren(a, @TypeOf(payload.*), payload),
        },
        .optional => |o| if (v.*) |inner| {
            var copy: o.child = inner;
            try copyChildren(a, o.child, &copy);
            v.* = copy;
        },
        .pointer => |p| switch (p.size) {
            .one => {
                if (p.child == ast.CallExtra and ast.isSharedCallExtra(v.*)) return;
                const copy = try a.create(p.child);
                copy.* = v.*.*;
                try copyChildren(a, p.child, copy);
                v.* = copy;
            },
            .slice => {
                if (v.len == 0) return;
                const copy = try a.alloc(p.child, v.len);
                @memcpy(copy, v.*);
                for (copy) |*e| try copyChildren(a, p.child, e);
                v.* = copy;
            },
            else => @compileError("unexpected pointer in an AST node: " ++ @typeName(T)),
        },
        else => @compileError("unexpected type in an AST node: " ++ @typeName(T)),
    }
}

/// Holds no node: scalars, strings and lists of optional strings.
fn isLeaf(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => true,
        .optional => |o| isLeaf(o.child),
        .pointer => |p| p.size == .slice and isLeaf(p.child),
        else => false,
    };
}

test "a clone shares no node with its original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = span_mod.FileId.from(0);
    const lit = try ast.box(a, ast.Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = .init(f, 4, 5), .id = .from(3) } });
    var segs = [_]ast.Ident{.{ .name = "g", .span = .init(f, 0, 1) }};
    const callee = try ast.box(a, ast.Expr{ .Path = .{ .segments = &segs, .span = .init(f, 0, 1), .id = .from(2) } });
    const args = try a.alloc(ast.Expr, 1);
    args[0] = lit.*;
    var stmts = [_]ast.Stmt{.{ .Expr = .{ .Call = .{ .callee = callee, .args = args, .extra = ast.positionalExtra(1), .is_infix = false, .span = .init(f, 0, 6), .id = .from(1) } } }};
    const body = ast.FunctionBody{ .Block = .{ .stmts = &stmts, .span = .init(f, 0, 6) } };

    const copy = try clone(a, ast.FunctionBody, &body);
    const call = &copy.Block.stmts[0].Expr.Call;
    try std.testing.expect(copy.Block.stmts.ptr != body.Block.stmts.ptr);
    try std.testing.expect(call.callee != callee);
    try std.testing.expect(call.args.ptr != args.ptr);
    try std.testing.expectEqual(ast.NodeId.from(1), call.id);
    try std.testing.expectEqual(ast.NodeId.from(3), call.args[0].id());
    // The shared positional box and the strings stay shared.
    try std.testing.expect(call.extra == ast.positionalExtra(1));
    try std.testing.expect(call.callee.Path.segments[0].name.ptr == segs[0].name.ptr);

    call.args[0].IntLit.value = 9;
    try std.testing.expectEqual(@as(i64, 1), args[0].IntLit.value);
}
