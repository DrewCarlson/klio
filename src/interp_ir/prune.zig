//! Strip the bodies of non-inline stdlib functions from the lifted AST, which
//! never run from the AST. Two readers keep theirs: `inline` bodies, spliced
//! into user code by the lowerer, and bodies holding an `ObjectExpr` that an
//! `Inst.BuildObject` points into. Dispatch reads `body != null` as a
//! concrete-versus-abstract sentinel, so a stripped body is an empty block.

const std = @import("std");
const ast = @import("ast");

const Decl = ast.Decl;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

/// Replace the bodies of non-inline, object-free functions across `decls` with
/// an empty block, recursing into members. Such a top-level function also drops
/// its signature: resolution binds through the baked symbol index and calls
/// dispatch by `FuncId`, so only class members are read back through
/// `MethodDef.decl`. `keep_composable_sigs` spares the signature of a
/// `@Composable` function, which the plugin's oracle reads from the base.
pub fn stripDeadBodies(decls: []Decl, keep_composable_sigs: bool) void {
    for (decls) |*d| pruneDecl(d, true, keep_composable_sigs);
}

fn pruneDecl(d: *Decl, top_level: bool, keep_composable_sigs: bool) void {
    switch (d.*) {
        .Function => |*f| pruneFunction(f, top_level, keep_composable_sigs),
        .Class => |*c| {
            for (c.members) |*m| pruneDecl(m, false, keep_composable_sigs);
        },
        .Object => |*o| {
            for (o.members) |*m| pruneDecl(m, false, keep_composable_sigs);
        },
        .Property, .TypeAlias => {},
    }
}

/// An annotation path ending in `Composable`; mirrors `compose_pass`.
fn annotationsHaveComposable(annotations: []const ast.Annotation) bool {
    for (annotations) |ann| {
        if (ann.path.len == 0) continue;
        if (std.mem.eql(u8, ann.path[ann.path.len - 1].name, "Composable")) return true;
    }
    return false;
}

/// `@Composable`, or declaring a `@Composable`-typed lambda parameter.
fn composeOracleNeedsSig(f: *const Function) bool {
    if (annotationsHaveComposable(f.annotations)) return true;
    for (f.params) |p| {
        if (p.ty.function != null and annotationsHaveComposable(p.ty.annotations)) return true;
    }
    return false;
}

fn pruneFunction(f: *Function, top_level: bool, keep_composable_sigs: bool) void {
    const keep_sig = keep_composable_sigs and composeOracleNeedsSig(f);
    if (f.body) |*body| {
        // Inline bodies splice at lower time; object-bearing ones run at runtime.
        if (f.is_inline or fnBodyHasObject(body)) return;
        // Read the span first: `body` aliases the storage about to be written.
        const sp = fnBodySpan(body);
        // Keep `body != null` so dispatch still treats the method as concrete.
        f.body = .{ .Block = .{ .stmts = &.{}, .span = sp } };
        if (top_level and !keep_sig) {
            f.receiver_type = null;
            f.type_params = &.{};
            f.where_bounds = &.{};
            f.params = &.{};
            f.return_type = null;
            f.annotations = &.{};
        }
    }
}

fn fnBodySpan(b: *const FunctionBody) ast.Span {
    return switch (b.*) {
        .Block => |*blk| blk.span,
        .Expr => |*e| e.span(),
    };
}

/// Every `inline`, object-free function across `decls`: the bodies the image can
/// defer to a lazily-decoded side section. An object-bearing body stays eager,
/// since an `Inst.BuildObject` points into its `ObjectExpr` subtree.
pub fn collectDeferrable(allocator: std.mem.Allocator, decls: []const Decl, out: *std.ArrayList(*Function)) std.mem.Allocator.Error!void {
    for (decls) |*d| try collectDeferrableDecl(allocator, d, out);
}

fn collectDeferrableDecl(allocator: std.mem.Allocator, d: *const Decl, out: *std.ArrayList(*Function)) std.mem.Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.body) |*body| {
                if (f.is_inline and !fnBodyHasObject(body)) try out.append(allocator, @constCast(f));
            }
        },
        .Class => |*c| for (c.members) |*m| try collectDeferrableDecl(allocator, m, out),
        .Object => |*o| for (o.members) |*m| try collectDeferrableDecl(allocator, m, out),
        .Property, .TypeAlias => {},
    }
}

// ObjectExpr detection, exhaustive over every `Expr` and `Stmt` case.

pub fn fnBodyHasObject(b: *const FunctionBody) bool {
    return switch (b.*) {
        .Block => |*blk| blockHasObject(blk),
        .Expr => |*e| exprHasObject(e),
    };
}

fn blockHasObject(b: *const Block) bool {
    for (b.stmts) |*s| if (stmtHasObject(s)) return true;
    return false;
}

fn stmtHasObject(s: *const Stmt) bool {
    return switch (s.*) {
        .Expr => |*e| exprHasObject(e),
        .Decl => |*d| declHasObject(d),
        .Assign => |*a| exprHasObject(&a.target) or exprHasObject(&a.value),
        .DestructuringDecl => |*dd| exprHasObject(&dd.init),
    };
}

fn declHasObject(d: *const Decl) bool {
    return switch (d.*) {
        .Function => |*f| if (f.body) |*b| fnBodyHasObject(b) else false,
        .Property => |p| {
            if (p.init) |*e| if (exprHasObject(e)) return true;
            if (p.explicit_field) |ef| {
                if (ef.init) |*e| if (exprHasObject(e)) return true;
            }
            if (p.delegate) |e| if (exprHasObject(e)) return true;
            if (p.getter) |acc| if (fnBodyHasObject(&acc.body)) return true;
            if (p.setter) |acc| if (fnBodyHasObject(&acc.body)) return true;
            return false;
        },
        .Class => |*c| {
            for (c.members) |*m| if (declHasObject(m)) return true;
            for (c.init_blocks) |*ib| if (blockHasObject(ib)) return true;
            return false;
        },
        .Object => |*o| {
            for (o.members) |*m| if (declHasObject(m)) return true;
            for (o.init_blocks) |*ib| if (blockHasObject(ib)) return true;
            return false;
        },
        .TypeAlias => false,
    };
}

fn optExprHasObject(e: ?*const Expr) bool {
    return if (e) |x| exprHasObject(x) else false;
}

fn exprHasObject(e: *const Expr) bool {
    return switch (e.*) {
        .ObjectExpr => true,
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path, .This, .Super, .PropertyRef, .Break, .Continue => false,
        .StringTemplate => |*x| {
            for (x.parts) |*p| switch (p.*) {
                .Interp => |ie| if (exprHasObject(ie)) return true,
                .Text, .ShortInterp => {},
            };
            return false;
        },
        .Member => |*x| exprHasObject(x.receiver),
        .Call => |*x| {
            if (exprHasObject(x.callee)) return true;
            for (x.args) |*a| if (exprHasObject(a)) return true;
            return false;
        },
        .Index => |*x| {
            if (exprHasObject(x.receiver)) return true;
            for (x.args) |*a| if (exprHasObject(a)) return true;
            return false;
        },
        .Binary => |*x| exprHasObject(x.lhs) or exprHasObject(x.rhs),
        .Unary => |*x| exprHasObject(x.expr),
        .Postfix => |*x| exprHasObject(x.expr),
        .If => |*x| exprHasObject(x.cond) or exprHasObject(x.then_branch) or optExprHasObject(x.else_branch),
        .While => |*x| exprHasObject(x.cond) or exprHasObject(x.body),
        .DoWhile => |*x| optExprHasObject(x.body) or exprHasObject(x.cond),
        .For => |*x| exprHasObject(x.iter) or exprHasObject(x.body),
        .Return => |*x| optExprHasObject(x.value),
        .Labeled => |*x| exprHasObject(x.expr),
        .Block => |*x| blockHasObject(x),
        .Throw => |*x| exprHasObject(x.value),
        .Try => |*x| {
            if (blockHasObject(&x.body)) return true;
            for (x.catches) |*c| if (blockHasObject(&c.body)) return true;
            if (x.finally) |*fb| if (blockHasObject(fb)) return true;
            return false;
        },
        .Lambda => |*x| blockHasObject(&x.body),
        .MemberRef => |*x| exprHasObject(x.receiver),
        .When => |*x| {
            if (optExprHasObject(x.subject)) return true;
            for (x.branches) |*br| {
                if (exprHasObject(&br.body)) return true;
                for (br.patterns) |*p| switch (p.kind) {
                    .Value => |*ve| if (exprHasObject(ve)) return true,
                    .InRange => |*ie| if (exprHasObject(ie)) return true,
                    .NotInRange => |*ie| if (exprHasObject(ie)) return true,
                    .IsType, .NotIsType, .Else => {},
                };
            }
            return false;
        },
        .IsCheck => |*x| exprHasObject(x.expr),
        .As => |*x| exprHasObject(x.expr),
        .AnonFun => |*x| if (x.body) |b| fnBodyHasObject(b) else false,
        .Spread => |*x| exprHasObject(x.expr),
    };
}

const testing = std.testing;

fn tSpan(s: u32, e: u32) ast.Span {
    return .{ .file = @enumFromInt(0), .start = s, .end = e };
}

fn tIdent(n: []const u8) ast.Ident {
    return .{ .name = n, .span = tSpan(0, 0) };
}

fn tFn(body: ?FunctionBody, is_inline: bool) Function {
    return .{
        .name = tIdent("f"),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = body,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = is_inline,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = tSpan(100, 200),
    };
}

fn tIntStmt() Stmt {
    return .{ .Expr = .{ .IntLit = .{ .value = 7, .kind = .Int, .span = tSpan(10, 11) } } };
}

test "non-inline body is stripped, span preserved" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(42, 99) } }, false);
    pruneFunction(&f, true, false);
    try testing.expect(f.body != null);
    try testing.expect(f.body.? == .Block);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    // The empty block carries the original body's span verbatim.
    try testing.expectEqual(@as(u32, 42), f.body.?.Block.span.start);
    try testing.expectEqual(@as(u32, 99), f.body.?.Block.span.end);
}

test "expression body is stripped, its span preserved" {
    var f = tFn(.{ .Expr = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = tSpan(7, 13) } } }, false);
    pruneFunction(&f, true, false);
    try testing.expect(f.body.? == .Block);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    try testing.expectEqual(@as(u32, 7), f.body.?.Block.span.start);
    try testing.expectEqual(@as(u32, 13), f.body.?.Block.span.end);
}

test "inline body is left intact" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, true);
    pruneFunction(&f, true, false);
    try testing.expectEqual(@as(usize, 1), f.body.?.Block.stmts.len);
}

test "object-bearing body is left intact" {
    const obj: Expr = .{ .ObjectExpr = .{
        .supertypes = &.{},
        .supertype_args = &.{},
        .supertype_delegates = &.{},
        .members = &.{},
        .init_blocks = &.{},
        .init_block_positions = &.{},
        .span = tSpan(5, 6),
    } };
    var stmts = [_]Stmt{.{ .Expr = obj }};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    pruneFunction(&f, true, false);
    try testing.expectEqual(@as(usize, 1), f.body.?.Block.stmts.len);
}

test "abstract body (null) stays null" {
    var f = tFn(null, false);
    pruneFunction(&f, true, false);
    try testing.expect(f.body == null);
}

test "a @Composable function keeps its signature when composable sigs are kept" {
    // The oracle reads composable signatures from the lifted decls.
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    var composable_path = [_]ast.Ident{tIdent("Composable")};
    var anns = [_]ast.Annotation{.{ .use_site = null, .path = &composable_path, .type_args = &.{}, .args = &.{}, .arg_names = &.{}, .span = tSpan(0, 0) }};
    f.annotations = &anns;
    var params = [_]ast.Param{.{
        .name = tIdent("content"),
        .ty = .{ .name = tIdent("Function0"), .nullable = false, .span = tSpan(0, 0), .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = tSpan(0, 0),
    }};
    f.params = &params;
    pruneFunction(&f, true, true);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    try testing.expectEqual(@as(usize, 1), f.annotations.len);
    try testing.expectEqual(@as(usize, 1), f.params.len);
    try testing.expect(annotationsHaveComposable(f.annotations));
}

test "a plain function still drops its signature even when composable sigs are kept" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, false);
    pruneFunction(&f, true, true);
    try testing.expectEqual(@as(usize, 0), f.params.len);
    try testing.expectEqual(@as(usize, 0), f.annotations.len);
}
