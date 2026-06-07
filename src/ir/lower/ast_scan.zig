//! Pure AST-walking helpers used by lowering. Kept separate from the
//! main lowering module because they only consume the AST — they touch
//! no `FuncBuilder` state and have no IR-side dependencies.

const std = @import("std");
const ast = @import("ast");

const Allocator = std.mem.Allocator;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const StringSet = std.StringHashMap(void);

/// `expr as Any` (or transitively wrapped) — used by the
/// boxed-equality routing.
pub fn isBoxedToAnyForm(e: *const Expr) bool {
    return switch (e.*) {
        .As => |a| std.mem.eql(u8, a.ty.name.name, "Any"),
        // A var binding annotated `: Any` — the IR lowering can't see
        // types here, so be conservative.
        .Path => false,
        else => false,
    };
}

/// Recursively collect every single-segment `Path` identifier that
/// appears anywhere in an expression. Used to find which names a nested
/// lambda references.
pub fn collectPathIdents(e: *const Expr, out: *StringSet) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) try out.put(p.segments[0].name, {});
        },
        .Member => |m| try collectPathIdents(m.receiver, out),
        .MemberRef => |m| try collectPathIdents(m.receiver, out),
        .Call => |c| {
            try collectPathIdents(c.callee, out);
            for (c.args) |*a| try collectPathIdents(a, out);
        },
        .Index => |idx| {
            try collectPathIdents(idx.receiver, out);
            for (idx.args) |*a| try collectPathIdents(a, out);
        },
        .Binary => |bin| {
            try collectPathIdents(bin.lhs, out);
            try collectPathIdents(bin.rhs, out);
        },
        .Unary => |u| try collectPathIdents(u.expr, out),
        .Postfix => |u| try collectPathIdents(u.expr, out),
        .Spread => |u| try collectPathIdents(u.expr, out),
        .Throw => |u| try collectPathIdents(u.value, out),
        .Labeled => |u| try collectPathIdents(u.expr, out),
        .As => |u| try collectPathIdents(u.expr, out),
        .IsCheck => |u| try collectPathIdents(u.expr, out),
        .If => |f| {
            try collectPathIdents(f.cond, out);
            try collectPathIdents(f.then_branch, out);
            if (f.else_branch) |els| try collectPathIdents(els, out);
        },
        .While => |w| {
            try collectPathIdents(w.cond, out);
            try collectPathIdents(w.body, out);
        },
        .DoWhile => |w| {
            if (w.body) |b| try collectPathIdents(b, out);
            try collectPathIdents(w.cond, out);
        },
        .For => |f| {
            try collectPathIdents(f.iter, out);
            try collectPathIdents(f.body, out);
        },
        .Return => |r| {
            if (r.value) |v| try collectPathIdents(v, out);
        },
        .Block => |b| {
            for (b.stmts) |*s| try collectPathIdentsStmt(s, out);
        },
        .Lambda => |l| {
            for (l.body.stmts) |*s| try collectPathIdentsStmt(s, out);
        },
        .AnonFun => |af| {
            if (af.body) |fb| switch (fb.*) {
                .Block => |b| {
                    for (b.stmts) |*s| try collectPathIdentsStmt(s, out);
                },
                .Expr => |*ex| try collectPathIdents(ex, out),
            };
        },
        .When => |w| {
            if (w.subject) |s| try collectPathIdents(s, out);
            for (w.branches) |*br| try collectPathIdents(&br.body, out);
        },
        .Try => |t| {
            for (t.body.stmts) |*s| try collectPathIdentsStmt(s, out);
            for (t.catches) |*c| {
                for (c.body.stmts) |*s| try collectPathIdentsStmt(s, out);
            }
            if (t.finally) |fb| {
                for (fb.stmts) |*s| try collectPathIdentsStmt(s, out);
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |*p| switch (p.*) {
                .Interp => |*ex| try collectPathIdents(ex, out),
                .ShortInterp => |id| try out.put(id.name, {}),
                .Text => {},
            };
        },
        else => {},
    }
}

pub fn collectPathIdentsStmt(s: *const Stmt, out: *StringSet) Allocator.Error!void {
    switch (s.*) {
        .Expr => |*e| try collectPathIdents(e, out),
        .Assign => |a| {
            try collectPathIdents(&a.target, out);
            try collectPathIdents(&a.value, out);
        },
        .DestructuringDecl => |d| try collectPathIdents(&d.init, out),
        .Decl => |d| switch (d) {
            .Property => |p| {
                if (p.init) |*e| try collectPathIdents(e, out);
            },
            else => {},
        },
    }
}

/// Names referenced anywhere inside a nested `Lambda` / `AnonFun` within
/// these statements (recursing into nested lambdas too).
pub fn namesReferencedInLambdas(stmts: []const Stmt, out: *StringSet) Allocator.Error!void {
    for (stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try scanLambdaRefsExpr(e, out),
            .Assign => |a| {
                try scanLambdaRefsExpr(&a.target, out);
                try scanLambdaRefsExpr(&a.value, out);
            },
            .DestructuringDecl => |d| try scanLambdaRefsExpr(&d.init, out),
            .Decl => |d| switch (d) {
                .Property => |p| {
                    if (p.init) |*e| try scanLambdaRefsExpr(e, out);
                },
                .Function => |f| {
                    if (f.body) |fb| switch (fb) {
                        .Block => |blk| {
                            for (blk.stmts) |*ss| try collectPathIdentsStmt(ss, out);
                        },
                        .Expr => |*ex| try collectPathIdents(ex, out),
                    };
                },
                else => {},
            },
        }
    }
}

fn scanLambdaRefsExpr(e: *const Expr, out: *StringSet) Allocator.Error!void {
    switch (e.*) {
        .Lambda => |l| {
            for (l.body.stmts) |*s| try collectPathIdentsStmt(s, out);
        },
        .AnonFun => |af| {
            if (af.body) |fb| switch (fb.*) {
                .Block => |b| {
                    for (b.stmts) |*s| try collectPathIdentsStmt(s, out);
                },
                .Expr => |*ex| try collectPathIdents(ex, out),
            };
        },
        .Member => |m| try scanLambdaRefsExpr(m.receiver, out),
        .Unary => |u| try scanLambdaRefsExpr(u.expr, out),
        .Postfix => |u| try scanLambdaRefsExpr(u.expr, out),
        .Spread => |u| try scanLambdaRefsExpr(u.expr, out),
        .Throw => |u| try scanLambdaRefsExpr(u.value, out),
        .Labeled => |u| try scanLambdaRefsExpr(u.expr, out),
        .As => |u| try scanLambdaRefsExpr(u.expr, out),
        .IsCheck => |u| try scanLambdaRefsExpr(u.expr, out),
        .MemberRef => |m| try scanLambdaRefsExpr(m.receiver, out),
        .Call => |c| {
            try scanLambdaRefsExpr(c.callee, out);
            for (c.args) |*a| try scanLambdaRefsExpr(a, out);
        },
        .Index => |idx| {
            try scanLambdaRefsExpr(idx.receiver, out);
            for (idx.args) |*a| try scanLambdaRefsExpr(a, out);
        },
        .Binary => |bin| {
            try scanLambdaRefsExpr(bin.lhs, out);
            try scanLambdaRefsExpr(bin.rhs, out);
        },
        .If => |f| {
            try scanLambdaRefsExpr(f.cond, out);
            try scanLambdaRefsExpr(f.then_branch, out);
            if (f.else_branch) |els| try scanLambdaRefsExpr(els, out);
        },
        .While => |w| {
            try scanLambdaRefsExpr(w.cond, out);
            try scanLambdaRefsExpr(w.body, out);
        },
        .DoWhile => |w| {
            if (w.body) |b| try scanLambdaRefsExpr(b, out);
            try scanLambdaRefsExpr(w.cond, out);
        },
        .For => |f| {
            try scanLambdaRefsExpr(f.iter, out);
            try scanLambdaRefsExpr(f.body, out);
        },
        .Return => |r| {
            if (r.value) |v| try scanLambdaRefsExpr(v, out);
        },
        .Block => |b| try namesReferencedInLambdas(b.stmts, out),
        .When => |w| {
            if (w.subject) |s| try scanLambdaRefsExpr(s, out);
            for (w.branches) |*br| try scanLambdaRefsExpr(&br.body, out);
        },
        .Try => |t| {
            try namesReferencedInLambdas(t.body.stmts, out);
            for (t.catches) |*c| try namesReferencedInLambdas(c.body.stmts, out);
            if (t.finally) |fb| try namesReferencedInLambdas(fb.stmts, out);
        },
        .StringTemplate => |st| {
            for (st.parts) |*p| switch (p.*) {
                .Interp => |*ex| try scanLambdaRefsExpr(ex, out),
                .ShortInterp => |id| try out.put(id.name, {}),
                .Text => {},
            };
        },
        else => {},
    }
}

/// `var` names declared directly in these statements (not inside a
/// nested lambda — those open their own frame). Also includes a
/// deferred-init plain `val` (no initializer / delegate / accessor),
/// because a later write from a nested lambda needs the same
/// `Ref`-boxing as a captured `var` to be visible at the decl site.
pub fn collectVarDecls(stmts: []const Stmt, out: *StringSet) Allocator.Error!void {
    for (stmts) |*s| {
        switch (s.*) {
            .Decl => |d| switch (d) {
                .Property => |p| {
                    const deferred_val = p.init == null and p.delegate == null and
                        p.getter == null and p.setter == null;
                    if (p.mutable or deferred_val) try out.put(p.name.name, {});
                },
                else => {},
            },
            .DestructuringDecl => |dd| {
                if (dd.mutable) {
                    for (dd.names) |n| try out.put(n.name, {});
                }
            },
            .Expr => |*e| try collectVarDeclsExpr(e, out),
            else => {},
        }
    }
}

fn collectVarDeclsExpr(e: *const Expr, out: *StringSet) Allocator.Error!void {
    switch (e.*) {
        .Block => |b| try collectVarDecls(b.stmts, out),
        .If => |f| {
            try collectVarDeclsExpr(f.then_branch, out);
            if (f.else_branch) |els| try collectVarDeclsExpr(els, out);
        },
        .While => |w| try collectVarDeclsExpr(w.body, out),
        .For => |f| try collectVarDeclsExpr(f.body, out),
        .DoWhile => |w| {
            if (w.body) |b| try collectVarDeclsExpr(b, out);
        },
        .When => |w| {
            for (w.branches) |*br| try collectVarDeclsExpr(&br.body, out);
        },
        .Labeled => |l| try collectVarDeclsExpr(l.expr, out),
        .Try => |t| {
            try collectVarDecls(t.body.stmts, out);
            for (t.catches) |*c| try collectVarDecls(c.body.stmts, out);
            if (t.finally) |fb| try collectVarDecls(fb.stmts, out);
        },
        else => {},
    }
}

/// `var`s declared in this frame and captured by a nested lambda need to
/// be boxed into a shared `Value.Cell` (Kotlin `Ref` semantics) so a
/// write from a coroutine / closure is visible at the decl site. The
/// caller owns the returned set.
pub fn computeBoxedVars(allocator: Allocator, stmts: []const Stmt) Allocator.Error!StringSet {
    var decls = StringSet.init(allocator);
    errdefer decls.deinit();
    try collectVarDecls(stmts, &decls);
    if (decls.count() == 0) return decls;
    var refs = StringSet.init(allocator);
    defer refs.deinit();
    try namesReferencedInLambdas(stmts, &refs);
    // Retain only names referenced inside a nested lambda.
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(allocator);
    var it = decls.keyIterator();
    while (it.next()) |k| {
        if (!refs.contains(k.*)) try to_remove.append(allocator, k.*);
    }
    for (to_remove.items) |k| _ = decls.remove(k);
    return decls;
}

/// Flatten a `Member{receiver: Member{...,Path}}` chain into a dotted
/// FQN like `kotlin.math.PI`. Returns `null` when the chain is not
/// purely identifier segments (e.g. it has a Call, Index, or arbitrary
/// expression). The caller owns the returned string.
pub fn collectDottedFqn(allocator: Allocator, expr: *const Expr) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var cur = expr;
    while (true) {
        switch (cur.*) {
            .Member => |m| {
                try parts.append(allocator, m.name.name);
                cur = m.receiver;
            },
            .Path => |p| {
                var i = p.segments.len;
                while (i > 0) {
                    i -= 1;
                    try parts.append(allocator, p.segments[i].name);
                }
                break;
            },
            else => return null,
        }
    }
    std.mem.reverse([]const u8, parts.items);
    return try std.mem.join(allocator, ".", parts.items);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const span = @import("span");

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

test "is boxed to any form matches as Any" {
    var inner = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    const e = Expr{ .As = .{
        .expr = &inner,
        .ty = .{
            .name = .{ .name = "Any", .span = dummySpan() },
            .nullable = false,
            .span = dummySpan(),
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        },
        .safe = false,
        .span = dummySpan(),
    } };
    try testing.expect(isBoxedToAnyForm(&e));
}

test "collect path idents from binary" {
    var aseg = [_]ast.Ident{.{ .name = "a", .span = dummySpan() }};
    var bseg = [_]ast.Ident{.{ .name = "b", .span = dummySpan() }};
    var lhs = Expr{ .Path = .{ .segments = &aseg, .span = dummySpan() } };
    var rhs = Expr{ .Path = .{ .segments = &bseg, .span = dummySpan() } };
    const e = Expr{ .Binary = .{ .op = .Add, .lhs = &lhs, .rhs = &rhs, .span = dummySpan() } };
    var out = StringSet.init(testing.allocator);
    defer out.deinit();
    try collectPathIdents(&e, &out);
    try testing.expect(out.contains("a"));
    try testing.expect(out.contains("b"));
    try testing.expectEqual(@as(usize, 2), out.count());
}

test "collect dotted fqn flattens member chain" {
    var seg = [_]ast.Ident{.{ .name = "kotlin", .span = dummySpan() }};
    var path = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    var mid = Expr{ .Member = .{ .receiver = &path, .name = .{ .name = "math", .span = dummySpan() }, .safe = false, .span = dummySpan() } };
    const top = Expr{ .Member = .{ .receiver = &mid, .name = .{ .name = "PI", .span = dummySpan() }, .safe = false, .span = dummySpan() } };
    const fqn = (try collectDottedFqn(testing.allocator, &top)).?;
    defer testing.allocator.free(fqn);
    try testing.expectEqualStrings("kotlin.math.PI", fqn);
}

test "collect dotted fqn rejects non-identifier chain" {
    var seg = [_]ast.Ident{.{ .name = "f", .span = dummySpan() }};
    var callee = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    const call = Expr{ .Call = .{
        .callee = &callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = dummySpan(),
    } };
    try testing.expect((try collectDottedFqn(testing.allocator, &call)) == null);
}

test "compute boxed vars keeps only captured var decls" {
    // var captured = 0; var untouched = 0; { x -> captured }
    const lit0 = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } };
    const lit1 = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = dummySpan() } };
    const prop_captured = ast.Property{
        .mutable = true,
        .name = .{ .name = "captured", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = lit0,
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    var prop_untouched = prop_captured;
    prop_untouched.name = .{ .name = "untouched", .span = dummySpan() };
    prop_untouched.init = lit1;

    // Lambda body references `captured`.
    var refseg = [_]ast.Ident{.{ .name = "captured", .span = dummySpan() }};
    var refexpr = Expr{ .Path = .{ .segments = &refseg, .span = dummySpan() } };
    var lambda_stmts = [_]Stmt{.{ .Expr = refexpr }};
    var lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &lambda_stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };

    var stmts = [_]Stmt{
        .{ .Decl = .{ .Property = prop_captured } },
        .{ .Decl = .{ .Property = prop_untouched } },
        .{ .Expr = lambda },
    };
    _ = &refexpr;
    _ = &lambda;
    var boxed = try computeBoxedVars(testing.allocator, &stmts);
    defer boxed.deinit();
    try testing.expect(boxed.contains("captured"));
    try testing.expect(!boxed.contains("untouched"));
}
