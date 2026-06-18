//! End-to-end type-checker tests.
//!
//! The typeck module's dependency graph excludes the lexer and parser, so
//! these tests build the `KotlinFile` AST directly with small helpers rather
//! than parsing source text. Each helper mirrors a syntactic form; the
//! assertions match the upstream Rust `#[test]` cases one for one, with the
//! corresponding source program reproduced in a comment.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const resolver = @import("resolver");

const check = @import("../check.zig");
const typecheck = check.typecheck;
const codes = check.codes;

const Span = span.Span;
const FileId = span.FileId;
const Ident = ast.Ident;
const TypeRef = ast.TypeRef;
const TypeArg = ast.TypeArg;
const TypeParam = ast.TypeParam;
const Param = ast.Param;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Block = ast.Block;
const Decl = ast.Decl;
const Function = ast.Function;
const Property = ast.Property;
const Accessor = ast.Accessor;
const FunctionBody = ast.FunctionBody;
const FunctionTypeRef = ast.FunctionTypeRef;
const StringPart = ast.StringPart;
const WhenBranch = ast.WhenBranch;
const WhenPattern = ast.WhenPattern;
const WhenBinding = ast.WhenBinding;
const Annotation = ast.Annotation;
const Catch = ast.Catch;
const KotlinFile = ast.KotlinFile;

const testing = std.testing;
const test_file = FileId.from(0);

// ---------------------------------------------------------------------------
// AST builder: a `Builder` owns an arena, hands out heap pointers, and tracks
// a monotonic span offset so every node gets a distinct span (the checker keys
// its side tables by span, so collisions would alias unrelated expressions).
// ---------------------------------------------------------------------------

const Builder = struct {
    arena: std.heap.ArenaAllocator,
    off: u32 = 1,

    fn init(gpa: std.mem.Allocator) Builder {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *Builder) void {
        self.arena.deinit();
    }

    fn a(self: *Builder) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn ts(self: *Builder) Span {
        const start = self.off;
        self.off += 1;
        return Span.init(test_file, start, start + 1);
    }

    /// Current span offset; pair with `spanFrom` to build an enclosing
    /// span over everything constructed in between (the parser gives a
    /// declaration a span covering its whole body; lexical-region checks
    /// like `@Suppress` rely on that containment).
    fn snap(self: *const Builder) u32 {
        return self.off;
    }

    fn spanFrom(self: *Builder, start: u32) Span {
        const end = self.off;
        self.off += 1;
        return Span.init(test_file, start, end + 1);
    }

    fn ident(self: *Builder, name: []const u8) Ident {
        return .{ .name = name, .span = self.ts() };
    }

    fn dup(self: *Builder, comptime T: type, value: T) *T {
        const p = self.a().create(T) catch unreachable;
        p.* = value;
        return p;
    }

    fn slice(self: *Builder, comptime T: type, items: []const T) []T {
        const out = self.a().alloc(T, items.len) catch unreachable;
        @memcpy(out, items);
        return out;
    }

    // --- types ---

    fn ty(self: *Builder, name: []const u8) TypeRef {
        return self.tyN(name, false);
    }

    fn tyNull(self: *Builder, name: []const u8) TypeRef {
        return self.tyN(name, true);
    }

    fn tyN(self: *Builder, name: []const u8, nullable: bool) TypeRef {
        return .{
            .name = self.ident(name),
            .nullable = nullable,
            .span = self.ts(),
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    }

    fn tyArgs(self: *Builder, name: []const u8, args: []const TypeRef) TypeRef {
        const ta = self.a().alloc(TypeArg, args.len) catch unreachable;
        for (args, 0..) |t, i| ta[i] = .{ .variance = .Invariant, .is_star = false, .ty = t, .span = self.ts() };
        return .{
            .name = self.ident(name),
            .nullable = false,
            .span = self.ts(),
            .type_args = ta,
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    }

    /// `(params) -> ret`
    fn tyFun(self: *Builder, params: []const TypeRef, ret: TypeRef) TypeRef {
        const ftr = self.dup(FunctionTypeRef, .{
            .receiver = null,
            .params = self.slice(TypeRef, params),
            .ret = ret,
            .is_suspend = false,
            .span = self.ts(),
        });
        return .{
            .name = self.ident("<function>"),
            .nullable = false,
            .span = self.ts(),
            .type_args = &.{},
            .function = ftr,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    }

    // --- expressions ---

    fn intLit(self: *Builder, value: i64) Expr {
        return .{ .IntLit = .{ .value = value, .kind = .Int, .span = self.ts() } };
    }

    fn boolLit(self: *Builder, value: bool) Expr {
        return .{ .BoolLit = .{ .value = value, .span = self.ts() } };
    }

    fn nullLit(self: *Builder) Expr {
        return .{ .NullLit = .{ .span = self.ts() } };
    }

    fn str(self: *Builder, text: []const u8) Expr {
        const parts = self.slice(StringPart, &.{.{ .Text = text }});
        return .{ .StringTemplate = .{ .parts = parts, .span = self.ts() } };
    }

    fn path(self: *Builder, name: []const u8) Expr {
        const segs = self.slice(Ident, &.{self.ident(name)});
        return .{ .Path = .{ .segments = segs, .span = self.ts() } };
    }

    fn member(self: *Builder, receiver: Expr, name: []const u8) Expr {
        return .{ .Member = .{
            .receiver = self.dup(Expr, receiver),
            .name = self.ident(name),
            .safe = false,
            .span = self.ts(),
        } };
    }

    fn safeMember(self: *Builder, receiver: Expr, name: []const u8) Expr {
        return .{ .Member = .{
            .receiver = self.dup(Expr, receiver),
            .name = self.ident(name),
            .safe = true,
            .span = self.ts(),
        } };
    }

    fn call(self: *Builder, callee: Expr, args: []const Expr) Expr {
        return self.callN(callee, args, &.{}, &.{});
    }

    fn callN(
        self: *Builder,
        callee: Expr,
        args: []const Expr,
        arg_names: []const ?[]const u8,
        type_args: []const TypeRef,
    ) Expr {
        const names: []?[]const u8 = if (arg_names.len == 0)
            blk: {
                const out = self.a().alloc(?[]const u8, args.len) catch unreachable;
                for (out) |*n| n.* = null;
                break :blk out;
            }
        else
            self.slice(?[]const u8, arg_names);
        return .{ .Call = .{
            .callee = self.dup(Expr, callee),
            .args = self.slice(Expr, args),
            .arg_names = names,
            .type_args = self.slice(TypeRef, type_args),
            .is_infix = false,
            .span = self.ts(),
        } };
    }

    fn binary(self: *Builder, op: ast.BinOp, lhs: Expr, rhs: Expr) Expr {
        return .{ .Binary = .{
            .op = op,
            .lhs = self.dup(Expr, lhs),
            .rhs = self.dup(Expr, rhs),
            .span = self.ts(),
        } };
    }

    fn postfix(self: *Builder, op: ast.PostfixOp, e: Expr) Expr {
        return .{ .Postfix = .{ .op = op, .expr = self.dup(Expr, e), .span = self.ts() } };
    }

    fn isCheck(self: *Builder, e: Expr, t: TypeRef, negated: bool) Expr {
        return .{ .IsCheck = .{
            .expr = self.dup(Expr, e),
            .ty = t,
            .negated = negated,
            .span = self.ts(),
        } };
    }

    fn asCast(self: *Builder, e: Expr, t: TypeRef, safe: bool) Expr {
        return .{ .As = .{
            .expr = self.dup(Expr, e),
            .ty = t,
            .safe = safe,
            .span = self.ts(),
        } };
    }

    fn ifExpr(self: *Builder, cond: Expr, then_b: Expr, else_b: ?Expr) Expr {
        return .{ .If = .{
            .cond = self.dup(Expr, cond),
            .then_branch = self.dup(Expr, then_b),
            .else_branch = if (else_b) |e| self.dup(Expr, e) else null,
            .span = self.ts(),
        } };
    }

    fn whileExpr(self: *Builder, cond: Expr, body: Expr) Expr {
        return .{ .While = .{
            .cond = self.dup(Expr, cond),
            .body = self.dup(Expr, body),
            .span = self.ts(),
        } };
    }

    fn doWhile(self: *Builder, body: ?Expr, cond: Expr) Expr {
        return .{ .DoWhile = .{
            .body = if (body) |b| self.dup(Expr, b) else null,
            .cond = self.dup(Expr, cond),
            .span = self.ts(),
        } };
    }

    fn returnExpr(self: *Builder, value: ?Expr) Expr {
        return .{ .Return = .{
            .value = if (value) |v| self.dup(Expr, v) else null,
            .label = null,
            .span = self.ts(),
        } };
    }

    fn breakExpr(self: *Builder) Expr {
        return .{ .Break = .{ .label = null, .span = self.ts() } };
    }

    fn throwExpr(self: *Builder, value: Expr) Expr {
        return .{ .Throw = .{ .value = self.dup(Expr, value), .span = self.ts() } };
    }

    fn block(self: *Builder, stmts: []const Stmt) Expr {
        return .{ .Block = .{ .stmts = self.slice(Stmt, stmts), .span = self.ts() } };
    }

    fn lambda(self: *Builder, params: []const []const u8, stmts: []const Stmt) Expr {
        const ps = self.a().alloc(Ident, params.len) catch unreachable;
        for (params, 0..) |p, i| ps[i] = self.ident(p);
        return .{ .Lambda = .{
            .params = ps,
            .body = .{ .stmts = self.slice(Stmt, stmts), .span = self.ts() },
            .span = self.ts(),
        } };
    }

    /// `fun(params): ret { body }` anonymous function expression.
    fn anonFun(self: *Builder, params: []const Param, ret: ?TypeRef, body: Expr) Expr {
        const fb = self.dup(FunctionBody, .{ .Block = .{
            .stmts = self.slice(Stmt, &.{.{ .Expr = body }}),
            .span = self.ts(),
        } });
        return .{ .AnonFun = .{
            .receiver_ty = null,
            .params = self.slice(Param, params),
            .return_ty = ret,
            .body = fb,
            .is_suspend = false,
            .span = self.ts(),
        } };
    }

    fn whenExpr(self: *Builder, subject: ?Expr, binding: ?WhenBinding, branches: []const WhenBranch) Expr {
        return .{ .When = .{
            .subject = if (subject) |s| self.dup(Expr, s) else null,
            .subject_binding = binding,
            .branches = self.slice(WhenBranch, branches),
            .span = self.ts(),
        } };
    }

    fn whenIs(self: *Builder, t: TypeRef, body: Expr) WhenBranch {
        const pats = self.slice(WhenPattern, &.{.{ .kind = .{ .IsType = t }, .span = self.ts() }});
        return .{ .patterns = pats, .body = body, .span = self.ts() };
    }

    fn whenElse(self: *Builder, body: Expr) WhenBranch {
        const pats = self.slice(WhenPattern, &.{.{ .kind = .Else, .span = self.ts() }});
        return .{ .patterns = pats, .body = body, .span = self.ts() };
    }

    // --- statements ---

    fn exprStmt(self: *Builder, e: Expr) Stmt {
        _ = self;
        return .{ .Expr = e };
    }

    fn assign(self: *Builder, target: Expr, value: Expr) Stmt {
        return .{ .Assign = .{
            .target = target,
            .op = .Assign,
            .value = value,
            .span = self.ts(),
        } };
    }

    /// `val name [: ty] = init`
    fn valDecl(self: *Builder, name: []const u8, t: ?TypeRef, init_e: ?Expr) Stmt {
        return self.localProp(false, name, t, init_e);
    }

    /// `var name [: ty] = init`
    fn varDecl(self: *Builder, name: []const u8, t: ?TypeRef, init_e: ?Expr) Stmt {
        return self.localProp(true, name, t, init_e);
    }

    fn localProp(self: *Builder, mutable: bool, name: []const u8, t: ?TypeRef, init_e: ?Expr) Stmt {
        return .{ .Decl = .{ .Property = self.dup(Property, self.prop(mutable, name, t, init_e)) } };
    }

    fn prop(self: *Builder, mutable: bool, name: []const u8, t: ?TypeRef, init_e: ?Expr) Property {
        return .{
            .mutable = mutable,
            .name = self.ident(name),
            .receiver_type = null,
            .ty = t,
            .init = init_e,
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
            .span = self.ts(),
        };
    }

    // --- declarations ---

    fn param(self: *Builder, name: []const u8, t: TypeRef) Param {
        return .{
            .name = self.ident(name),
            .ty = t,
            .default = null,
            .is_vararg = false,
            .is_crossinline = false,
            .is_noinline = false,
            .annotations = &.{},
            .span = self.ts(),
        };
    }

    fn varargParam(self: *Builder, name: []const u8, t: TypeRef) Param {
        var p = self.param(name, t);
        p.is_vararg = true;
        return p;
    }

    /// `val name: T` primary-constructor property parameter.
    fn valParam(self: *Builder, name: []const u8, t: TypeRef) ast.ClassParam {
        return self.ctorParam(false, name, t);
    }

    /// A plain (non-property) primary-constructor parameter.
    fn plainCtorParam(self: *Builder, name: []const u8, t: TypeRef) ast.ClassParam {
        return .{
            .property = null,
            .name = self.ident(name),
            .ty = t,
            .default = null,
            .visibility = .Public,
            .is_vararg = false,
            .annotations = &.{},
            .span = self.ts(),
        };
    }

    fn ctorParam(self: *Builder, mutable: bool, name: []const u8, t: TypeRef) ast.ClassParam {
        return .{
            .property = mutable,
            .name = self.ident(name),
            .ty = t,
            .default = null,
            .visibility = .Public,
            .is_vararg = false,
            .annotations = &.{},
            .span = self.ts(),
        };
    }

    fn func(self: *Builder, name: []const u8, params: []const Param, ret: ?TypeRef, body: ?FunctionBody) Function {
        return .{
            .name = self.ident(name),
            .receiver_type = null,
            .type_params = &.{},
            .where_bounds = &.{},
            .params = self.slice(Param, params),
            .return_type = ret,
            .body = body,
            .is_open = false,
            .is_override = false,
            .is_abstract = false,
            .is_operator = false,
            .is_inline = false,
            .is_infix = false,
            .is_tailrec = false,
            .is_suspend = false,
            .is_expect = false,
            .is_actual = false,
            .visibility = .Public,
            .annotations = &.{},
            .span = self.ts(),
        };
    }

    /// A function whose body is an expression: `fun f(...) = expr`.
    fn funExpr(self: *Builder, name: []const u8, params: []const Param, ret: ?TypeRef, e: Expr) Function {
        return self.func(name, params, ret, .{ .Expr = e });
    }

    /// A function whose body is a block of statements.
    fn funBlock(self: *Builder, name: []const u8, params: []const Param, ret: ?TypeRef, stmts: []const Stmt) Function {
        return self.func(name, params, ret, .{ .Block = .{
            .stmts = self.slice(Stmt, stmts),
            .span = self.ts(),
        } });
    }

    fn typeParam(self: *Builder, name: []const u8) TypeParam {
        return .{
            .name = self.ident(name),
            .variance = .Invariant,
            .upper_bound = null,
            .is_reified = false,
            .annotations = &.{},
            .span = self.ts(),
        };
    }

    fn class(self: *Builder, name: []const u8) ast.Class {
        return .{
            .name = self.ident(name),
            .type_params = &.{},
            .where_bounds = &.{},
            .primary_params = &.{},
            .init_blocks = &.{},
            .init_block_positions = &.{},
            .supertypes = &.{},
            .supertype_args = &.{},
            .supertype_delegates = &.{},
            .is_data = false,
            .is_companion = false,
            .is_enum = false,
            .is_sealed = false,
            .is_open = false,
            .is_abstract = false,
            .is_inner = false,
            .secondary_ctors = &.{},
            .is_interface = false,
            .is_fun_interface = false,
            .is_value = false,
            .is_annotation = false,
            .is_expect = false,
            .is_actual = false,
            .enum_entries = &.{},
            .members = &.{},
            .visibility = .Public,
            .primary_ctor_visibility = null,
            .annotations = &.{},
            .span = self.ts(),
        };
    }

    fn annotation(self: *Builder, name: []const u8, args: []const Expr) Annotation {
        return .{
            .use_site = null,
            .path = self.slice(Ident, &.{self.ident(name)}),
            .type_args = &.{},
            .args = self.slice(Expr, args),
            .arg_names = blk: {
                const out = self.a().alloc(?[]const u8, args.len) catch unreachable;
                for (out) |*n| n.* = null;
                break :blk out;
            },
            .span = self.ts(),
        };
    }

    fn file(self: *Builder, decls: []const Decl) KotlinFile {
        return .{
            .package = null,
            .imports = &.{},
            .decls = self.slice(Decl, decls),
            .span = self.ts(),
        };
    }
};

// ---------------------------------------------------------------------------
// Result harness: holds the resolution + typecheck output plus an owning
// allocator so they can be torn down together.
// ---------------------------------------------------------------------------

const Checked = struct {
    arena: *std.heap.ArenaAllocator,
    res: resolver.Resolution,
    tc: check.TypeCheck,

    fn deinit(self: *Checked) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    fn hasErrors(self: *const Checked) bool {
        return self.tc.diagnostics.hasErrors();
    }

    fn hasCode(self: *const Checked, code: []const u8) bool {
        for (self.tc.diagnostics.diags()) |d| {
            if (d.legacy_code) |c| {
                if (std.mem.eql(u8, c, code)) return true;
            }
        }
        return false;
    }

    fn countCode(self: *const Checked, code: []const u8) usize {
        var n: usize = 0;
        for (self.tc.diagnostics.diags()) |d| {
            if (d.legacy_code) |c| {
                if (std.mem.eql(u8, c, code)) n += 1;
            }
        }
        return n;
    }

    fn hasAnyCode(self: *const Checked) bool {
        for (self.tc.diagnostics.diags()) |d| {
            if (d.legacy_code != null) return true;
        }
        return false;
    }
};

/// Mirror of the Rust `check_src`: resolve, then typecheck, the given file.
/// Everything the resolver and checker allocate lands on a private arena so
/// the whole run is torn down with a single `deinit`.
fn checkFile(gpa: std.mem.Allocator, f: *const KotlinFile) Checked {
    const arena = gpa.create(std.heap.ArenaAllocator) catch unreachable;
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var res = resolver.resolve(a, f) catch unreachable;
    const tc = typecheck(a, f, &res) catch unreachable;
    return .{ .arena = arena, .res = res, .tc = tc };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "literal_types" {
    // fun main() { val x: Int = 1; val y: String = "hi" }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Int"), b.intLit(1)),
        b.valDecl("y", b.ty("String"), b.str("hi")),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasAnyCode());
}

test "literal_int_fits_long" {
    // fun main() { val x: Long = 1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Long"), b.intLit(1)),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasAnyCode());
}

test "type_mismatch_literal" {
    // fun main() { val x: Int = "hi" }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Int"), b.str("hi")),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_MISMATCH));
}

test "val_reassign_flagged" {
    // fun main() { val x = 1; x = 2 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", null, b.intLit(1)),
        b.assign(b.path("x"), b.intLit(2)),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_VAL_REASSIGN));
}

test "var_reassign_ok" {
    // fun main() { var x = 1; x = 2 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.varDecl("x", null, b.intLit(1)),
        b.assign(b.path("x"), b.intLit(2)),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_VAL_REASSIGN));
}

test "null_deref_flagged" {
    // fun main() { val s: String? = null; println(s.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", b.tyNull("String"), b.nullLit()),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("s"), "length")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_NULL_SAFETY));
}

test "safe_call_on_nullable_ok" {
    // fun main() { val s: String? = null; println(s?.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", b.tyNull("String"), b.nullLit()),
        b.exprStmt(b.call(b.path("println"), &.{b.safeMember(b.path("s"), "length")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_NULL_SAFETY));
}

test "smart_cast_after_unsafe_as" {
    // fun main() { val a: Any = "hi"; val s = a as String; println(a.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Any"), b.str("hi")),
        b.valDecl("s", null, b.asCast(b.path("a"), b.ty("String"), false)),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("a"), "length")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_safe_as_does_not_narrow_subject" {
    // fun main() { val a: Any = "hi"; val s = a as? String; val x: Any = a }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Any"), b.str("hi")),
        b.valDecl("s", null, b.asCast(b.path("a"), b.ty("String"), true)),
        b.valDecl("x", b.ty("Any"), b.path("a")),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_while_true_with_return" {
    // fun f(a: String?): Int { while (true) { if (a == null) return -1; break }; return a.length }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const loop_body = b.block(&.{
        b.exprStmt(b.ifExpr(
            b.binary(.Eq, b.path("a"), b.nullLit()),
            b.returnExpr(b.intLit(-1)),
            null,
        )),
        b.exprStmt(b.breakExpr()),
    });
    const f0 = b.funBlock("f", &.{b.param("a", b.tyNull("String"))}, b.ty("Int"), &.{
        b.exprStmt(b.whileExpr(b.boolLit(true), loop_body)),
        b.exprStmt(b.returnExpr(b.member(b.path("a"), "length"))),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_do_while" {
    // fun f(a: String?): Int { do { if (a == null) return -1 } while (false); return a.length }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const do_body = b.block(&.{
        b.exprStmt(b.ifExpr(
            b.binary(.Eq, b.path("a"), b.nullLit()),
            b.returnExpr(b.intLit(-1)),
            null,
        )),
    });
    const f0 = b.funBlock("f", &.{b.param("a", b.tyNull("String"))}, b.ty("Int"), &.{
        b.exprStmt(b.doWhile(do_body, b.boolLit(false))),
        b.exprStmt(b.returnExpr(b.member(b.path("a"), "length"))),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "builder_call_typechecks" {
    // fun main() { val xs = buildList<Int> {} }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("xs", null, b.callN(b.path("buildList"), &.{b.lambda(&.{}, &.{})}, &.{}, &.{b.ty("Int")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());

    // fun main() { val m = buildMap<String, Int> {} }
    var b2 = Builder.init(testing.allocator);
    defer b2.deinit();
    const main2 = b2.funBlock("main", &.{}, null, &.{
        b2.valDecl("m", null, b2.callN(b2.path("buildMap"), &.{b2.lambda(&.{}, &.{})}, &.{}, &.{ b2.ty("String"), b2.ty("Int") })),
    });
    const f2 = b2.file(&.{.{ .Function = main2 }});
    var c2 = checkFile(testing.allocator, &f2);
    defer c2.deinit();
    try testing.expect(!c2.hasErrors());
}

test "bare_type_argument_inference_is_check" {
    // fun f(x: Any) { if (x is List) {}; if (x is Map) {} }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("x", b.ty("Any"))}, null, &.{
        b.exprStmt(b.ifExpr(b.isCheck(b.path("x"), b.ty("List"), false), b.block(&.{}), null)),
        b.exprStmt(b.ifExpr(b.isCheck(b.path("x"), b.ty("Map"), false), b.block(&.{}), null)),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "bare_type_argument_inference_user_generic" {
    // class Box<T>(val v: T); fun f(x: Any) { if (x is Box) {}; val y = x as Box }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    box.type_params = b.slice(TypeParam, &.{b.typeParam("T")});
    box.primary_params = b.slice(ast.ClassParam, &.{b.valParam("v", b.ty("T"))});
    const f0 = b.funBlock("f", &.{b.param("x", b.ty("Any"))}, null, &.{
        b.exprStmt(b.ifExpr(b.isCheck(b.path("x"), b.ty("Box"), false), b.block(&.{}), null)),
        b.valDecl("y", null, b.asCast(b.path("x"), b.ty("Box"), false)),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = f0 } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "lambda_zero_arity_against_unit_callable" {
    // fun foreach(action: () -> Unit) {}; fun main() { foreach { 1 + 2 } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const foreach = b.funBlock("foreach", &.{b.param("action", b.tyFun(&.{}, b.ty("Unit")))}, null, &.{});
    const lam = b.lambda(&.{}, &.{b.exprStmt(b.binary(.Add, b.intLit(1), b.intLit(2)))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("foreach"), &.{lam})),
    });
    const f = b.file(&.{ .{ .Function = foreach }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "lambda_one_arity_with_it_against_one_arity_callable" {
    // fun action(a: (Int) -> Int): Int { return a(1) }; fun main() { action { it + 1 } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const action = b.funBlock("action", &.{b.param("a", b.tyFun(&.{b.ty("Int")}, b.ty("Int")))}, b.ty("Int"), &.{
        b.exprStmt(b.returnExpr(b.call(b.path("a"), &.{b.intLit(1)}))),
    });
    const lam = b.lambda(&.{}, &.{b.exprStmt(b.binary(.Add, b.path("it"), b.intLit(1)))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("action"), &.{lam})),
    });
    const f = b.file(&.{ .{ .Function = action }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_bound_alias_narrows_source" {
    // fun f(a: Any): Int { val b = a; if (b is String) { return a.length }; return -1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("a", b.ty("Any"))}, b.ty("Int"), &.{
        b.valDecl("b", null, b.path("a")),
        b.exprStmt(b.ifExpr(
            b.isCheck(b.path("b"), b.ty("String"), false),
            b.block(&.{b.exprStmt(b.returnExpr(b.member(b.path("a"), "length")))}),
            null,
        )),
        b.exprStmt(b.returnExpr(b.intLit(-1))),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_bound_alias_narrows_copy" {
    // fun f(a: Any): Int { val b = a; if (a is String) { return b.length }; return -1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("a", b.ty("Any"))}, b.ty("Int"), &.{
        b.valDecl("b", null, b.path("a")),
        b.exprStmt(b.ifExpr(
            b.isCheck(b.path("a"), b.ty("String"), false),
            b.block(&.{b.exprStmt(b.returnExpr(b.member(b.path("b"), "length")))}),
            null,
        )),
        b.exprStmt(b.returnExpr(b.intLit(-1))),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_bound_alias_chain" {
    // fun f(a: Any): Int { val b = a; val c = b; if (a is String) { return c.length }; return -1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("a", b.ty("Any"))}, b.ty("Int"), &.{
        b.valDecl("b", null, b.path("a")),
        b.valDecl("c", null, b.path("b")),
        b.exprStmt(b.ifExpr(
            b.isCheck(b.path("a"), b.ty("String"), false),
            b.block(&.{b.exprStmt(b.returnExpr(b.member(b.path("c"), "length")))}),
            null,
        )),
        b.exprStmt(b.returnExpr(b.intLit(-1))),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_not_is_return" {
    // fun f(x: Any): Int { if (x !is String) return -1; return x.length }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("x", b.ty("Any"))}, b.ty("Int"), &.{
        b.exprStmt(b.ifExpr(b.isCheck(b.path("x"), b.ty("String"), true), b.returnExpr(b.intLit(-1)), null)),
        b.exprStmt(b.returnExpr(b.member(b.path("x"), "length"))),
    });
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_not_is_else_branch" {
    // fun f(x: Any): Int = if (x !is String) -1 else x.length
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const body = b.ifExpr(
        b.isCheck(b.path("x"), b.ty("String"), true),
        b.intLit(-1),
        b.member(b.path("x"), "length"),
    );
    const f0 = b.funExpr("f", &.{b.param("x", b.ty("Any"))}, b.ty("Int"), body);
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_when_subject_is_branch" {
    // fun f(x: Any): Int = when (x) { is String -> x.length; else -> 0 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const w = b.whenExpr(b.path("x"), null, &.{
        b.whenIs(b.ty("String"), b.member(b.path("x"), "length")),
        b.whenElse(b.intLit(0)),
    });
    const f0 = b.funExpr("f", &.{b.param("x", b.ty("Any"))}, b.ty("Int"), w);
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_when_with_subject_binding" {
    // fun f(): Int = when (val v: Any = "hi") { is String -> v.length; else -> 0 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const binding: WhenBinding = .{
        .name = b.ident("v"),
        .ty = b.ty("Any"),
        .annotations = &.{},
        .span = b.ts(),
    };
    const w = b.whenExpr(b.str("hi"), binding, &.{
        b.whenIs(b.ty("String"), b.member(b.path("v"), "length")),
        b.whenElse(b.intLit(0)),
    });
    const f0 = b.funExpr("f", &.{}, b.ty("Int"), w);
    const f = b.file(&.{.{ .Function = f0 }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_cross_variable_ref_eq" {
    // fun main() { val a: Any? = "hi"; val b: String = "bye"; if (a === b) { val x: String = a; } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.tyNull("Any"), b.str("hi")),
        b.valDecl("b", b.ty("String"), b.str("bye")),
        b.exprStmt(b.ifExpr(
            b.binary(.IdentEq, b.path("a"), b.path("b")),
            b.block(&.{b.valDecl("x", b.ty("String"), b.path("a"))}),
            null,
        )),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_cross_variable_ref_neq_in_else" {
    // fun main() { val a: Any? = "x"; val b: String = "y"; if (a !== b) {} else { val s: String = a } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.tyNull("Any"), b.str("x")),
        b.valDecl("b", b.ty("String"), b.str("y")),
        b.exprStmt(b.ifExpr(
            b.binary(.IdentNeq, b.path("a"), b.path("b")),
            b.block(&.{}),
            b.block(&.{b.valDecl("s", b.ty("String"), b.path("a"))}),
        )),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_elvis_return" {
    // fun greet(name: String?) { val n = name ?: return; println(name.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const greet = b.funBlock("greet", &.{b.param("name", b.tyNull("String"))}, null, &.{
        b.valDecl("n", null, b.binary(.Elvis, b.path("name"), b.returnExpr(null))),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("name"), "length")})),
    });
    const f = b.file(&.{.{ .Function = greet }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_elvis_throw" {
    // fun greet(name: String?) { name ?: throw RuntimeException("x"); println(name.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const greet = b.funBlock("greet", &.{b.param("name", b.tyNull("String"))}, null, &.{
        b.exprStmt(b.binary(.Elvis, b.path("name"), b.throwExpr(b.call(b.path("RuntimeException"), &.{b.str("x")})))),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("name"), "length")})),
    });
    const f = b.file(&.{.{ .Function = greet }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_if_null_return" {
    // fun greet(name: String?) { if (name == null) return; println(name.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const greet = b.funBlock("greet", &.{b.param("name", b.tyNull("String"))}, null, &.{
        b.exprStmt(b.ifExpr(b.binary(.Eq, b.path("name"), b.nullLit()), b.returnExpr(null), null)),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("name"), "length")})),
    });
    const f = b.file(&.{.{ .Function = greet }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_if_nonnull_else_return" {
    // fun greet(name: String?) { if (name != null) {} else return; println(name.length) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const greet = b.funBlock("greet", &.{b.param("name", b.tyNull("String"))}, null, &.{
        b.exprStmt(b.ifExpr(b.binary(.Neq, b.path("name"), b.nullLit()), b.block(&.{}), b.returnExpr(null))),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("name"), "length")})),
    });
    const f = b.file(&.{.{ .Function = greet }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_after_null_check" {
    // fun main() { val s: String? = null; if (s != null) { println(s.length) } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", b.tyNull("String"), b.nullLit()),
        b.exprStmt(b.ifExpr(
            b.binary(.Neq, b.path("s"), b.nullLit()),
            b.block(&.{b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("s"), "length")}))}),
            null,
        )),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_NULL_SAFETY));
}

test "arity_mismatch_flagged" {
    // fun f(a: Int) = a
    // fun main() { f(1, 2) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funExpr("f", &.{b.param("a", b.ty("Int"))}, null, b.path("a"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("f"), &.{ b.intLit(1), b.intLit(2) })),
    });
    const f = b.file(&.{ .{ .Function = f0 }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_ARGUMENT_COUNT));
}

test "wrong_arg_type_flagged" {
    // fun f(s: String) {}
    // fun main() { f(1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("s", b.ty("String"))}, null, &.{});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("f"), &.{b.intLit(1)})),
    });
    const f = b.file(&.{ .{ .Function = f0 }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_MISMATCH));
}

test "if_lub_string_int_is_any" {
    // fun main() { val x: Any = if (true) "hi" else 1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Any"), b.ifExpr(b.boolLit(true), b.str("hi"), b.intLit(1))),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasAnyCode());
}

test "is_check_narrows_in_branch" {
    // fun main() { val a: Any = "hi"; if (a is String) { println(a.length) } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Any"), b.str("hi")),
        b.exprStmt(b.ifExpr(
            b.isCheck(b.path("a"), b.ty("String"), false),
            b.block(&.{b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("a"), "length")}))}),
            null,
        )),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_NULL_SAFETY));
}

test "binary_string_concat" {
    // fun main() { val x: String = "a" + 1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("String"), b.binary(.Add, b.str("a"), b.intLit(1))),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasAnyCode());
}

test "user_class_call_type_checks" {
    // class Box(val x: Int)
    // fun main() { val b = Box(3); println(b.x) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    box.primary_params = b.slice(ast.ClassParam, &.{b.valParam("x", b.ty("Int"))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("b", null, b.call(b.path("Box"), &.{b.intLit(3)})),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("b"), "x")})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "user_class_wrong_ctor_arg_type" {
    // class Box(val x: Int)
    // fun main() { val b = Box("hi") }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    box.primary_params = b.slice(ast.ClassParam, &.{b.valParam("x", b.ty("Int"))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("b", null, b.call(b.path("Box"), &.{b.str("hi")})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_MISMATCH));
}

test "lambda_param_types_from_expected" {
    // fun main() { val f: (Int) -> Int = { x -> x + 1 }; println(f(2)) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const lam = b.lambda(&.{"x"}, &.{b.exprStmt(b.binary(.Add, b.path("x"), b.intLit(1)))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("f", b.tyFun(&.{b.ty("Int")}, b.ty("Int")), lam),
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("f"), &.{b.intLit(2)})})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "abstract_member_not_implemented" {
    // abstract class Shape { abstract fun area(): Int }
    // class Square : Shape()
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var shape = b.class("Shape");
    shape.is_abstract = true;
    var area = b.func("area", &.{}, b.ty("Int"), null);
    area.is_abstract = true;
    shape.members = b.slice(Decl, &.{.{ .Function = area }});
    var square = b.class("Square");
    square.supertypes = b.slice(TypeRef, &.{b.ty("Shape")});
    square.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{})});
    const f = b.file(&.{ .{ .Class = shape }, .{ .Class = square } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED));
}

test "delegate_with_operator_modifier_ok" {
    // class D { operator fun getValue(...): Int = 1; operator fun setValue(...) {} }
    // var x: Int by D()
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var d = b.class("D");
    var get_value = b.funExpr("getValue", &.{ b.param("thisRef", b.tyNull("Any")), b.param("prop", b.tyNull("Any")) }, b.ty("Int"), b.intLit(1));
    get_value.is_operator = true;
    var set_value = b.funBlock("setValue", &.{ b.param("thisRef", b.tyNull("Any")), b.param("prop", b.tyNull("Any")), b.param("value", b.ty("Int")) }, null, &.{});
    set_value.is_operator = true;
    d.members = b.slice(Decl, &.{ .{ .Function = get_value }, .{ .Function = set_value } });
    var x = b.prop(true, "x", b.ty("Int"), null);
    x.delegate = b.dup(Expr, b.call(b.path("D"), &.{}));
    const f = b.file(&.{ .{ .Class = d }, .{ .Property = b.dup(Property, x) } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_DELEGATE_OPERATOR_REQUIRED));
}

test "delegate_missing_operator_on_get_value_flagged" {
    // class D { fun getValue(...): Int = 1 }
    // val x: Int by D()
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var d = b.class("D");
    const get_value = b.funExpr("getValue", &.{ b.param("thisRef", b.tyNull("Any")), b.param("prop", b.tyNull("Any")) }, b.ty("Int"), b.intLit(1));
    d.members = b.slice(Decl, &.{.{ .Function = get_value }});
    var x = b.prop(false, "x", b.ty("Int"), null);
    x.delegate = b.dup(Expr, b.call(b.path("D"), &.{}));
    const f = b.file(&.{ .{ .Class = d }, .{ .Property = b.dup(Property, x) } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_DELEGATE_OPERATOR_REQUIRED));
}

test "delegate_missing_operator_on_set_value_flagged" {
    // class D { operator fun getValue(...): Int = 1; fun setValue(...) {} }
    // var x: Int by D()
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var d = b.class("D");
    var get_value = b.funExpr("getValue", &.{ b.param("thisRef", b.tyNull("Any")), b.param("prop", b.tyNull("Any")) }, b.ty("Int"), b.intLit(1));
    get_value.is_operator = true;
    const set_value = b.funBlock("setValue", &.{ b.param("thisRef", b.tyNull("Any")), b.param("prop", b.tyNull("Any")), b.param("value", b.ty("Int")) }, null, &.{});
    d.members = b.slice(Decl, &.{ .{ .Function = get_value }, .{ .Function = set_value } });
    var x = b.prop(true, "x", b.ty("Int"), null);
    x.delegate = b.dup(Expr, b.call(b.path("D"), &.{}));
    const f = b.file(&.{ .{ .Class = d }, .{ .Property = b.dup(Property, x) } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_DELEGATE_OPERATOR_REQUIRED));
}

test "diamond_conflict_flagged" {
    // interface A { fun hi(): String = "A" }
    // interface B { fun hi(): String = "B" }
    // class C : A, B
    // fun main() { println(C().hi()) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var ia = b.class("A");
    ia.is_interface = true;
    ia.members = b.slice(Decl, &.{.{ .Function = b.funExpr("hi", &.{}, b.ty("String"), b.str("A")) }});
    var ib = b.class("B");
    ib.is_interface = true;
    ib.members = b.slice(Decl, &.{.{ .Function = b.funExpr("hi", &.{}, b.ty("String"), b.str("B")) }});
    var cc = b.class("C");
    cc.supertypes = b.slice(TypeRef, &.{ b.ty("A"), b.ty("B") });
    cc.supertype_args = b.slice(?[]Expr, &.{ null, null });
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.member(b.call(b.path("C"), &.{}), "hi"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = ia }, .{ .Class = ib }, .{ .Class = cc }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_DIAMOND_CONFLICT));
}

test "diamond_conflict_resolved_by_override" {
    // interface A { fun hi(): String = "A" }
    // interface B { fun hi(): String = "B" }
    // class C : A, B { override fun hi(): String = "C" }
    // fun main() { println(C().hi()) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var ia = b.class("A");
    ia.is_interface = true;
    ia.members = b.slice(Decl, &.{.{ .Function = b.funExpr("hi", &.{}, b.ty("String"), b.str("A")) }});
    var ib = b.class("B");
    ib.is_interface = true;
    ib.members = b.slice(Decl, &.{.{ .Function = b.funExpr("hi", &.{}, b.ty("String"), b.str("B")) }});
    var cc = b.class("C");
    cc.supertypes = b.slice(TypeRef, &.{ b.ty("A"), b.ty("B") });
    cc.supertype_args = b.slice(?[]Expr, &.{ null, null });
    var hi_c = b.funExpr("hi", &.{}, b.ty("String"), b.str("C"));
    hi_c.is_override = true;
    cc.members = b.slice(Decl, &.{.{ .Function = hi_c }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.member(b.call(b.path("C"), &.{}), "hi"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = ia }, .{ .Class = ib }, .{ .Class = cc }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_DIAMOND_CONFLICT));
}

test "diamond_no_false_positive_for_linear_chain" {
    // open class Shape { open fun area(): Int = 0 }
    // open class Rectangle : Shape() { override fun area(): Int = 1 }
    // class Square : Rectangle()
    // fun main() { println(Square().area()) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var shape = b.class("Shape");
    shape.is_open = true;
    var area0 = b.funExpr("area", &.{}, b.ty("Int"), b.intLit(0));
    area0.is_open = true;
    shape.members = b.slice(Decl, &.{.{ .Function = area0 }});
    var rect = b.class("Rectangle");
    rect.is_open = true;
    rect.supertypes = b.slice(TypeRef, &.{b.ty("Shape")});
    rect.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{})});
    var area1 = b.funExpr("area", &.{}, b.ty("Int"), b.intLit(1));
    area1.is_override = true;
    rect.members = b.slice(Decl, &.{.{ .Function = area1 }});
    var square = b.class("Square");
    square.supertypes = b.slice(TypeRef, &.{b.ty("Rectangle")});
    square.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{})});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.member(b.call(b.path("Square"), &.{}), "area"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = shape }, .{ .Class = rect }, .{ .Class = square }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_DIAMOND_CONFLICT));
}

test "lateinit_var_string_ok" {
    // class Box { lateinit var s: String }
    // fun main() { println(Box()) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var s = b.prop(true, "s", b.ty("String"), null);
    s.is_lateinit = true;
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, s) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("Box"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_LATEINIT_VAL));
    try testing.expect(!c.hasCode(codes.TYPE_LATEINIT_PRIMITIVE));
    try testing.expect(!c.hasCode(codes.TYPE_LATEINIT_WITH_INITIALIZER));
    try testing.expect(!c.hasCode(codes.TYPE_LATEINIT_NULLABLE));
}

test "lateinit_val_flagged" {
    // class Box { lateinit val s: String }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var s = b.prop(false, "s", b.ty("String"), null);
    s.is_lateinit = true;
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, s) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("Box"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_LATEINIT_VAL));
}

test "lateinit_primitive_flagged" {
    // class Box { lateinit var n: Int }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var n = b.prop(true, "n", b.ty("Int"), null);
    n.is_lateinit = true;
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, n) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("Box"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_LATEINIT_PRIMITIVE));
}

test "lateinit_initializer_flagged" {
    // class Box { lateinit var s: String = "x" }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var s = b.prop(true, "s", b.ty("String"), b.str("x"));
    s.is_lateinit = true;
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, s) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("Box"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_LATEINIT_WITH_INITIALIZER));
}

test "lateinit_nullable_flagged" {
    // class Box { lateinit var s: String? }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var s = b.prop(true, "s", b.tyNull("String"), null);
    s.is_lateinit = true;
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, s) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("Box"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_LATEINIT_NULLABLE));
}

test "accessor_return_type_match_ok" {
    // class Box { val x: Int get(): Int = 1 }
    // fun main() { println(Box().x) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var x = b.prop(false, "x", b.ty("Int"), null);
    x.getter = b.dup(Accessor, .{
        .params = &.{},
        .return_type = b.ty("Int"),
        .body = .{ .Expr = b.intLit(1) },
        .visibility = null,
        .is_inline = false,
        .annotations = &.{},
        .span = b.ts(),
    });
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, x) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.call(b.path("Box"), &.{}), "x")})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_ACCESSOR_RETURN_TYPE_MISMATCH));
}

test "accessor_return_type_mismatch_flagged" {
    // class Box { val x: Int get(): String = "hi" }
    // fun main() { println(Box().x) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    var x = b.prop(false, "x", b.ty("Int"), null);
    x.getter = b.dup(Accessor, .{
        .params = &.{},
        .return_type = b.ty("String"),
        .body = .{ .Expr = b.str("hi") },
        .visibility = null,
        .is_inline = false,
        .annotations = &.{},
        .span = b.ts(),
    });
    box.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, x) }});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.call(b.path("Box"), &.{}), "x")})),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_ACCESSOR_RETURN_TYPE_MISMATCH));
}

test "member_access_resolves_through_class_table" {
    // class Box(val n: Int)
    // fun main() { val b = Box(3); val y: Int = b.n }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var box = b.class("Box");
    box.primary_params = b.slice(ast.ClassParam, &.{b.valParam("n", b.ty("Int"))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("b", null, b.call(b.path("Box"), &.{b.intLit(3)})),
        b.valDecl("y", b.ty("Int"), b.member(b.path("b"), "n")),
    });
    const f = b.file(&.{ .{ .Class = box }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "member_access_chains_propagate_class" {
    // class Inner(val value: Int)
    // class Outer(val inner: Inner)
    // fun main() { val o = Outer(Inner(7)); val n: Int = o.inner.value }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var inner = b.class("Inner");
    inner.primary_params = b.slice(ast.ClassParam, &.{b.valParam("value", b.ty("Int"))});
    var outer = b.class("Outer");
    outer.primary_params = b.slice(ast.ClassParam, &.{b.valParam("inner", b.ty("Inner"))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("o", null, b.call(b.path("Outer"), &.{b.call(b.path("Inner"), &.{b.intLit(7)})})),
        b.valDecl("n", b.ty("Int"), b.member(b.member(b.path("o"), "inner"), "value")),
    });
    const f = b.file(&.{ .{ .Class = inner }, .{ .Class = outer }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "extension_function_resolves_through_receiver_chain" {
    // open class Animal(val name: String)
    // class Dog(n: String) : Animal(n)
    // fun Animal.greet(): String = "hi " + this.name
    // fun main() { val d = Dog("Rex"); val g: String = d.greet(); println(g) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var animal = b.class("Animal");
    animal.is_open = true;
    animal.primary_params = b.slice(ast.ClassParam, &.{b.valParam("name", b.ty("String"))});
    var dog = b.class("Dog");
    dog.primary_params = b.slice(ast.ClassParam, &.{b.plainCtorParam("n", b.ty("String"))});
    dog.supertypes = b.slice(TypeRef, &.{b.ty("Animal")});
    dog.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{b.path("n")})});
    var greet = b.funExpr("greet", &.{}, b.ty("String"), b.binary(.Add, b.str("hi "), b.member(.{ .This = .{ .qualifier = null, .span = b.ts() } }, "name")));
    greet.receiver_type = b.ty("Animal");
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("d", null, b.call(b.path("Dog"), &.{b.str("Rex")})),
        b.valDecl("g", b.ty("String"), b.call(b.member(b.path("d"), "greet"), &.{})),
        b.exprStmt(b.call(b.path("println"), &.{b.path("g")})),
    });
    const f = b.file(&.{ .{ .Class = animal }, .{ .Class = dog }, .{ .Function = greet }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "stdlib_chain_infers_lambda_params_and_fold_result" {
    // fun main() { val r: Int = listOf(1,2,3).map { it*2 }.filter { it>0 }.fold(0) { acc, x -> acc + x }; println(r) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const list_of = b.call(b.path("listOf"), &.{ b.intLit(1), b.intLit(2), b.intLit(3) });
    const map_lam = b.lambda(&.{}, &.{b.exprStmt(b.binary(.Mul, b.path("it"), b.intLit(2)))});
    const mapped = b.call(b.member(list_of, "map"), &.{map_lam});
    const filter_lam = b.lambda(&.{}, &.{b.exprStmt(b.binary(.Gt, b.path("it"), b.intLit(0)))});
    const filtered = b.call(b.member(mapped, "filter"), &.{filter_lam});
    const fold_lam = b.lambda(&.{ "acc", "x" }, &.{b.exprStmt(b.binary(.Add, b.path("acc"), b.path("x")))});
    const folded = b.call(b.member(filtered, "fold"), &.{ b.intLit(0), fold_lam });
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("r", b.ty("Int"), folded),
        b.exprStmt(b.call(b.path("println"), &.{b.path("r")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "overload_picks_by_first_fit_arg_types" {
    // fun f(x: Int): Int = x
    // fun f(x: String): String = x
    // fun main() { val a: Int = f(1); val b: String = f("hi") }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fs = b.funExpr("f", &.{b.param("x", b.ty("String"))}, b.ty("String"), b.path("x"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Int"), b.call(b.path("f"), &.{b.intLit(1)})),
        b.valDecl("bb", b.ty("String"), b.call(b.path("f"), &.{b.str("hi")})),
    });
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fs }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "overload_picks_int_over_short_per_widen" {
    // fun f(x: Int): Int = x
    // fun f(x: Short): Short = x
    // fun main() { val a: Int = f(2) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fsh = b.funExpr("f", &.{b.param("x", b.ty("Short"))}, b.ty("Short"), b.path("x"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Int"), b.call(b.path("f"), &.{b.intLit(2)})),
    });
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fsh }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "named_arg_picks_matching_overload" {
    // fun f(x: Int): Int = x
    // fun f(name: String): String = name
    // fun main() { val s: String = f(name = "hi") }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fs = b.funExpr("f", &.{b.param("name", b.ty("String"))}, b.ty("String"), b.path("name"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", b.ty("String"), b.callN(b.path("f"), &.{b.str("hi")}, &.{"name"}, &.{})),
    });
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fs }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "named_arg_unknown_param_reports_t0089" {
    // fun f(x: Int): Int = x
    // fun f(y: Int): Int = y
    // fun main() { val _r = f(z = 1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fx = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fy = b.funExpr("f", &.{b.param("y", b.ty("Int"))}, b.ty("Int"), b.path("y"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", null, b.callN(b.path("f"), &.{b.intLit(1)}, &.{"z"}, &.{})),
    });
    const f = b.file(&.{ .{ .Function = fx }, .{ .Function = fy }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_NAMED_PARAMETER_NOT_FOUND));
}

test "type_arg_count_filters_overloads" {
    // fun <T> f(x: T): T = x
    // fun <T, U> f(x: T, y: U): T = x
    // fun main() { val r: Int = f<Int>(1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var f1 = b.funExpr("f", &.{b.param("x", b.ty("T"))}, b.ty("T"), b.path("x"));
    f1.type_params = b.slice(TypeParam, &.{b.typeParam("T")});
    var f2 = b.funExpr("f", &.{ b.param("x", b.ty("T")), b.param("y", b.ty("U")) }, b.ty("T"), b.path("x"));
    f2.type_params = b.slice(TypeParam, &.{ b.typeParam("T"), b.typeParam("U") });
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("r", b.ty("Int"), b.callN(b.path("f"), &.{b.intLit(1)}, &.{}, &.{b.ty("Int")})),
    });
    const f = b.file(&.{ .{ .Function = f1 }, .{ .Function = f2 }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "msc_picks_more_specific_subtype" {
    // open class Animal
    // class Dog : Animal()
    // fun f(a: Animal): Int = 1
    // fun f(d: Dog): String = "dog"
    // fun main() { val r: String = f(Dog()) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var animal = b.class("Animal");
    animal.is_open = true;
    var dog = b.class("Dog");
    dog.supertypes = b.slice(TypeRef, &.{b.ty("Animal")});
    dog.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{})});
    const fa = b.funExpr("f", &.{b.param("a", b.ty("Animal"))}, b.ty("Int"), b.intLit(1));
    const fd = b.funExpr("f", &.{b.param("d", b.ty("Dog"))}, b.ty("String"), b.str("dog"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("r", b.ty("String"), b.call(b.path("f"), &.{b.call(b.path("Dog"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = animal }, .{ .Class = dog }, .{ .Function = fa }, .{ .Function = fd }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "msc_non_parameterized_beats_parameterized" {
    // fun f(x: Int): Int = x
    // fun <T> f(x: T): Int = 0
    // fun main() { val _r: Int = f(1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    var fg = b.funExpr("f", &.{b.param("x", b.ty("T"))}, b.ty("Int"), b.intLit(0));
    fg.type_params = b.slice(TypeParam, &.{b.typeParam("T")});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", b.ty("Int"), b.call(b.path("f"), &.{b.intLit(1)})),
    });
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fg }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "conflicting_overloads_reports_t0094" {
    // fun f(x: Int): Int = x
    // fun f(y: Int): Int = y
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fx = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fy = b.funExpr("f", &.{b.param("y", b.ty("Int"))}, b.ty("Int"), b.path("y"));
    const f = b.file(&.{ .{ .Function = fx }, .{ .Function = fy } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_CONFLICTING_OVERLOADS));
}

test "distinct_overloads_no_conflict" {
    // fun f(x: Int): Int = x
    // fun f(x: String): String = x
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fs = b.funExpr("f", &.{b.param("x", b.ty("String"))}, b.ty("String"), b.path("x"));
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fs } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_CONFLICTING_OVERLOADS));
}

test "super_ambiguous_reports_t0093" {
    // interface A { fun f(): Int }
    // interface B { fun f(): Int }
    // class C : A, B { override fun f(): Int = super.f() + 1 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var ia = b.class("A");
    ia.is_interface = true;
    var fa = b.func("f", &.{}, b.ty("Int"), null);
    fa.is_abstract = true;
    ia.members = b.slice(Decl, &.{.{ .Function = fa }});
    var ib = b.class("B");
    ib.is_interface = true;
    var fb = b.func("f", &.{}, b.ty("Int"), null);
    fb.is_abstract = true;
    ib.members = b.slice(Decl, &.{.{ .Function = fb }});
    var cc = b.class("C");
    cc.supertypes = b.slice(TypeRef, &.{ b.ty("A"), b.ty("B") });
    cc.supertype_args = b.slice(?[]Expr, &.{ null, null });
    const super_call = b.call(b.member(.{ .Super = .{ .qualifier = null, .label = null, .span = b.ts() } }, "f"), &.{});
    var f_over = b.funExpr("f", &.{}, b.ty("Int"), b.binary(.Add, super_call, b.intLit(1)));
    f_over.is_override = true;
    cc.members = b.slice(Decl, &.{.{ .Function = f_over }});
    const f = b.file(&.{ .{ .Class = ia }, .{ .Class = ib }, .{ .Class = cc } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_AMBIGUOUS_SUPER));
}

test "super_qualified_unambiguous_ok" {
    // interface A { fun f(): Int { return 1 } }
    // interface B { fun f(): Int { return 2 } }
    // class C : A, B { override fun f(): Int = super<A>.f() + super<B>.f() }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var ia = b.class("A");
    ia.is_interface = true;
    ia.members = b.slice(Decl, &.{.{ .Function = b.funBlock("f", &.{}, b.ty("Int"), &.{b.exprStmt(b.returnExpr(b.intLit(1)))}) }});
    var ib = b.class("B");
    ib.is_interface = true;
    ib.members = b.slice(Decl, &.{.{ .Function = b.funBlock("f", &.{}, b.ty("Int"), &.{b.exprStmt(b.returnExpr(b.intLit(2)))}) }});
    var cc = b.class("C");
    cc.supertypes = b.slice(TypeRef, &.{ b.ty("A"), b.ty("B") });
    cc.supertype_args = b.slice(?[]Expr, &.{ null, null });
    const super_a = b.call(b.member(.{ .Super = .{ .qualifier = b.ty("A"), .label = null, .span = b.ts() } }, "f"), &.{});
    const super_b = b.call(b.member(.{ .Super = .{ .qualifier = b.ty("B"), .label = null, .span = b.ts() } }, "f"), &.{});
    var f_over = b.funExpr("f", &.{}, b.ty("Int"), b.binary(.Add, super_a, super_b));
    f_over.is_override = true;
    cc.members = b.slice(Decl, &.{.{ .Function = f_over }});
    const f = b.file(&.{ .{ .Class = ia }, .{ .Class = ib }, .{ .Class = cc } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_AMBIGUOUS_SUPER));
}

test "nothing_receiver_uses_extension_only" {
    // fun Any?.describe(): String = "x"
    // fun bottom(): Nothing = throw RuntimeException("x")
    // fun main() { val s: String = bottom().describe(); println(s) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var describe = b.funExpr("describe", &.{}, b.ty("String"), b.str("x"));
    describe.receiver_type = b.tyNull("Any");
    const bottom = b.funExpr("bottom", &.{}, b.ty("Nothing"), b.throwExpr(b.call(b.path("RuntimeException"), &.{b.str("x")})));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", b.ty("String"), b.call(b.member(b.call(b.path("bottom"), &.{}), "describe"), &.{})),
        b.exprStmt(b.call(b.path("println"), &.{b.path("s")})),
    });
    const f = b.file(&.{ .{ .Function = describe }, .{ .Function = bottom }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "msc_ambiguous_reports_t0091" {
    // interface I
    // interface J
    // class Both : I, J
    // fun f(x: I): Int = 1
    // fun f(x: J): Int = 2
    // fun main() { val _r: Int = f(Both()) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var ii = b.class("I");
    ii.is_interface = true;
    var ij = b.class("J");
    ij.is_interface = true;
    var both = b.class("Both");
    both.supertypes = b.slice(TypeRef, &.{ b.ty("I"), b.ty("J") });
    both.supertype_args = b.slice(?[]Expr, &.{ null, null });
    const fi = b.funExpr("f", &.{b.param("x", b.ty("I"))}, b.ty("Int"), b.intLit(1));
    const fj = b.funExpr("f", &.{b.param("x", b.ty("J"))}, b.ty("Int"), b.intLit(2));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", b.ty("Int"), b.call(b.path("f"), &.{b.call(b.path("Both"), &.{})})),
    });
    const f = b.file(&.{ .{ .Class = ii }, .{ .Class = ij }, .{ .Class = both }, .{ .Function = fi }, .{ .Function = fj }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_OVERLOAD_RESOLUTION_AMBIGUITY));
}

test "expect_actual_pair_is_not_ambiguous" {
    // expect fun mk(x: Int): Int
    // actual fun mk(x: Int): Int = x
    // fun main() { val _r: Int = mk(1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var mk_e = b.func("mk", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), null);
    mk_e.is_expect = true;
    var mk_a = b.funExpr("mk", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    mk_a.is_actual = true;
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", b.ty("Int"), b.call(b.path("mk"), &.{b.intLit(1)})),
    });
    const f = b.file(&.{ .{ .Function = mk_e }, .{ .Function = mk_a }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_OVERLOAD_RESOLUTION_AMBIGUITY));
}

test "msc_no_vararg_beats_vararg" {
    // fun f(x: Int): Int = x
    // fun f(vararg xs: Int): Int = 0
    // fun main() { val _r: Int = f(1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fv = b.funExpr("f", &.{b.varargParam("xs", b.ty("Int"))}, b.ty("Int"), b.intLit(0));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", b.ty("Int"), b.call(b.path("f"), &.{b.intLit(1)})),
    });
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fv }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "none_applicable_reports_t0090" {
    // fun f(x: Int): Int = x
    // fun f(x: Int, y: Int): Int = x + y
    // fun main() { val _r = f(1, 2, 3) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f1 = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const f2 = b.funExpr("f", &.{ b.param("x", b.ty("Int")), b.param("y", b.ty("Int")) }, b.ty("Int"), b.binary(.Add, b.path("x"), b.path("y")));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", null, b.call(b.path("f"), &.{ b.intLit(1), b.intLit(2), b.intLit(3) })),
    });
    const f = b.file(&.{ .{ .Function = f1 }, .{ .Function = f2 }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_NONE_APPLICABLE));
}

test "type_arg_count_mismatch_reports_t0092" {
    // fun f(x: Int): Int = x
    // fun main() { val _r = f<Int>(1) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("_r", null, b.callN(b.path("f"), &.{b.intLit(1)}, &.{}, &.{b.ty("Int")})),
    });
    const f = b.file(&.{ .{ .Function = f0 }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_TYPE_ARGUMENT_COUNT_MISMATCH));
}

test "overload_picks_int_over_long_per_widen" {
    // fun f(x: Int): Int = x
    // fun f(x: Long): Long = x
    // fun main() { val a: Int = f(2) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const fi = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    const fl = b.funExpr("f", &.{b.param("x", b.ty("Long"))}, b.ty("Long"), b.path("x"));
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Int"), b.call(b.path("f"), &.{b.intLit(2)})),
    });
    const f = b.file(&.{ .{ .Function = fi }, .{ .Function = fl }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "smart_cast_narrows_val_member_chain" {
    // open class Shape
    // class Circle(val radius: Int) : Shape()
    // class Wrapper(val shape: Shape)
    // fun area(w: Wrapper): Int { if (w.shape is Circle) { return w.shape.radius }; return 0 }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var shape = b.class("Shape");
    shape.is_open = true;
    var circle = b.class("Circle");
    circle.primary_params = b.slice(ast.ClassParam, &.{b.valParam("radius", b.ty("Int"))});
    circle.supertypes = b.slice(TypeRef, &.{b.ty("Shape")});
    circle.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{})});
    var wrapper = b.class("Wrapper");
    wrapper.primary_params = b.slice(ast.ClassParam, &.{b.valParam("shape", b.ty("Shape"))});
    const area = b.funBlock("area", &.{b.param("w", b.ty("Wrapper"))}, b.ty("Int"), &.{
        b.exprStmt(b.ifExpr(
            b.isCheck(b.member(b.path("w"), "shape"), b.ty("Circle"), false),
            b.block(&.{b.exprStmt(b.returnExpr(b.member(b.member(b.path("w"), "shape"), "radius")))}),
            null,
        )),
        b.exprStmt(b.returnExpr(b.intLit(0))),
    });
    const f = b.file(&.{ .{ .Class = shape }, .{ .Class = circle }, .{ .Class = wrapper }, .{ .Function = area } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "unreachable_after_return" {
    // fun main() { return; println("dead") }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.returnExpr(null)),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_UNREACHABLE_CODE));
}

test "unreachable_after_throw" {
    // fun main() { throw RuntimeException("x"); println("dead") }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.throwExpr(b.call(b.path("RuntimeException"), &.{b.str("x")}))),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_UNREACHABLE_CODE));
}

test "unreachable_after_nothing_typed_call" {
    // fun boom(): Nothing { throw RuntimeException("x") }
    // fun main() { boom(); println("dead") }
    // The reachability query consumes the maintained per-function set of
    // Nothing-typed spans: code after a call typed `Nothing` is dead.
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const boom = b.funBlock("boom", &.{}, b.ty("Nothing"), &.{
        b.exprStmt(b.throwExpr(b.call(b.path("RuntimeException"), &.{b.str("x")}))),
    });
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("boom"), &.{})),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead")})),
    });
    const f = b.file(&.{ .{ .Function = boom }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_UNREACHABLE_CODE));
}

test "unreachable_memo_does_not_leak_across_functions" {
    // fun boom(): Nothing { throw RuntimeException("x") }
    // fun dead() { boom(); println("dead") }
    // fun alive() { println("ok"); println("still ok") }
    // The memoized per-function reachability solve must not let `dead`'s
    // divergence mark statements in `alive` unreachable, and `alive`'s
    // clean solve must not mask the warning in `dead`.
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const boom = b.funBlock("boom", &.{}, b.ty("Nothing"), &.{
        b.exprStmt(b.throwExpr(b.call(b.path("RuntimeException"), &.{b.str("x")}))),
    });
    const dead = b.funBlock("dead", &.{}, null, &.{
        b.exprStmt(b.call(b.path("boom"), &.{})),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead")})),
    });
    const alive = b.funBlock("alive", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.str("ok")})),
        b.exprStmt(b.call(b.path("println"), &.{b.str("still ok")})),
    });
    const f = b.file(&.{ .{ .Function = boom }, .{ .Function = dead }, .{ .Function = alive } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.countCode(codes.WARN_UNREACHABLE_CODE));
}

test "unreachable_warns_in_each_diverging_function" {
    // Two functions that each diverge mid-body: the per-function memo must
    // recompute when the Nothing-span set grows, warning in both.
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f1 = b.funBlock("f1", &.{}, null, &.{
        b.exprStmt(b.returnExpr(null)),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead1")})),
    });
    const f2 = b.funBlock("f2", &.{}, null, &.{
        b.exprStmt(b.returnExpr(null)),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead2")})),
    });
    const f = b.file(&.{ .{ .Function = f1 }, .{ .Function = f2 } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.countCode(codes.WARN_UNREACHABLE_CODE));
}

test "senseless_comparison_nonnull_eq_null" {
    // fun main() { val x: Int = 5; if (x == null) { println("nope") } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Int"), b.intLit(5)),
        b.exprStmt(b.ifExpr(
            b.binary(.Eq, b.path("x"), b.nullLit()),
            b.block(&.{b.exprStmt(b.call(b.path("println"), &.{b.str("nope")}))}),
            null,
        )),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_SENSELESS_COMPARISON));
}

test "useless_cast_same_type" {
    // fun main() { val x: Int = 5; val y = x as Int; println(y) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Int"), b.intLit(5)),
        b.valDecl("y", null, b.asCast(b.path("x"), b.ty("Int"), false)),
        b.exprStmt(b.call(b.path("println"), &.{b.path("y")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_USELESS_CAST));
}

test "useless_elvis_nonnull_lhs" {
    // fun main() { val x: Int = 5; val y = x ?: 0; println(y) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Int"), b.intLit(5)),
        b.valDecl("y", null, b.binary(.Elvis, b.path("x"), b.intLit(0))),
        b.exprStmt(b.call(b.path("println"), &.{b.path("y")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_USELESS_ELVIS));
}

test "finally_return_makes_continuation_unreachable" {
    // fun main() { try { println("try") } finally { return }; println("dead") }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const try_expr: Expr = .{ .Try = .{
        .body = .{ .stmts = b.slice(Stmt, &.{b.exprStmt(b.call(b.path("println"), &.{b.str("try")}))}), .span = b.ts() },
        .catches = &.{},
        .finally = .{ .stmts = b.slice(Stmt, &.{b.exprStmt(b.returnExpr(null))}), .span = b.ts() },
        .span = b.ts(),
    } };
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(try_expr),
        b.exprStmt(b.call(b.path("println"), &.{b.str("dead")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_UNREACHABLE_CODE));
}

test "var_reassign_kills_narrowing" {
    // fun src(): String? = null
    // fun main() { var x: String? = "ok"; if (x != null) { while (true) { x = src(); println(x.length) } } }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const src = b.funExpr("src", &.{}, b.tyNull("String"), b.nullLit());
    const loop_body = b.block(&.{
        b.assign(b.path("x"), b.call(b.path("src"), &.{})),
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.path("x"), "length")})),
    });
    const main = b.funBlock("main", &.{}, null, &.{
        b.varDecl("x", b.tyNull("String"), b.str("ok")),
        b.exprStmt(b.ifExpr(
            b.binary(.Neq, b.path("x"), b.nullLit()),
            b.block(&.{b.exprStmt(b.whileExpr(b.boolLit(true), loop_body))}),
            null,
        )),
    });
    const f = b.file(&.{ .{ .Function = src }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_NULL_SAFETY));
}

test "class_val_property_uninit_in_init_block" {
    // class Foo(b: Boolean) { val x: Int; init { if (b) { x = 1 } } }
    // fun main() { println(Foo(true).x) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var foo = b.class("Foo");
    foo.primary_params = b.slice(ast.ClassParam, &.{b.plainCtorParam("b", b.ty("Boolean"))});
    foo.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, b.prop(false, "x", b.ty("Int"), null)) }});
    const init_blk: Block = .{
        .stmts = b.slice(Stmt, &.{b.exprStmt(b.ifExpr(
            b.path("b"),
            b.block(&.{b.assign(b.path("x"), b.intLit(1))}),
            null,
        ))}),
        .span = b.ts(),
    };
    foo.init_blocks = b.slice(Block, &.{init_blk});
    foo.init_block_positions = b.slice(usize, &.{0});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.call(b.path("Foo"), &.{b.boolLit(true)}), "x")})),
    });
    const f = b.file(&.{ .{ .Class = foo }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_VAR_NOT_DEFINITELY_ASSIGNED));
}

test "class_val_property_initialized_in_all_init_branches" {
    // class Foo(b: Boolean) { val x: Int; init { if (b) { x = 1 } else { x = 2 } } }
    // fun main() { println(Foo(true).x) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var foo = b.class("Foo");
    foo.primary_params = b.slice(ast.ClassParam, &.{b.plainCtorParam("b", b.ty("Boolean"))});
    foo.members = b.slice(Decl, &.{.{ .Property = b.dup(Property, b.prop(false, "x", b.ty("Int"), null)) }});
    const init_blk: Block = .{
        .stmts = b.slice(Stmt, &.{b.exprStmt(b.ifExpr(
            b.path("b"),
            b.block(&.{b.assign(b.path("x"), b.intLit(1))}),
            b.block(&.{b.assign(b.path("x"), b.intLit(2))}),
        ))}),
        .span = b.ts(),
    };
    foo.init_blocks = b.slice(Block, &.{init_blk});
    foo.init_block_positions = b.slice(usize, &.{0});
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.member(b.call(b.path("Foo"), &.{b.boolLit(true)}), "x")})),
    });
    const f = b.file(&.{ .{ .Class = foo }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "notnull_narrows_subject" {
    // fun main() { val s: String? = "hi"; s!!; val n: Int = s.length; println(n) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", b.tyNull("String"), b.str("hi")),
        b.exprStmt(b.postfix(.NotNull, b.path("s"))),
        b.valDecl("n", b.ty("Int"), b.member(b.path("s"), "length")),
        b.exprStmt(b.call(b.path("println"), &.{b.path("n")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "as_cast_narrows_subject" {
    // fun main() { val a: Any = "hi"; val s = a as String; val n: Int = a.length; println(s); println(n) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("a", b.ty("Any"), b.str("hi")),
        b.valDecl("s", null, b.asCast(b.path("a"), b.ty("String"), false)),
        b.valDecl("n", b.ty("Int"), b.member(b.path("a"), "length")),
        b.exprStmt(b.call(b.path("println"), &.{b.path("s")})),
        b.exprStmt(b.call(b.path("println"), &.{b.path("n")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "contract_run_initializes_val" {
    // fun main() { val x: Int; run { x = 4 }; println(x) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const run_lam = b.lambda(&.{}, &.{b.assign(b.path("x"), b.intLit(4))});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Int"), null),
        b.exprStmt(b.call(b.path("run"), &.{run_lam})),
        b.exprStmt(b.call(b.path("println"), &.{b.path("x")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "contract_check_introduces_smartcast" {
    // fun main() { val x: Any = 42; check(x is Int); val y: Int = x + 1; println(y) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("x", b.ty("Any"), b.intLit(42)),
        b.exprStmt(b.call(b.path("check"), &.{b.isCheck(b.path("x"), b.ty("Int"), false)})),
        b.valDecl("y", b.ty("Int"), b.binary(.Add, b.path("x"), b.intLit(1))),
        b.exprStmt(b.call(b.path("println"), &.{b.path("y")})),
    });
    const f = b.file(&.{.{ .Function = main }});
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "contract_require_nonnull" {
    // fun f(s: String?): Int { require(s != null); return s.length }
    // fun main() { println(f("hi")) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const f0 = b.funBlock("f", &.{b.param("s", b.tyNull("String"))}, b.ty("Int"), &.{
        b.exprStmt(b.call(b.path("require"), &.{b.binary(.Neq, b.path("s"), b.nullLit())})),
        b.exprStmt(b.returnExpr(b.member(b.path("s"), "length"))),
    });
    const main = b.funBlock("main", &.{}, null, &.{
        b.exprStmt(b.call(b.path("println"), &.{b.call(b.path("f"), &.{b.str("hi")})})),
    });
    const f = b.file(&.{ .{ .Function = f0 }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "infer_call_return_propagates_arg_type" {
    // fun <T> id(x: T): T = x
    // fun main() { val n: Int = id(5); val s: String = id("hi"); println(n); println(s) }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var id = b.funExpr("id", &.{b.param("x", b.ty("T"))}, b.ty("T"), b.path("x"));
    id.type_params = b.slice(TypeParam, &.{b.typeParam("T")});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("n", b.ty("Int"), b.call(b.path("id"), &.{b.intLit(5)})),
        b.valDecl("s", b.ty("String"), b.call(b.path("id"), &.{b.str("hi")})),
        b.exprStmt(b.call(b.path("println"), &.{b.path("n")})),
        b.exprStmt(b.call(b.path("println"), &.{b.path("s")})),
    });
    const f = b.file(&.{ .{ .Function = id }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "opt_in_marker_propagates" {
    // @RequiresOptIn annotation class Experimental
    // @Experimental fun risky(): Int = 1
    // fun unsafe(): Int = risky()
    // @OptIn(Experimental::class) fun safe(): Int = risky()
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var experimental = b.class("Experimental");
    experimental.is_annotation = true;
    experimental.annotations = b.slice(Annotation, &.{b.annotation("RequiresOptIn", &.{})});
    var risky = b.funExpr("risky", &.{}, b.ty("Int"), b.intLit(1));
    risky.annotations = b.slice(Annotation, &.{b.annotation("Experimental", &.{})});
    const unsafe = b.funExpr("unsafe", &.{}, b.ty("Int"), b.call(b.path("risky"), &.{}));
    var safe = b.funExpr("safe", &.{}, b.ty("Int"), b.call(b.path("risky"), &.{}));
    const opt_in_arg: Expr = .{ .MemberRef = .{ .receiver = b.dup(Expr, b.path("Experimental")), .name = b.ident("class"), .span = b.ts() } };
    safe.annotations = b.slice(Annotation, &.{b.annotation("OptIn", &.{opt_in_arg})});
    const f = b.file(&.{ .{ .Class = experimental }, .{ .Function = risky }, .{ .Function = unsafe }, .{ .Function = safe } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.countCode(codes.TYPE_OPT_IN_REQUIRED));
}

test "suppress_silences_deprecation_warning" {
    // @Deprecated("gone") fun foo(): Int = 1
    // fun caller(): Int = foo()
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var foo = b.funExpr("foo", &.{}, b.ty("Int"), b.intLit(1));
    foo.annotations = b.slice(Annotation, &.{b.annotation("Deprecated", &.{b.str("gone")})});
    const caller = b.funExpr("caller", &.{}, b.ty("Int"), b.call(b.path("foo"), &.{}));
    const f = b.file(&.{ .{ .Function = foo }, .{ .Function = caller } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.WARN_DEPRECATED));

    // @Deprecated("gone") fun foo(): Int = 1
    // @Suppress("W0006") fun caller(): Int = foo()
    var b2 = Builder.init(testing.allocator);
    defer b2.deinit();
    var foo2 = b2.funExpr("foo", &.{}, b2.ty("Int"), b2.intLit(1));
    foo2.annotations = b2.slice(Annotation, &.{b2.annotation("Deprecated", &.{b2.str("gone")})});
    const caller_start = b2.snap();
    var caller2 = b2.funExpr("caller", &.{}, b2.ty("Int"), b2.call(b2.path("foo"), &.{}));
    caller2.annotations = b2.slice(Annotation, &.{b2.annotation("Suppress", &.{b2.str("W0006")})});
    // The function's source span encloses its body so the `@Suppress`
    // region covers the deprecated call inside it.
    caller2.span = b2.spanFrom(caller_start);
    const f2 = b2.file(&.{ .{ .Function = foo2 }, .{ .Function = caller2 } });
    var c2 = checkFile(testing.allocator, &f2);
    defer c2.deinit();
    try testing.expect(!c2.hasCode(codes.WARN_DEPRECATED));
}

test "member_access_inherits_from_supertype" {
    // open class Base(val tag: String)
    // class Sub(t: String) : Base(t)
    // fun main() { val s = Sub("hi"); val t: String = s.tag }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var base = b.class("Base");
    base.is_open = true;
    base.primary_params = b.slice(ast.ClassParam, &.{b.valParam("tag", b.ty("String"))});
    var sub = b.class("Sub");
    sub.primary_params = b.slice(ast.ClassParam, &.{b.plainCtorParam("t", b.ty("String"))});
    sub.supertypes = b.slice(TypeRef, &.{b.ty("Base")});
    sub.supertype_args = b.slice(?[]Expr, &.{b.slice(Expr, &.{b.path("t")})});
    const main = b.funBlock("main", &.{}, null, &.{
        b.valDecl("s", null, b.call(b.path("Sub"), &.{b.str("hi")})),
        b.valDecl("t", b.ty("String"), b.member(b.path("s"), "tag")),
    });
    const f = b.file(&.{ .{ .Class = base }, .{ .Class = sub }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasErrors());
}

test "suspend_call_from_suspend_ok" {
    // suspend fun a() {}
    // suspend fun b() { a() }
    // fun main() {}
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var fa = b.funBlock("a", &.{}, null, &.{});
    fa.is_suspend = true;
    var fb = b.funBlock("b", &.{}, null, &.{b.exprStmt(b.call(b.path("a"), &.{}))});
    fb.is_suspend = true;
    const main = b.funBlock("main", &.{}, null, &.{});
    const f = b.file(&.{ .{ .Function = fa }, .{ .Function = fb }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(!c.hasCode(codes.TYPE_SUSPEND_CALL_FROM_NON_SUSPEND));
}

test "suspend_call_from_non_suspend_flagged" {
    // suspend fun a() {}
    // fun main() { a() }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var fa = b.funBlock("a", &.{}, null, &.{});
    fa.is_suspend = true;
    const main = b.funBlock("main", &.{}, null, &.{b.exprStmt(b.call(b.path("a"), &.{}))});
    const f = b.file(&.{ .{ .Function = fa }, .{ .Function = main } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_SUSPEND_CALL_FROM_NON_SUSPEND));
}

test "suspend_call_inside_anon_fun_marked_suspend" {
    // suspend fun a() {}
    // fun outer() { val f = fun() { a() }; f() }
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var fa = b.funBlock("a", &.{}, null, &.{});
    fa.is_suspend = true;
    const anon = b.anonFun(&.{}, null, b.call(b.path("a"), &.{}));
    const outer = b.funBlock("outer", &.{}, null, &.{
        b.valDecl("f", null, anon),
        b.exprStmt(b.call(b.path("f"), &.{})),
    });
    const f = b.file(&.{ .{ .Function = fa }, .{ .Function = outer } });
    var c = checkFile(testing.allocator, &f);
    defer c.deinit();
    try testing.expect(c.hasCode(codes.TYPE_SUSPEND_CALL_FROM_NON_SUSPEND));
}

// ---------------------------------------------------------------------------
// Module-level (multi-file) checks: conflicting overloads are per package.
// ---------------------------------------------------------------------------

/// Re-home every span a test function carries onto `fid` so the checker's
/// per-file package map (and cross-file visibility checks) see the decl in
/// the right file.
fn rehomeFn(f: *Function, fid: FileId) void {
    f.span.file = fid;
    f.name.span.file = fid;
}

fn pkgFile(b: *Builder, pkg_name: ?[]const u8, decls: []const Decl, fid: FileId) KotlinFile {
    var f = b.file(decls);
    f.span.file = fid;
    if (pkg_name) |pn| {
        const idents = b.arena.allocator().alloc(Ident, 1) catch unreachable;
        idents[0] = b.ident(pn);
        f.package = .{ .path = idents, .span = f.span };
    }
    return f;
}

fn checkModule(gpa: std.mem.Allocator, files: []const KotlinFile) Checked {
    const arena = gpa.create(std.heap.ArenaAllocator) catch unreachable;
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var res = resolver.resolveModule(a, files) catch unreachable;
    const tc = check.typecheckModule(a, files, &res) catch unreachable;
    return .{ .arena = arena, .res = res, .tc = tc };
}

test "module: cross-package same-signature functions are not conflicting overloads" {
    // liba.kt: package liba; fun f(x: Int): Int = x
    // libb.kt: package libb; fun f(x: Int): Int = x
    // kotlinc compiles this module clean — the conflicting-overloads
    // domain is one package, so no T0094.
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var fa = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    rehomeFn(&fa, FileId.from(1));
    var fb = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    rehomeFn(&fb, FileId.from(2));
    const file_a = pkgFile(&b, "liba", &.{.{ .Function = fa }}, FileId.from(1));
    const file_b = pkgFile(&b, "libb", &.{.{ .Function = fb }}, FileId.from(2));
    var c = checkModule(testing.allocator, &.{ file_a, file_b });
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.countCode(codes.TYPE_CONFLICTING_OVERLOADS));
}

test "module: same-package same-signature functions across files still conflict" {
    // a.kt + b.kt both `package liba` declaring `fun f(x: Int): Int` —
    // one package, identical signatures: kotlinc rejects, T0094 fires.
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    var fa = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    rehomeFn(&fa, FileId.from(1));
    var fb = b.funExpr("f", &.{b.param("x", b.ty("Int"))}, b.ty("Int"), b.path("x"));
    rehomeFn(&fb, FileId.from(2));
    const file_a = pkgFile(&b, "liba", &.{.{ .Function = fa }}, FileId.from(1));
    const file_b = pkgFile(&b, "liba", &.{.{ .Function = fb }}, FileId.from(2));
    var c = checkModule(testing.allocator, &.{ file_a, file_b });
    defer c.deinit();
    try testing.expect(c.countCode(codes.TYPE_CONFLICTING_OVERLOADS) >= 1);
}
