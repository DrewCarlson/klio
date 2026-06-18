//! Strip the bodies of non-inline stdlib functions from the lifted AST.
//!
//! The baked stdlib image keeps the full post-lift AST forest (`lifted_decls`)
//! alongside the lowered IR — ~67MB resident — even though a non-inline
//! function's body never runs from the AST (its lowered IR does). Three things
//! still read a base function's AST body: the lowerer splices `inline fun`
//! bodies into user code (kept via `is_inline`), the runtime builds anonymous
//! `object { … }` expressions from `Inst.BuildObject.ast` whose subtree lives in
//! the body (kept when the body contains an `ObjectExpr`), and dispatch reads
//! `body != null` as a concrete-vs-abstract sentinel (preserved by leaving an
//! empty body, not `null`). Every other body is dead weight; replacing it with
//! an empty block keeps the metadata (params, return type, the `body != null`
//! sentinel) while dropping the statement tree.
//!
//! The `ObjectExpr` check is a compiler-exhaustive AST walk: Zig forces every
//! `Expr`/`Stmt` union case to be handled, so a future node kind cannot silently
//! slip an anonymous object past the keep test.

const std = @import("std");
const ast = @import("ast");

const Decl = ast.Decl;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

/// Replace the bodies of non-inline, object-free functions across `decls`
/// (recursing into class / object members) with an empty block. A non-inline,
/// object-free *top-level* function additionally drops its signature (params,
/// type params, receiver, return type, annotations): its AST declaration is
/// never read again — resolution binds through the baked symbol index and the
/// lowered IR func, calls dispatch by `FuncId`, and only class members are read
/// back through `MethodDef.decl`. Inline functions (spliced) and class members
/// keep their full signatures.
pub fn stripDeadBodies(decls: []Decl) void {
    for (decls) |*d| pruneDecl(d, true);
}

fn pruneDecl(d: *Decl, top_level: bool) void {
    switch (d.*) {
        .Function => |*f| pruneFunction(f, top_level),
        .Class => |*c| {
            for (c.members) |*m| pruneDecl(m, false);
        },
        .Object => |*o| {
            for (o.members) |*m| pruneDecl(m, false);
        },
        .Property, .TypeAlias => {},
    }
}

fn pruneFunction(f: *Function, top_level: bool) void {
    if (f.body) |*body| {
        // Keep inline bodies (spliced into user code at lower time) and any body
        // that materialises an anonymous object at runtime.
        if (f.is_inline or fnBodyHasObject(body)) return;
        // Read the body's span into a local *before* overwriting `f.body`.
        // `body` aliases `f.body`'s storage, and writing the new block in place
        // would clobber the body fields mid-construction were the span read
        // inline in the literal.
        const sp = fnBodySpan(body);
        // Drop the statements; keep `body != null` so dispatch still treats the
        // method as concrete.
        f.body = .{ .Block = .{ .stmts = &.{}, .span = sp } };
        if (top_level) {
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

// --- Deferrable-body collection ----------------------------------------------

/// Collect every `inline`, object-free function across `decls` (recursing into
/// class / object members) into `out`. These are the bodies the baked image can
/// hold in a lazily-decoded side section: a non-inline body is already stripped
/// (it never runs from the AST), and an object-bearing body must stay eager (its
/// `ObjectExpr` subtree is referenced by an `Inst.BuildObject`).
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

// --- ObjectExpr detection (compiler-exhaustive) ------------------------------

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
        .Property => |*p| {
            if (p.init) |*e| if (exprHasObject(e)) return true;
            if (p.delegate) |*e| if (exprHasObject(e)) return true;
            if (p.getter) |*acc| if (fnBodyHasObject(&acc.body)) return true;
            if (p.setter) |*acc| if (fnBodyHasObject(&acc.body)) return true;
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
                .Interp => |*ie| if (exprHasObject(ie)) return true,
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

// --- tests ------------------------------------------------------------------

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
    pruneFunction(&f, true);
    // Body kept (concrete sentinel) but statements dropped.
    try testing.expect(f.body != null);
    try testing.expect(f.body.? == .Block);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    // The empty block must carry the original body's span verbatim -- the
    // in-place result-location aliasing bug used to clobber `end` here.
    try testing.expectEqual(@as(u32, 42), f.body.?.Block.span.start);
    try testing.expectEqual(@as(u32, 99), f.body.?.Block.span.end);
}

test "expression body is stripped, its span preserved" {
    var f = tFn(.{ .Expr = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = tSpan(7, 13) } } }, false);
    pruneFunction(&f, true);
    try testing.expect(f.body.? == .Block);
    try testing.expectEqual(@as(usize, 0), f.body.?.Block.stmts.len);
    try testing.expectEqual(@as(u32, 7), f.body.?.Block.span.start);
    try testing.expectEqual(@as(u32, 13), f.body.?.Block.span.end);
}

test "inline body is left intact" {
    var stmts = [_]Stmt{tIntStmt()};
    var f = tFn(.{ .Block = .{ .stmts = &stmts, .span = tSpan(1, 2) } }, true);
    pruneFunction(&f, true);
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
    pruneFunction(&f, true);
    // Must keep the statements: the runtime materialises the object from them.
    try testing.expectEqual(@as(usize, 1), f.body.?.Block.stmts.len);
}

test "abstract body (null) stays null" {
    var f = tFn(null, false);
    pruneFunction(&f, true);
    try testing.expect(f.body == null);
}
