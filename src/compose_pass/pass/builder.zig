//! Arena-allocated AST node builders. Generated nodes carry `gen_span`.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");

const Span = span_mod.Span;
const Ident = ast.Ident;
const Expr = ast.Expr;
const Param = ast.Param;
const TypeRef = ast.TypeRef;

pub const B = struct {
    a: std.mem.Allocator,
    gen_span: Span,

    pub fn ident(self: B, name: []const u8) Ident {
        return .{ .name = name, .span = self.gen_span };
    }

    pub fn box(self: B, e: Expr) *Expr {
        const p = self.a.create(Expr) catch @panic("oom");
        p.* = e;
        return p;
    }

    /// `name` as a single-segment path expression.
    pub fn pathExpr(self: B, name: []const u8) Expr {
        const segs = self.a.alloc(Ident, 1) catch @panic("oom");
        segs[0] = self.ident(name);
        return .{ .Path = .{ .segments = segs, .span = self.gen_span } };
    }

    /// `a.b.c` as a multi-segment path expression.
    pub fn pathExprSegs(self: B, names: []const []const u8) Expr {
        const segs = self.a.alloc(Ident, names.len) catch @panic("oom");
        for (names, segs) |nm, *s| s.* = self.ident(nm);
        return .{ .Path = .{ .segments = segs, .span = self.gen_span } };
    }

    pub fn intLit(self: B, v: i64) Expr {
        return .{ .IntLit = .{ .value = v, .kind = .Int, .span = self.gen_span } };
    }

    /// `receiver.name`.
    pub fn member(self: B, receiver: Expr, name: []const u8) Expr {
        return .{ .Member = .{
            .receiver = self.box(receiver),
            .name = self.ident(name),
            .safe = false,
            .span = self.gen_span,
        } };
    }

    /// `receiver.name(args)` (positional args, no trailing lambda).
    pub fn callMember(self: B, receiver: Expr, name: []const u8, args: []Expr) Expr {
        return self.call(self.member(receiver, name), args);
    }

    /// `callee(args)` with all-positional args.
    pub fn call(self: B, callee: Expr, args: []Expr) Expr {
        const names = self.a.alloc(?[]const u8, args.len) catch @panic("oom");
        for (names) |*n| n.* = null;
        return .{ .Call = .{
            .callee = self.box(callee),
            .args = args,
            .arg_names = names,
            .type_args = &.{},
            .is_infix = false,
            .has_trailing_lambda = false,
            .span = self.gen_span,
        } };
    }

    pub fn slice1(self: B, e: Expr) []Expr {
        const s = self.a.alloc(Expr, 1) catch @panic("oom");
        s[0] = e;
        return s;
    }

    /// A named user type reference (`Composer`, `Int`) with no generics.
    pub fn typeRef(self: B, name: []const u8) TypeRef {
        return .{
            .name = self.ident(name),
            .nullable = false,
            .span = self.gen_span,
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    }

    pub fn param(self: B, name: []const u8, ty: TypeRef) Param {
        return .{
            .name = self.ident(name),
            .ty = ty,
            .default = null,
            .is_vararg = false,
            .is_crossinline = false,
            .is_noinline = false,
            .annotations = &.{},
            .span = self.gen_span,
        };
    }
};
