//! Callable reference closures.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const Reg = ir.Reg;
const FuncId = ir.FuncId;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const binary_mod = @import("binary.zig");
const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;

const type_probe_mod = @import("type_probe.zig");
const simpleTypeHead = type_probe_mod.simpleTypeHead;

const probe_mod = @import("probe.zig");
const eagerLambdaRecvHead = probe_mod.eagerLambdaRecvHead;

/// Sibling-arg reified inference: when an argument of a resolved call is
/// itself a bare 0-arg call to a single-type-param fn with no type args
/// (`enumEntries()`), and a SIBLING argument bound to the same declared
/// type variable statically names an enum (`EmptyEnum.entries`,
/// `EmptyEnum.values().toList()`), the enum solves the nested call's
/// reified argument. Records the solution keyed by the nested call's AST
/// node; `emitCall` consumes it when that node lowers with no type args
/// of its own.
/// `::name` in a slot whose DECLARED function type solves the referenced
/// fn's single reified type parameter (`val empty: () -> EnumEntries<E> =
/// ::enumEntries`): the reference lowers as a zero-arg closure over the
/// call with the solved type argument stamped — a plain function value
/// carries no type args, so invoking it later would lose the reification.
/// AST synthesized from the MODULE allocator (lambda bodies are
/// runtime-read).
/// Eta-expand a bare `::localExt` reference into
/// `{ p0..pN -> localExt(p0..pN) }`: the synthesized bare call resolves
/// the local extension through the ordinary local-ext machinery (its
/// receiver supplied by the enclosing `this`), and the closure carries
/// the value-parameter arity the reference's use site applies.
pub fn localExtRefClosure(b: *FuncBuilder, name: []const u8, sp: ast.Span) Allocator.Error!?Reg {
    // Value-parameter count: the declaring builder recorded the local fn's
    // positional params; inside a nested lambda builder that record is not
    // inherited, so the use site's expected callable arity (the
    // function-typed parameter slot the reference fills) supplies it.
    const n: usize = blk: {
        if (b.localExtFnArity(name)) |a| break :blk @intCast(a);
        if (b.localFnParamTys(name)) |tys| break :blk tys.len;
        if (b.pending_lambda_arity >= 0) break :blk @intCast(b.pending_lambda_arity);
        if (b.peekExpected()) |exp| {
            if (exp.function) |ft| break :blk ft.params.len;
        }
        return null;
    };
    const ma = b.module.func_name_index.allocator;
    const params = try ma.alloc(ast.Ident, n);
    const args = try ma.alloc(ast.Expr, n);
    for (0..n) |i| {
        const pn = try std.fmt.allocPrint(ma, "$ref$p{d}", .{i});
        params[i] = .{ .name = pn, .span = sp };
        const segs_i = try ma.alloc(ast.Ident, 1);
        segs_i[0] = .{ .name = pn, .span = sp };
        args[i] = .{ .Path = .{ .segments = segs_i, .span = sp } };
    }
    const anames = try ma.alloc(?[]const u8, n);
    for (anames) |*a| a.* = null;
    const segs = try ma.alloc(ast.Ident, 1);
    segs[0] = .{ .name = try ma.dupe(u8, name), .span = sp };
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = sp } };
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = anames,
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = .{ .Lambda = .{
        .params = params,
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    return try lowerExpr(b, boxed);
}

/// A callable reference used as a function type that differs from the
/// target's signature — fewer parameters through defaults or a vararg, or
/// a result coerced to Unit — is an adapted reference: a distinct callable
/// per adaptation, equal to any other adaptation of the same kind of the
/// same target. Lower it as a forwarding lambda of the expected arity,
/// keyed by target and shape; a reference whose shape matches keeps the
/// plain function value.
/// The expected parameter type heads at a reference site (`Int|String`),
/// interned for the instruction; null when the site has no function type.
pub fn expectedHeadsConst(b: *FuncBuilder) Allocator.Error!?ConstId {
    const types = b.pending_ref_lambda_param_types orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(b.allocator);
    for (types, 0..) |*t, i| {
        if (i > 0) try buf.append(b.allocator, '|');
        try buf.appendSlice(b.allocator, simpleTypeHead(t.name));
    }
    return try b.module.internConst(b.allocator, .{ .String = try b.allocator.dupe(u8, buf.items) });
}

/// Whether the expected type head at a vararg parameter's position is an
/// array (`(Array<String>) -> Unit` takes the vararg as written).
fn isArrayHead(head: []const u8) bool {
    return std.mem.eql(u8, head, "Array") or std.mem.endsWith(u8, head, "Array");
}

pub fn isVarargIntrinsicName(name: []const u8) bool {
    const names = [_][]const u8{
        "arrayOf",       "intArrayOf",     "longArrayOf",   "shortArrayOf",  "byteArrayOf",
        "charArrayOf",   "booleanArrayOf", "floatArrayOf",  "doubleArrayOf", "listOf",
        "mutableListOf", "arrayListOf",    "setOf",         "mutableSetOf",  "hashSetOf",
        "linkedSetOf",   "sequenceOf",     "sortedSetOf",
    };
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// `{ p0 -> arrayOf(*p0) }`: the reference's single slot is the array a
/// vararg intrinsic would otherwise wrap again.
pub fn varargIntrinsicRefClosure(b: *FuncBuilder, name: []const u8, sp: ast.Span) Allocator.Error!?Reg {
    const slot_is_array = blk: {
        if (b.pending_ref_lambda_param_types) |types| {
            if (b.pending_lambda_arity != 1) break :blk false;
            break :blk types.len == 1 and isArrayHead(simpleTypeHead(types[0].name));
        }
        const expected = b.peekExpected() orelse break :blk false;
        const ft = expected.function orelse break :blk false;
        if (ft.receiver != null or ft.params.len != 1) break :blk false;
        break :blk isArrayHead(simpleTypeHead(ft.params[0].name.name));
    };
    if (!slot_is_array) return null;
    const ma = b.module.func_name_index.allocator;
    const params = try ma.alloc(ast.Ident, 1);
    const pn = try ma.dupe(u8, "$ref$p0");
    params[0] = .{ .name = pn, .span = sp };
    const segs_p = try ma.alloc(ast.Ident, 1);
    segs_p[0] = .{ .name = pn, .span = sp };
    const inner = try ma.create(ast.Expr);
    inner.* = .{ .Path = .{ .segments = segs_p, .span = sp } };
    const args = try ma.alloc(ast.Expr, 1);
    args[0] = .{ .Spread = .{ .expr = inner, .span = sp } };
    const anames = try ma.alloc(?[]const u8, 1);
    anames[0] = null;
    const segs = try ma.alloc(ast.Ident, 1);
    segs[0] = .{ .name = try ma.dupe(u8, name), .span = sp };
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = sp } };
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = anames,
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = .{ .Lambda = .{
        .params = params,
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    return try lowerExpr(b, boxed);
}

/// `{ p0, … -> value.localExt(p0, …) }` for a bound reference to a local
/// extension function; the arity is the expected function type's, else the
/// local's declared parameter count.
pub fn boundLocalExtRefClosure(b: *FuncBuilder, receiver: *const Expr, name: []const u8, sp: ast.Span) Allocator.Error!?Reg {
    const n: usize = if (b.pending_lambda_arity >= 0)
        @intCast(b.pending_lambda_arity)
    else if (b.localExtFnArity(name)) |declared|
        @intCast(@max(declared, 0))
    else
        return null;
    const ma = b.module.func_name_index.allocator;
    const params = try ma.alloc(ast.Ident, n);
    const args = try ma.alloc(ast.Expr, n);
    for (0..n) |i| {
        const pn = try std.fmt.allocPrint(ma, "$ref$p{d}", .{i});
        params[i] = .{ .name = pn, .span = sp };
        const segs_i = try ma.alloc(ast.Ident, 1);
        segs_i[0] = .{ .name = pn, .span = sp };
        args[i] = .{ .Path = .{ .segments = segs_i, .span = sp } };
    }
    const anames = try ma.alloc(?[]const u8, n);
    for (anames) |*a| a.* = null;
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Member = .{ .receiver = @constCast(receiver), .name = .{ .name = try ma.dupe(u8, name), .span = sp }, .safe = false, .span = sp } };
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = anames,
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = .{ .Lambda = .{
        .params = params,
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    return try lowerExpr(b, boxed);
}

pub fn isArrayCtorRefName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "Array")) return true;
    return std.mem.endsWith(u8, name, "Array") and isPrimitiveTypeName(name[0 .. name.len - "Array".len]);
}

/// `{ p0, p1 -> Array(p0, p1) }` for `::Array` (or `{ p0 -> IntArray(p0) }`
/// for a size-only reference): the arity is the expected function type's,
/// else the (size, init) form for `Array` and the size form for a
/// primitive array.
pub fn arrayCtorRefClosure(b: *FuncBuilder, name: []const u8, sp: ast.Span) Allocator.Error!?Reg {
    const n: usize = if (b.pending_lambda_arity >= 0)
        @intCast(b.pending_lambda_arity)
    else if (std.mem.eql(u8, name, "Array")) 2 else 1;
    if (n == 0 or n > 2) return null;
    const ma = b.module.func_name_index.allocator;
    const params = try ma.alloc(ast.Ident, n);
    const args = try ma.alloc(ast.Expr, n);
    for (0..n) |i| {
        const pn = try std.fmt.allocPrint(ma, "$ref$p{d}", .{i});
        params[i] = .{ .name = pn, .span = sp };
        const segs_i = try ma.alloc(ast.Ident, 1);
        segs_i[0] = .{ .name = pn, .span = sp };
        args[i] = .{ .Path = .{ .segments = segs_i, .span = sp } };
    }
    const anames = try ma.alloc(?[]const u8, n);
    for (anames) |*a| a.* = null;
    const segs = try ma.alloc(ast.Ident, 1);
    segs[0] = .{ .name = try ma.dupe(u8, name), .span = sp };
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = sp } };
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = anames,
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = .{ .Lambda = .{
        .params = params,
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    return try lowerExpr(b, boxed);
}

/// When every declaration named `name` is an extension function, the
/// innermost implicit receiver class whose hierarchy satisfies one of
/// their receiver types: the current extension receiver, the owner class,
/// then each enclosing class outward. Null when none does.
pub fn bareRefExtensionReceiverClass(b: *FuncBuilder, name: []const u8) ?[]const u8 {
    const cands = b.module.funcsBySimpleName(name);
    if (cands.len == 0) return null;
    for (cands) |fid| {
        const f = b.module.funcById(fid) orelse return null;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) return null;
    }
    const Match = struct {
        fn any(mod: *const ir.Module, fids: []const FuncId, cls: []const u8) bool {
            for (fids) |fid| {
                const f = mod.funcById(fid) orelse continue;
                const head = simpleTypeHead(std.mem.trimEnd(u8, f.params[0].ty.name, "?"));
                if (classHierarchyHasName(mod, cls, head)) return true;
            }
            return false;
        }
    };
    if (b.recvTy()) |rt| {
        if (Match.any(b.module, cands, rt)) return rt;
    }
    // Receiver lambdas (`with(a) { ::ext }`) contribute their receivers,
    // innermost first, ahead of the lexical owner chain.
    const tower = b.collectImplicitReceiverTower(b.allocator, eagerLambdaRecvHead(b)) catch &.{};
    defer b.allocator.free(tower);
    for (tower) |head| {
        if (Match.any(b.module, cands, head)) return head;
    }
    var cur: ?[]const u8 = b.ownerClass();
    var depth: usize = 0;
    while (cur) |c| : (depth += 1) {
        if (depth > 16) break;
        if (Match.any(b.module, cands, c)) return c;
        cur = b.module.registry.enclosing_class.get(c);
    }
    return null;
}

/// Whether `name` has declarations and every one is an extension function.
pub fn bareRefNamesOnlyExtensions(b: *const FuncBuilder, name: []const u8) bool {
    const cands = b.module.funcsBySimpleName(name);
    if (cands.len == 0) return false;
    for (cands) |fid| {
        const f = b.module.funcById(fid) orelse return false;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) return false;
    }
    return true;
}

/// The innermost class among the owner and its enclosing classes whose
/// hierarchy declares a member named `name`; null when none does.
pub fn enclosingClassDeclaringMember(b: *const FuncBuilder, name: []const u8) ?[]const u8 {
    var cur: ?[]const u8 = b.ownerClass();
    var depth: usize = 0;
    while (cur) |c| : (depth += 1) {
        if (depth > 16) break;
        if (b.module.registry.hierarchy_methods.get(c)) |m| {
            if (m.contains(name)) return c;
        }
        if (b.module.registry.hierarchy_shadow_names.get(c)) |hs| {
            if (hs.names.contains(name)) return c;
        }
        cur = b.module.registry.enclosing_class.get(c);
    }
    return null;
}

fn classHierarchyHasName(module: *const ir.Module, class_name: []const u8, want: []const u8) bool {
    if (std.mem.eql(u8, simpleTypeHead(class_name), want)) return true;
    const cid = module.classId(class_name) orelse module.classIdByFqn(class_name) orelse return false;
    return classIdHierarchyHasName(module, cid, want, 0);
}

fn classIdHierarchyHasName(module: *const ir.Module, cid: ir.ClassId, want: []const u8, depth: u8) bool {
    if (depth >= 64 or cid.int() >= module.classes.items.len) return false;
    const c = &module.classes.items[cid.int()];
    if (std.mem.eql(u8, simpleTypeHead(c.name), want) or std.mem.eql(u8, simpleTypeHead(c.fqn), want)) return true;
    for (c.supertypes) |p| {
        if (classIdHierarchyHasName(module, p, want, depth + 1)) return true;
    }
    return false;
}

pub fn adaptedRefClosure(b: *FuncBuilder, name: []const u8, sp: ast.Span, fid: FuncId) Allocator.Error!?Reg {
    const f = b.module.funcById(fid) orelse return null;
    if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) return null;
    if (b.pending_lambda_arity < 0) return null;
    const n: usize = @intCast(b.pending_lambda_arity);
    const returns_unit = std.mem.eql(u8, simpleTypeHead(f.return_ty.name), "Unit");
    const unit = b.pending_ref_lambda_unit and !returns_unit;
    var vararg_at: ?usize = null;
    for (f.params, 0..) |*prm, i| if (prm.is_vararg) {
        vararg_at = i;
    };
    // A vararg parameter adapts unless the slot expects the array itself.
    const vararg_adapts = blk: {
        const vi = vararg_at orelse break :blk false;
        const types = b.pending_ref_lambda_param_types orelse break :blk n != f.params.len;
        if (vi >= types.len) break :blk true;
        break :blk !isArrayHead(simpleTypeHead(types[vi].name));
    };
    if (n == f.params.len and !unit and !vararg_adapts) return null;
    if (n > f.params.len and vararg_at == null) return null;
    const ma = b.module.func_name_index.allocator;
    const params = try ma.alloc(ast.Ident, n);
    const args = try ma.alloc(ast.Expr, n);
    for (0..n) |i| {
        const pn = try std.fmt.allocPrint(ma, "$ref$p{d}", .{i});
        params[i] = .{ .name = pn, .span = sp };
        const segs_i = try ma.alloc(ast.Ident, 1);
        segs_i[0] = .{ .name = pn, .span = sp };
        args[i] = .{ .Path = .{ .segments = segs_i, .span = sp } };
    }
    const anames = try ma.alloc(?[]const u8, n);
    for (anames) |*a| a.* = null;
    const segs = try ma.alloc(ast.Ident, 1);
    segs[0] = .{ .name = try ma.dupe(u8, name), .span = sp };
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = sp } };
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = anames,
        .type_args = &.{},
        .is_infix = false,
        .span = sp,
    } } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = .{ .Lambda = .{
        .params = params,
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    const heads: []const u8 = blk: {
        const types = b.pending_ref_lambda_param_types orelse break :blk "";
        var buf: std.ArrayList(u8) = .empty;
        for (types, 0..) |*t, i| {
            if (i > 0) try buf.append(ma, '|');
            try buf.appendSlice(ma, simpleTypeHead(t.name));
        }
        break :blk try buf.toOwnedSlice(ma);
    };
    b.module.pending_ref_key = try std.fmt.allocPrint(ma, "{s}|{d}|{s}|{s}", .{ f.fqn, n, heads, if (unit) "unit" else "value" });
    return try lowerExpr(b, boxed);
}

pub fn reifiedRefClosure(b: *FuncBuilder, name: []const u8, sp: ast.Span) Allocator.Error!?Reg {
    const expected = b.peekExpected() orelse return null;
    const fnty = expected.function orelse return null;
    if (fnty.params.len != 0) return null;
    if (fnty.ret.type_args.len != 1) return null;
    const fid = b.module.funcId(name) orelse return null;
    const tps = b.module.registry.func_type_params.get(fid) orelse return null;
    if (tps.items.len != 1) return null;
    const ma = b.module.func_name_index.allocator;
    const segs = try ma.alloc(ast.Ident, 1);
    segs[0] = .{ .name = try ma.dupe(u8, name), .span = sp };
    const callee = try ma.create(ast.Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = sp } };
    const ta = try ma.alloc(ast.TypeRef, 1);
    ta[0] = fnty.ret.type_args[0].ty;
    const stmts = try ma.alloc(ast.Stmt, 1);
    stmts[0] = .{ .Expr = .{ .Call = .{
        .callee = callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = ta,
        .is_infix = false,
        .span = sp,
    } } };
    const lam: ast.Expr = .{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = stmts, .span = sp },
        .span = sp,
        .implicit_it = false,
    } };
    const boxed = try ma.create(ast.Expr);
    boxed.* = lam;
    return try lowerExpr(b, boxed);
}
