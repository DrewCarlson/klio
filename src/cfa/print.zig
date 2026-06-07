//! Textual CFG printer for snapshot tests. Produces a stable, dense
//! representation suitable for golden-file diffs. The format carries
//! the same information as the dataflow box diagram in line-oriented
//! text.

const std = @import("std");
const ir = @import("ir.zig");

const types = @import("types");

const Allocator = std.mem.Allocator;
const Cfg = ir.Cfg;
const Edge = ir.Edge;
const EdgeKind = ir.EdgeKind;
const Node = ir.Node;
const Pattern = ir.Pattern;
const Place = ir.Place;
const Terminator = ir.Terminator;
const Type = ir.Type;
const GenericArg = types.GenericArg;
const Variance = types.Variance;

/// Thin formatting sink over an owned `std.ArrayList(u8)`.
const Out = struct {
    buf: *std.ArrayList(u8),
    allocator: Allocator,

    fn writeAll(self: Out, s: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn print(self: Out, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.buf.appendSlice(self.allocator, s);
    }
};

/// Render `cfg` to an owned string. Caller frees with `allocator`.
pub fn printCfg(allocator: Allocator, cfg: *const Cfg) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = Out{ .buf = &buf, .allocator = allocator };

    try w.print("cfg: entry=b{d}\n", .{cfg.entry.int()});
    if (cfg.exits.items.len != 0) {
        try w.writeAll("exits: ");
        for (cfg.exits.items, 0..) |b, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("b{d}", .{b.int()});
        }
        try w.writeAll("\n");
    }
    for (cfg.blocks.items) |*blk| {
        try w.writeAll("\n");
        try w.print("b{d}:\n", .{blk.id.int()});
        if (blk.preds.items.len != 0) {
            try w.writeAll("  preds: ");
            for (blk.preds.items, 0..) |e, i| {
                if (i != 0) try w.writeAll(", ");
                try formatEdge(w, e);
            }
            try w.writeAll("\n");
        }
        for (blk.nodes.items) |*node| {
            try w.writeAll("  ");
            try formatNode(w, node);
            try w.writeAll("\n");
        }
        try w.writeAll("  term: ");
        try formatTerm(w, &blk.term);
        try w.writeAll("\n");
    }
    return buf.toOwnedSlice(allocator);
}

fn formatEdge(w: Out, e: Edge) Allocator.Error!void {
    try w.print("b{d}", .{e.block.int()});
    switch (e.kind) {
        .Normal => {},
        .True => try w.writeAll("(T)"),
        .False => try w.writeAll("(F)"),
        .Exception => |x| {
            if (x.ty) |t| {
                try w.writeAll("(throw ");
                try formatType(w, t);
                try w.writeAll(")");
            } else {
                try w.writeAll("(throw)");
            }
        },
        .FinallyEntry => try w.writeAll("(finally-entry)"),
        .FinallyExit => try w.writeAll("(finally-exit)"),
    }
}

fn formatNode(w: Out, n: *const Node) Allocator.Error!void {
    switch (n.*) {
        .Eval => |e| {
            try w.print("r{d} = eval @{d}..{d} :: ", .{ e.reg.int(), e.expr.span.start, e.expr.span.end });
            try formatType(w, e.expr.ty);
        },
        .Assign => |a| {
            try w.writeAll("assign ");
            try formatPlace(w, a.lhs);
            try w.print(" = r{d}", .{a.rhs.int()});
        },
        .DeclLocal => |d| {
            try w.print("decl {s} : ", .{d.place.name});
            try formatType(w, d.declared_ty);
        },
        .Assume => |a| {
            try w.print("assume {s}r{d}", .{ if (a.polarity) "" else "!", a.reg.int() });
        },
        .AssumeIs => |a| {
            try w.print("assume r{d} {s} ", .{ a.reg.int(), if (a.polarity) "is" else "!is" });
            try formatType(w, a.ty);
            if (a.class_name) |cn| try w.print(" [{s}]", .{cn});
        },
        .AssumeNull => |a| {
            try w.print("assume r{d} {s} null", .{ a.reg.int(), if (a.eq_null) "==" else "!=" });
        },
        .AssumeRefEq => |a| {
            try w.print("assume r{d} {s} r{d}", .{ a.reg_a.int(), if (a.polarity) "===" else "!==", a.reg_b.int() });
        },
        .Assert => |a| try w.print("assert r{d}", .{a.reg.int()}),
        .KillDataFlow => |k| {
            try w.writeAll("kill ");
            try formatPlace(w, k.place);
        },
        .Backedge => |b| try w.print("backedge l{d}", .{b.loop_id.int()}),
        .LabelMark => |l| try w.print("label l{d}", .{l.label.int()}),
        .Unreachable => try w.writeAll("unreachable"),
    }
}

fn formatPlace(w: Out, p: Place) Allocator.Error!void {
    switch (p) {
        .Local => |s| try w.writeAll(s.name),
        .Field => |f| {
            try formatPlace(w, f.receiver.*);
            try w.print(".{s}", .{f.field.name});
        },
        .This => try w.writeAll("this"),
    }
}

fn formatTerm(w: Out, t: *const Terminator) Allocator.Error!void {
    switch (t.*) {
        .Goto => |b| try w.print("goto b{d}", .{b.int()}),
        .Branch => |b| try w.print("branch r{d} -> b{d} else b{d}", .{ b.cond.int(), b.then_blk.int(), b.else_blk.int() }),
        .Switch => |sw| {
            try w.print("switch r{d} [", .{sw.reg.int()});
            for (sw.arms, 0..) |a, i| {
                if (i != 0) try w.writeAll("; ");
                try formatPattern(w, a.pattern);
                try w.print(" -> b{d}", .{a.target.int()});
            }
            try w.print("] default b{d}", .{sw.default.int()});
        },
        .Throw => |r| try w.print("throw r{d}", .{r.int()}),
        .Return => |maybe| {
            if (maybe) |r| try w.print("return r{d}", .{r.int()}) else try w.writeAll("return");
        },
        .Unreachable => try w.writeAll("unreachable"),
    }
}

fn formatPattern(w: Out, p: Pattern) Allocator.Error!void {
    switch (p) {
        .Equal => |r| try w.print("== r{d}", .{r.int()}),
        .Is => |is| {
            try w.print("{s} ", .{if (is.polarity) "is" else "!is"});
            try formatType(w, is.ty);
        },
        .Wildcard => try w.writeAll("_"),
    }
}

/// Render a type the way Rust's derived `{:?}` does. `print_cfg`
/// formats every type through `Debug`, not `Display`, so the output
/// must match the derived shape exactly: tuple variants render as
/// `Name(inner)`, struct variants as `Name { field: value, ... }`,
/// vectors as `[a, b]`, and strings quoted.
fn formatType(w: Out, t: Type) Allocator.Error!void {
    switch (t) {
        .Unit, .Boolean, .Byte, .Short, .Int, .Long, .UByte, .UShort, .UInt, .ULong, .Float, .Double, .Char, .String, .Any, .Nothing, .Unresolved => try w.writeAll(@tagName(t)),
        .Nullable => |inner| {
            try w.writeAll("Nullable(");
            try formatType(w, inner.*);
            try w.writeAll(")");
        },
        .Range => |inner| {
            try w.writeAll("Range(");
            try formatType(w, inner.*);
            try w.writeAll(")");
        },
        .TypeParam => |name| {
            try w.writeAll("TypeParam(");
            try formatStrDebug(w, name);
            try w.writeAll(")");
        },
        .Function => |f| {
            try w.writeAll("Function { params: ");
            try formatTypeSlice(w, f.params);
            try w.writeAll(", return_type: ");
            try formatType(w, f.return_type.*);
            try w.print(", is_suspend: {s} }}", .{if (f.is_suspend) "true" else "false"});
        },
        .Generic => |g| {
            try w.writeAll("Generic { name: ");
            try formatStrDebug(w, g.name);
            try w.writeAll(", args: ");
            try formatArgSlice(w, g.args);
            try w.writeAll(" }");
        },
        .Intersection => |parts| {
            try w.writeAll("Intersection(");
            try formatTypeSlice(w, parts);
            try w.writeAll(")");
        },
    }
}

fn formatTypeSlice(w: Out, items: []const Type) Allocator.Error!void {
    try w.writeAll("[");
    for (items, 0..) |it, i| {
        if (i != 0) try w.writeAll(", ");
        try formatType(w, it);
    }
    try w.writeAll("]");
}

fn formatArgSlice(w: Out, items: []const GenericArg) Allocator.Error!void {
    try w.writeAll("[");
    for (items, 0..) |it, i| {
        if (i != 0) try w.writeAll(", ");
        try formatGenericArg(w, it);
    }
    try w.writeAll("]");
}

fn formatGenericArg(w: Out, a: GenericArg) Allocator.Error!void {
    try w.print("GenericArg {{ variance: {s}, is_star: {s}, ty: ", .{
        @tagName(a.variance),
        if (a.is_star) "true" else "false",
    });
    try formatType(w, a.ty);
    try w.writeAll(" }");
}

/// Render a string the way Rust's `Debug for str` does: wrapped in
/// double quotes with the standard escapes. The names that reach this
/// path are type-parameter and class identifiers, but the escaping is
/// faithful for any content.
fn formatStrDebug(w: Out, s: []const u8) Allocator.Error!void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.print("{c}", .{c}),
        }
    }
    try w.writeAll("\"");
}

/// Render a single type through the CFG printer's Debug formatter,
/// used by the type-rendering tests below. Caller frees the result.
fn typeToDebug(allocator: Allocator, t: Type) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = Out{ .buf = &buf, .allocator = allocator };
    try formatType(w, t);
    return buf.toOwnedSlice(allocator);
}

test "print empty-body cfg header" {
    const a = std.testing.allocator;
    const span = @import("span");
    var cfg = Cfg{
        .entry = ir.BlockId.from(0),
        .source = span.Span.init(span.FileId.from(0), 0, 0),
        .next_reg = 0,
    };
    defer cfg.blocks.deinit(a);
    defer cfg.exits.deinit(a);
    try cfg.blocks.append(a, .{ .id = ir.BlockId.from(0), .term = .{ .Return = null } });
    defer cfg.blocks.items[0].nodes.deinit(a);
    defer cfg.blocks.items[0].preds.deinit(a);
    defer cfg.blocks.items[0].succs.deinit(a);
    const s = try printCfg(a, &cfg);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "cfg: entry=b0") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "term: return") != null);
}

test "scalar types render as their tag name" {
    const a = std.testing.allocator;
    const i = try typeToDebug(a, .Int);
    defer a.free(i);
    try std.testing.expectEqualStrings("Int", i);
    const u = try typeToDebug(a, .Unresolved);
    defer a.free(u);
    try std.testing.expectEqualStrings("Unresolved", u);
}

test "compound types render like derived Debug" {
    const a = std.testing.allocator;

    var inner: Type = .Int;
    const nullable = Type{ .Nullable = &inner };
    const n = try typeToDebug(a, nullable);
    defer a.free(n);
    try std.testing.expectEqualStrings("Nullable(Int)", n);

    const tp = Type{ .TypeParam = "T" };
    const t = try typeToDebug(a, tp);
    defer a.free(t);
    try std.testing.expectEqualStrings("TypeParam(\"T\")", t);

    var args = [_]GenericArg{.{ .variance = .Out, .is_star = false, .ty = .String }};
    const generic = Type{ .Generic = .{ .name = "List", .args = &args } };
    const g = try typeToDebug(a, generic);
    defer a.free(g);
    try std.testing.expectEqualStrings(
        "Generic { name: \"List\", args: [GenericArg { variance: Out, is_star: false, ty: String }] }",
        g,
    );

    var ret: Type = .Boolean;
    var params = [_]Type{.Int};
    const func = Type{ .Function = .{ .params = &params, .return_type = &ret, .is_suspend = false } };
    const f = try typeToDebug(a, func);
    defer a.free(f);
    try std.testing.expectEqualStrings(
        "Function { params: [Int], return_type: Boolean, is_suspend: false }",
        f,
    );
}
