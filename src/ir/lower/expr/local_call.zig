//! Local function and local extension overload selection, and the value
//! invocation tail.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const lambda_body = @import("../lambda_body.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const TypeRef = ir.TypeRef;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const resolveCapture = lambda_body.resolveCapture;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const receiver_mod = @import("receiver.zig");
const lowerReceiver = receiver_mod.lowerReceiver;

const control_mod = @import("control.zig");
const localOverloadPick = control_mod.localOverloadPick;

const call_mod = @import("call.zig");
const packContiguous = call_mod.packContiguous;
const plainFnParamRejectsTrailingLambda = call_mod.plainFnParamRejectsTrailingLambda;
const resolveThisForBareCallNoBind = call_mod.resolveThisForBareCallNoBind;

const arg_shape_mod = @import("arg_shape.zig");
const argLitKind = arg_shape_mod.argLitKind;
const callInitNonInvocable = arg_shape_mod.callInitNonInvocable;
const ctorInitNonInvocable = arg_shape_mod.ctorInitNonInvocable;
const initTypeNonInvocable = arg_shape_mod.initTypeNonInvocable;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;

const probe_mod = @import("probe.zig");
const anyReceiverClassDeclares = probe_mod.anyReceiverClassDeclares;
const inReceiverContext = probe_mod.inReceiverContext;

const audit_mod = @import("audit.zig");
const orEmitAudit = audit_mod.orEmitAudit;

const member_call_mod = @import("member_call.zig");
const localOverloadReceiverCouldApply = member_call_mod.localOverloadReceiverCouldApply;

/// The definitely-known static type head of an argument expression, for
/// local-fn overload selection: literals, lambdas, and locals with a
/// declared type annotation. Null = unknown (never disproves).
fn staticArgHead(b: *const FuncBuilder, e: *const Expr) ?[]const u8 {
    return switch (e.*) {
        .BoolLit => "Boolean",
        .StringTemplate => "String",
        .CharLit => "Char",
        .IntLit => "Int",
        .FloatLit => "Double",
        .Lambda => "->",
        .Path => |p| blk: {
            if (p.segments.len != 1) break :blk null;
            break :blk b.localDeclType(p.segments[0].name);
        },
        // A zero-argument stdlib CONVERSION has a statically known result
        // type, and it is often the only evidence a bare call has. Without it
        // `writeULEB128(data.size.toUInt())` inside kotlinx-io's local
        // `Buffer.writeULEB128(data: UIntArray)` had no argument head, the
        // type disproof below was skipped, the local was judged applicable on
        // arity alone, and the call recursed into itself.
        .Call => |c| blk: {
            if (c.args.len != 0 or c.callee.* != .Member) break :blk null;
            break :blk conversionResultHead(c.callee.Member.name.name);
        },
        else => null,
    };
}

/// The result head of a stdlib collection factory (`listOf`, `mapOf`, ...), or
/// null for any other name. Deliberately a fixed list, like
/// `conversionResultHead`: these names fix their own result head.
pub fn factoryResultHead(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { m: []const u8, t: []const u8 }{
        .{ .m = "listOf", .t = "List" },
        .{ .m = "listOfNotNull", .t = "List" },
        .{ .m = "emptyList", .t = "List" },
        .{ .m = "mutableListOf", .t = "MutableList" },
        .{ .m = "arrayListOf", .t = "ArrayList" },
        .{ .m = "setOf", .t = "Set" },
        .{ .m = "setOfNotNull", .t = "Set" },
        .{ .m = "emptySet", .t = "Set" },
        .{ .m = "mutableSetOf", .t = "MutableSet" },
        .{ .m = "hashSetOf", .t = "HashSet" },
        .{ .m = "linkedSetOf", .t = "LinkedHashSet" },
        .{ .m = "mapOf", .t = "Map" },
        .{ .m = "emptyMap", .t = "Map" },
        .{ .m = "mutableMapOf", .t = "MutableMap" },
        .{ .m = "hashMapOf", .t = "HashMap" },
        .{ .m = "linkedMapOf", .t = "LinkedHashMap" },
        .{ .m = "sequenceOf", .t = "Sequence" },
        .{ .m = "emptySequence", .t = "Sequence" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p.m)) return p.t;
    }
    return null;
}

/// The result type of a zero-argument stdlib conversion (`toUInt`, `toLong`,
/// ...), or null for any other name. Deliberately a fixed list: these are
/// canonical stdlib conversions whose result type is fixed by their name.
fn conversionResultHead(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { m: []const u8, t: []const u8 }{
        .{ .m = "toInt", .t = "Int" },       .{ .m = "toLong", .t = "Long" },
        .{ .m = "toShort", .t = "Short" },   .{ .m = "toByte", .t = "Byte" },
        .{ .m = "toFloat", .t = "Float" },   .{ .m = "toDouble", .t = "Double" },
        .{ .m = "toUInt", .t = "UInt" },     .{ .m = "toULong", .t = "ULong" },
        .{ .m = "toUShort", .t = "UShort" }, .{ .m = "toUByte", .t = "UByte" },
        .{ .m = "toChar", .t = "Char" },     .{ .m = "toBoolean", .t = "Boolean" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p.m)) return p.t;
    }
    return null;
}

pub fn allUppercase(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return s.len != 0;
}

const numeric_heads = [_][]const u8{
    "Int",  "Long",  "Short",  "Byte",  "Double", "Float",
    "UInt", "ULong", "UShort", "UByte", "Number",
};

fn headIsNumeric(h: []const u8) bool {
    for (numeric_heads) |n| {
        if (std.mem.eql(u8, h, n)) return true;
    }
    return false;
}

/// A builtin scalar head — the only heads that definitely disprove one
/// another (and that a lambda literal can never satisfy).
fn headIsScalar(h: []const u8) bool {
    if (headIsNumeric(h)) return true;
    const scalars = [_][]const u8{ "Boolean", "String", "Char" };
    for (scalars) |s| {
        if (std.mem.eql(u8, h, s)) return true;
    }
    return false;
}

/// Whether declared head `d` denotes a function type. A parsed function
/// type carries the synthetic tag `"<function>"` (see `ast.TypeRef`); a
/// spelled-out `(P) -> R` or an erased `FunctionN` name also count.
fn headIsFunctionType(d: []const u8) bool {
    return std.mem.eql(u8, d, "<function>") or
        std.mem.indexOf(u8, d, "->") != null or
        std.mem.startsWith(u8, d, "Function");
}

/// Can an argument with static head `h` bind a parameter declared `d`?
/// Disproof-only: `true` unless both sides are known and definitely
/// incompatible (numeric literals coerce across the numeric family).
///
/// `strict` tightens the lambda case for OVERLOAD SELECTION: a `{ … }`
/// argument matches only a function-typed parameter, so a `(…) -> R`
/// sibling wins over a same-arity non-function one. When `false` (the
/// applicability / shadow-or-fall-through decision) the lambda case is
/// disproof-only: reject only a definite non-function scalar, since an
/// unknown class name may be a function typealias.
/// Builtin container heads: final array/collection types that no scalar can
/// ever be an instance of.
fn headIsContainer(h: []const u8) bool {
    const heads = [_][]const u8{
        "Array",       "IntArray",   "LongArray",  "ShortArray",  "ByteArray",
        "FloatArray",  "DoubleArray", "CharArray", "BooleanArray",
        "UIntArray",   "ULongArray", "UShortArray", "UByteArray",
        "List",        "MutableList", "Set",       "MutableSet",
        "Map",         "MutableMap", "Collection", "MutableCollection",
        "Iterable",    "Sequence",
    };
    for (heads) |x| {
        if (std.mem.eql(u8, h, x)) return true;
    }
    return false;
}

pub fn headCompatible(h: []const u8, d_raw: []const u8, strict: bool) bool {
    const d = std.mem.trimEnd(u8, d_raw, "?");
    if (std.mem.eql(u8, d, "Any") or std.mem.eql(u8, d, "Unit")) return true;
    if (d.len > 0 and d.len <= 2 and allUppercase(d)) return true;
    const d_fn = headIsFunctionType(d);
    if (std.mem.eql(u8, h, "->")) {
        if (d_fn) return true;
        return if (strict) false else !headIsScalar(d);
    }
    if (d_fn) return false;
    if (std.mem.eql(u8, h, d)) return true;
    if (headIsNumeric(h) and headIsNumeric(d)) return true;
    // A scalar argument can never satisfy an ARRAY or COLLECTION parameter.
    // These are final builtin containers with no scalar subtype, so unlike a
    // plain class name (which could be a supertype of the argument) they
    // disprove outright. kotlinx-io's local
    // `Buffer.writeULEB128(data: UIntArray)` was judged able to take
    // `writeULEB128(data.size.toUInt())` without this, and the call recursed
    // into itself.
    if (headIsScalar(h) and headIsContainer(d)) return false;
    // The head is a definite literal kind; a differently-named declared
    // class stays unknown (could be a supertype) — only the builtin
    // scalar heads disprove each other.
    return !(headIsScalar(h) and headIsScalar(d));
}

/// Statically select among same-named local-fn declarations: arity and
/// named-argument fit, then literal/declared-type disproof per bound
/// parameter. Returns the unique survivor's mangled binding, or null
/// when no signature fact separates the candidates (the caller keeps
/// the plain last-decl binding).
/// Can any same-named local-function declaration take this call at all
/// (arity, varargs, defaults, argument names)? When none can, the local
/// name does not shadow the outer candidates.
pub fn anyLocalFnOverloadApplicable(
    b: *const FuncBuilder,
    ovs: []const build.LocalFnOverload,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!bool {
    outer: for (ovs) |*ov| {
        if (ov.is_ext) {
            // A statically known receiver type adjudicates; a scope with a
            // REACHABLE `this` but no threaded type (a nested lambda inside
            // the local ext's own body) keeps the candidate UNPROVEN — only
            // a genuinely receiver-less scope drops it.
            if (b.recvTypeRef()) |receiver| {
                if (!try localOverloadReceiverCouldApply(b, ov, receiver)) continue;
            } else if (b.resolve("this") == null and !b.knowsOuter("this") and !b.capturesThisSlot()) {
                return false;
            }
        }
        if (args.len < ov.n_required and !ov.has_vararg) continue;
        if (args.len > ov.param_tys.len and !ov.has_vararg) continue;
        var bound = [_]bool{false} ** 64;
        if (ov.param_tys.len > bound.len) continue;
        var positional: usize = 0;
        for (args, 0..) |*a, i| {
            const supplied: ?[]const u8 = if (i < ast_arg_names.len) ast_arg_names[i] else null;
            var pi: ?usize = null;
            if (supplied) |nm| {
                var found = false;
                for (ov.param_names, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, nm)) {
                        if (bound[k]) continue :outer;
                        pi = k;
                        bound[k] = true;
                        found = true;
                        break;
                    }
                }
                if (!found) continue :outer;
            } else {
                // A generated positional arg after named ones (the compose
                // pass appends the ($composer, $changed) pair positionally
                // behind named user args): skip slots the names already
                // bound, or the pair refutes against the first user param.
                while (positional < ov.param_tys.len and bound[positional]) positional += 1;
                if (positional < ov.param_tys.len) {
                    pi = positional;
                    bound[positional] = true;
                } else if (!ov.has_vararg) {
                    continue :outer;
                }
                positional += 1;
            }
            // Type-head disproof per bound parameter, mirroring
            // `selectLocalFnOverload`: a `validate { … }` (lambda arg) does not
            // fit `fun validate(state: Int)`. Without this the local name was
            // deemed applicable on arity alone and the call recursed into
            // itself instead of falling through to the outer extension.
            if (pi) |k| {
                const d = ov.param_tys[k] orelse continue;
                const h = staticArgHead(b, a) orelse continue;
                if (!headCompatible(h, d, false)) continue :outer;
            }
        }
        return true;
    }
    return false;
}

/// Whether the enclosing local fn's own overload record can take this call
/// (arity + argument names). Missing record (the table did not reach this
/// deferred body) keeps the route available — the runtime binder still
/// resolves the mangled cell's closure.
pub fn selfLocalFnApplicable(
    b: *const FuncBuilder,
    mangled: []const u8,
    bare: []const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!bool {
    const decls = b.localFnDecls(bare) orelse return true;
    for (decls) |*ov| {
        if (!std.mem.eql(u8, ov.mangled, mangled)) continue;
        return anyLocalFnOverloadApplicable(b, @as([*]const build.LocalFnOverload, @ptrCast(ov))[0..1], args, ast_arg_names);
    }
    return true;
}

/// Ext-only variant of `selectLocalFnOverload` for a RECEIVER-FULL call
/// (`this.f(args)` / `recv.f(args)`): only extension siblings can take a
/// receiver, and their applicability is judged against the receiver's
/// DECLARED type (in scope at the call), not the enclosing lambda's
/// receiver context.
pub fn selectLocalExtOverload(
    b: *const FuncBuilder,
    ovs: []const build.LocalFnOverload,
    declared_ty: ?TypeRef,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?[]const u8 {
    var survivor: ?*const build.LocalFnOverload = null;
    var n_survivors: usize = 0;
    outer: for (ovs) |*ov| {
        if (!ov.is_ext) continue;
        if (declared_ty) |actual| {
            if (!try localOverloadReceiverCouldApply(b, ov, actual)) continue;
        }
        if (args.len < ov.n_required and !ov.has_vararg) continue;
        if (args.len > ov.param_tys.len and !ov.has_vararg) continue;
        var bound = [_]bool{false} ** 64;
        if (ov.param_tys.len > bound.len) continue;
        var positional: usize = 0;
        for (args, 0..) |*a, i| {
            const supplied: ?[]const u8 = if (i < ast_arg_names.len) ast_arg_names[i] else null;
            var pi: ?usize = null;
            if (supplied) |nm| {
                for (ov.param_names, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, nm)) {
                        if (bound[k]) continue :outer;
                        pi = k;
                        bound[k] = true;
                        break;
                    }
                }
                if (pi == null) continue :outer;
            } else {
                // A generated positional arg after named ones (the compose
                // pass appends the ($composer, $changed) pair positionally
                // behind named user args): skip slots the names already
                // bound, or the pair refutes against the first user param.
                while (positional < ov.param_tys.len and bound[positional]) positional += 1;
                if (positional < ov.param_tys.len) {
                    pi = positional;
                    bound[positional] = true;
                } else if (!ov.has_vararg) {
                    continue :outer;
                }
                positional += 1;
            }
            if (pi) |k| {
                const d = ov.param_tys[k] orelse continue;
                const h = staticArgHead(b, a) orelse continue;
                if (!headCompatible(h, d, true)) continue :outer;
            }
        }
        survivor = ov;
        n_survivors += 1;
    }
    if (n_survivors == 1) return survivor.?.mangled;
    return null;
}

/// Call a selected local EXTENSION overload through its mangled cell with
/// an EXPLICIT receiver expression prepended as the leading `this` arg.
/// Null when the cell is unreachable from this scope (forward reference);
/// the caller keeps its plain-name route.
pub fn lowerSelectedLocalExtCallWithReceiver(
    b: *FuncBuilder,
    mangled: []const u8,
    receiver: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const cell: Reg = if (b.resolve(mangled)) |r|
        r
    else if (b.knowsOuter(mangled))
        try resolveCapture(b, mangled)
    else
        return null;
    const callee_reg = b.allocReg();
    try b.push(.{ .CellGet = .{ .dst = callee_reg, .cell = cell } });
    const recv = try lowerReceiver(b, receiver);
    const vals = try b.allocator.alloc(Reg, args.len + 1);
    defer b.allocator.free(vals);
    vals[0] = recv;
    for (args, 0..) |*a, i| vals[i + 1] = try lowerExpr(b, a);
    const args_start = try packContiguous(b, vals);
    // The receiver rides as slot 0: shift the arg-name list one slot right,
    // or a named call (`this.Composition(a = true, ...)`) labels the RECEIVER
    // "a" and every binding misaligns.
    const shifted: []const ?[]const u8 = blk: {
        if (ast_arg_names.len == 0) break :blk ast_arg_names;
        const sh = try b.allocator.alloc(?[]const u8, ast_arg_names.len + 1);
        sh[0] = null;
        @memcpy(sh[1..], ast_arg_names);
        break :blk sh;
    };
    const arg_names = try internArgNames(b.allocator, b.module, shifted);
    const dst = b.allocReg();
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_reg,
        .args = args_start,
        .n_args = @intCast(vals.len),
        .arg_names = arg_names,
    } });
    return dst;
}

pub fn selectLocalFnOverload(
    b: *const FuncBuilder,
    ovs: []const build.LocalFnOverload,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?[]const u8 {
    var survivor: ?*const build.LocalFnOverload = null;
    var n_survivors: usize = 0;
    var exact: ?*const build.LocalFnOverload = null;
    var n_exact: usize = 0;
    outer: for (ovs) |*ov| {
        // An EXTENSION sibling is only a candidate where a KNOWN
        // receiver type is in scope (the enclosing receiver-lambda's
        // declared receiver, carried across lambda boundaries):
        // `fun Checker.Composition()` beside a plain local
        // `fun Composition(...)` binds inside the validator's receiver
        // lambda and never from a receiver-less scope. A merely-captured
        // `this` is not enough — every lambda captures one.
        if (ov.is_ext) {
            const receiver = b.recvTypeRef() orelse continue;
            if (!try localOverloadReceiverCouldApply(b, ov, receiver)) continue;
        }
        if (args.len < ov.n_required and !ov.has_vararg) continue;
        if (args.len > ov.param_tys.len and !ov.has_vararg) continue;
        var bound = [_]bool{false} ** 64;
        if (ov.param_tys.len > bound.len) continue;
        var positional: usize = 0;
        for (args, 0..) |*a, i| {
            const supplied: ?[]const u8 = if (i < ast_arg_names.len) ast_arg_names[i] else null;
            var pi: ?usize = null;
            if (supplied) |nm| {
                for (ov.param_names, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, nm)) {
                        if (bound[k]) continue :outer;
                        pi = k;
                        bound[k] = true;
                        break;
                    }
                }
                if (pi == null) continue :outer;
            } else {
                // A generated positional arg after named ones (the compose
                // pass appends the ($composer, $changed) pair positionally
                // behind named user args): skip slots the names already
                // bound, or the pair refutes against the first user param.
                while (positional < ov.param_tys.len and bound[positional]) positional += 1;
                if (positional < ov.param_tys.len) {
                    pi = positional;
                    bound[positional] = true;
                } else if (!ov.has_vararg) {
                    continue :outer;
                }
                positional += 1;
            }
            if (pi) |k| {
                const d = ov.param_tys[k] orelse continue;
                const h = staticArgHead(b, a) orelse continue;
                if (!headCompatible(h, d, true)) continue :outer;
            }
        }
        survivor = ov;
        n_survivors += 1;
        if (args.len == ov.param_tys.len) {
            exact = ov;
            n_exact += 1;
        }
    }
    if (n_survivors == 1) return survivor.?.mangled;
    if (n_exact == 1) return exact.?.mangled;
    return null;
}

/// Emit the call to a statically selected local-fn overload through its
/// mangled cell binding — resolvable in the declaring scope or as a
/// capture. Null when this scope cannot reach the cell (a forward sibling
/// reference from a lambda captured before the sibling declared); the
/// caller falls back to the plain-name binding.
pub fn lowerSelectedLocalOverloadCall(
    b: *FuncBuilder,
    bare: []const u8,
    mangled: []const u8,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const cell: Reg = if (b.resolve(mangled)) |r|
        r
    else if (b.knowsOuter(mangled))
        try resolveCapture(b, mangled)
    else
        return null;
    const callee_reg = b.allocReg();
    try b.push(.{ .CellGet = .{ .dst = callee_reg, .cell = cell } });
    // A selected local *extension* overload takes the enclosing receiver
    // as its leading `this` param, like the plain-name ext arm.
    if (b.isLocalExtFn(mangled)) {
        // No reachable receiver: fall back to the plain-name route rather
        // than invoking the extension with its `this` slot missing.
        const this_reg = try resolveThisForBareCallNoBind(b);
        if (this_reg == null) return null;
        if (this_reg) |tr| {
            const recv = b.allocReg();
            try b.push(.{ .Move = .{ .dst = recv, .src = tr } });
            const vals = try b.allocator.alloc(Reg, args.len + 1);
            defer b.allocator.free(vals);
            vals[0] = recv;
            for (args, 0..) |*a, i| vals[i + 1] = try lowerExpr(b, a);
            const args_start = try packContiguous(b, vals);
            // The receiver rides as slot 0: shift the arg-name list one
            // slot right, or a named call (`Composition(a = ..., ...)`)
            // labels the RECEIVER "a" and every binding misaligns.
            const shifted: []const ?[]const u8 = blk: {
                if (ast_arg_names.len == 0) break :blk ast_arg_names;
                const sh = try b.allocator.alloc(?[]const u8, ast_arg_names.len + 1);
                sh[0] = null;
                @memcpy(sh[1..], ast_arg_names);
                break :blk sh;
            };
            const arg_names = try internArgNames(b.allocator, b.module, shifted);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_reg,
                .args = args_start,
                .n_args = @intCast(vals.len),
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    const lfp: ?[]const ?[]const u8 = if (allNull(ast_arg_names)) b.localFnParamTys(mangled) else null;
    const run = try lowerArgRunFull(b, args, null, lfp);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    var member_declared = b.hasEnclosingMember(bare);
    if (!member_declared) {
        if (b.ownerClass()) |oc| {
            if (b.module.registry.hierarchy_methods.get(oc)) |s| {
                member_declared = s.contains(bare);
            }
        }
    }
    if (member_declared) {
        if (try resolveThisForBareCallNoBind(b)) |this_reg| {
            const name = try b.module.internConst(b.allocator, .{ .String = bare });
            orEmitAudit(b, "cvom_unresolved_bare", "CallValueOrMember", bare);
            try b.push(.{ .CallValueOrMember = .{
                .dst = dst,
                .callee = callee_reg,
                .this_recv = this_reg,
                .name = name,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }
    try b.push(.{ .CallValue = .{
        .dst = dst,
        .callee = callee_reg,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
    } });
    return dst;
}

/// A single-name callee bound as a local / parameter / receiver-lambda-param.
pub fn lowerValueInvocation(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    const name0 = localOverloadPick(b, callee.Path.segments[0].name, args.len);

    // A bare call to a receiver-lambda param reached as a capture. The
    // declared receiver HEAD rides the instruction: the captured `this`
    // register can be a coroutine that rebound the enclosing block's slot,
    // and the VM re-selects the innermost implicit receiver of the
    // declared type (combineInternal's `transform(...)` binds
    // this@combineInternal, the FlowCollector, not the flowScope
    // coroutine).
    if (runtime.envOnce("KLIO_RLP_TRACE")) |w| {
        if (std.mem.eql(u8, w, name0))
            std.debug.print("[rlp-arm] {s} isRLP={} resolved={} outer={} head={s} in={s}\n", .{ name0, b.isReceiverLambdaParam(name0), b.resolve(name0) != null, b.knowsOuter(name0), b.receiverLambdaRecvHead(name0) orelse "-", build.currentRealFn() orelse "-" });
    }
    if (b.isReceiverLambdaParam(name0) and b.resolve(name0) == null and b.knowsOuter(name0)) {
        // The innermost implicit receiver OF THE DECLARED HEAD, resolved
        // lexically: an enclosing extension fn's receiver reaches nested
        // lambdas through its `this@<fn>` entry slot, which no coroutine
        // receiver rebinding ever displaces (the flowScope block's `this`
        // is the FlowCoroutine; `transform(...)` still binds
        // this@combineInternal, the FlowCollector).
        var head_receiver: ?Reg = null;
        if (b.receiverLambdaRecvHead(name0)) |h| {
            const tower = try b.collectReceiverTowerLabeled(b.allocator, null, null);
            defer b.allocator.free(tower);
            for (tower) |entry| {
                if (!std.mem.eql(u8, entry.head, h)) continue;
                if (entry.label) |lbl| {
                    const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{lbl});
                    if (b.resolve(label)) |r| {
                        head_receiver = r;
                    } else if (b.knowsOuter(label)) {
                        const dst2 = try b.loadCaptureHoisted(label);
                        try b.bind(label, dst2);
                        head_receiver = dst2;
                    }
                    if (runtime.envOnce("KLIO_RLP_TRACE") != null)
                        std.debug.print("[rlp-head] {s} label={s} hit={} in={s}\n", .{ name0, label, head_receiver != null, build.currentRealFn() orelse "-" });
                }
                break;
            }
        }
        const this_reg: ?Reg = head_receiver orelse if (b.knowsOuter("this") or b.capturesThisSlot())
            try resolveCapture(b, "this")
        else
            b.resolve("this");
        if (this_reg) |tr| {
            const callee_r = try resolveCapture(b, name0);
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const head_c: ?ir.ConstId = if (b.receiverLambdaRecvHead(name0)) |h|
                try b.module.internConst(b.allocator, .{ .String = h })
            else
                null;
            const dst = b.allocReg();
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_r,
                .receiver = tr,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
                .recv_head = head_c,
            } });
            return dst;
        }
    }

    // A bare call to a local *extension* function reached as a capture:
    // prepend the enclosing receiver as the closure's leading `this`
    // param, mirroring the declaring-scope arm below (`handleCall(...)`
    // inside an `on(Send) { ... }` lambda binds the Sender receiver).
    if (b.isLocalExtFn(name0) and b.resolve(name0) == null and b.knowsOuter(name0)) {
        const this_reg: ?Reg = if (b.knowsOuter("this") or b.capturesThisSlot())
            try resolveCapture(b, "this")
        else
            b.resolve("this");
        if (this_reg) |tr| {
            const callee_r = try resolveCapture(b, name0);
            const recv = b.allocReg();
            try b.push(.{ .Move = .{ .dst = recv, .src = tr } });
            const vals = try b.allocator.alloc(Reg, args.len + 1);
            defer b.allocator.free(vals);
            vals[0] = recv;
            for (args, 0..) |*a, i| vals[i + 1] = try lowerExpr(b, a);
            const args_start = try packContiguous(b, vals);
            // The receiver rides as slot 0: shift the arg-name list one slot
            // right, or a named call (`Composition(a = true, ...)`) labels
            // the RECEIVER "a" and every binding misaligns.
            const shifted: []const ?[]const u8 = blk: {
                if (ast_arg_names.len == 0) break :blk ast_arg_names;
                const sh = try b.allocator.alloc(?[]const u8, ast_arg_names.len + 1);
                sh[0] = null;
                @memcpy(sh[1..], ast_arg_names);
                break :blk sh;
            };
            const arg_names = try internArgNames(b.allocator, b.module, shifted);
            const dst = b.allocReg();
            try b.push(.{ .CallValue = .{
                .dst = dst,
                .callee = callee_r,
                .args = args_start,
                .n_args = @intCast(vals.len),
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // Member-function precedence over a same-named value/param. A local
    // fn with a same-named enclosing member also routes through the
    // arbitrated form: the value arm wins unless the closure's declared
    // params refute the args (Kotlin picks the member overload then), so
    // `testEncode(codec, byteArray, s)` reaches the private member past
    // the String-typed local.
    const redirect_to_member = blk: {
        var member_declared = b.hasEnclosingMember(name0);
        if (!member_declared) {
            if (b.ownerClass()) |oc| {
                if (b.module.registry.hierarchy_methods.get(oc)) |s| {
                    member_declared = s.contains(name0);
                }
            }
        }
        break :blk member_declared and b.resolve(name0) != null and !b.isLocalExtFn(name0);
    };
    if (redirect_to_member) {
        if (try resolveThisForBareCallNoBind(b)) |this_reg| {
            var callee_reg = b.resolve(name0).?;
            if (b.isBoxed(name0)) {
                const c = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = c, .cell = callee_reg } });
                callee_reg = c;
            }
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            orEmitAudit(b, "cvom_redirect_member", "CallValueOrMember", name0);
            try b.push(.{ .CallValueOrMember = .{
                .dst = dst,
                .callee = callee_reg,
                .this_recv = this_reg,
                .name = nm,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    if (b.resolve(name0)) |reg| {
        // A non-function-typed param does not shadow a same-named top-level
        // function for a *call*: `flow { … }` inside
        // `fun Flow<T>.combine(flow: Flow<T2>, …)` resolves to the `flow {}`
        // builder, not the `flow: Flow<T2>` parameter (a `Flow` is not
        // invokable). Defer to the bare-function path so the builder binds.
        if (b.isNonFnParam(name0) and
            b.module.hasBareCallCandidate(name0, callee.Path.segments[0].span.file))
        {
            return null;
        }
        // Nor does a LOCAL whose initializer is a definite non-callable
        // literal: `var nodeIndex = 0` beside `fun nodeIndex(slots, group)`
        // resolves the call `nodeIndex(slots, startingGroup)` to the
        // function (an Int is not invokable) — the composer's
        // movable-content insert is the shape.
        // A constructor initializer of a class with no `invoke` operator
        // (member or extension) is equally non-invokable, and the member
        // alternative counts alongside the bare-function one: inside a
        // spliced `ReentrantLock.withLock` body the bare `lock()` is the
        // receiver's member, never the caller's `val lock =
        // ReentrantLock()` local.
        if ((b.module.hasBareCallCandidate(name0, callee.Path.segments[0].span.file) or
            (inReceiverContext(b) and anyReceiverClassDeclares(b, name0))) and
            !b.isLocalFn(name0))
        {
            if (b.localInitExpr(name0)) |init_e| {
                if (argLitKind(init_e) != null) return null;
                if (ctorInitNonInvocable(b, init_e, args.len)) return null;
                if (callInitNonInvocable(b, init_e, args.len)) return null;
                if (try initTypeNonInvocable(b, init_e, args.len)) return null;
            } else if (b.knowsOuter(name0) and b.spliceRecvTy() != null and
                anyReceiverClassDeclares(b, name0))
            {
                // A CAPTURE-reached local has no recorded initializer to
                // disprove invocability, but the spliced receiver's class
                // declares the name: the same `lock()`-in-withLock rule
                // applies (the body's bare call is the receiver's member),
                // so defer to the arbitrated/member path.
                return null;
            }
        }
        // Nor does a function-typed param shadow one for a TRAILING-LAMBDA
        // call it cannot accept. The lambda binds the callee's last parameter,
        // so a param whose own last parameter is not a function type is not
        // this call's target: inside
        // `Flow<T>.map(crossinline transform: suspend (T) -> R)` the body's
        // `transform { value -> … }` is the `Flow.transform` OPERATOR, and only
        // the inner `transform(value)` is the parameter. Binding the parameter
        // there passed the operator's own lambda in as the emitted value, so
        // `map`'s caller saw a closure where its element belonged.
        if (plainFnParamRejectsTrailingLambda(b, name0, args)) {
            return null;
        }
        var callee_reg = reg;
        if (b.isBoxed(name0)) {
            const c = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = c, .cell = reg } });
            callee_reg = c;
        }
        // A bare call to a receiver-typed function param. With explicit
        // positional args the FIRST one is the receiver (`f: T.() -> R`
        // called `f(x)` means `x.f()`); with none, the enclosing `this`.
        if (b.isReceiverLambdaParam(name0) and args.len >= 1 and
            ast_arg_names.len >= 1 and ast_arg_names[0] == null and blk: {
            const ar = b.receiverLambdaArity(name0) orelse break :blk false;
            break :blk args.len == ar + 1;
        }) {
            const recv_r = try lowerExpr(b, &args[0]);
            const run = try lowerArgRun(b, args[1..]);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names[1..]);
            const dst = b.allocReg();
            try b.push(.{ .CallValueWithThis = .{
                .dst = dst,
                .callee = callee_reg,
                .receiver = recv_r,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
        if (b.isReceiverLambdaParam(name0)) {
            const this_reg = try resolveThisForBareCallNoBind(b);
            if (this_reg) |tr| {
                const run = try lowerArgRun(b, args);
                const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
                // The declared receiver HEAD rides the instruction: inside a
                // spliced/nested receiver block the syntactic `this` can be
                // the block's own receiver (flowScope's coroutine), while
                // Kotlin binds the innermost implicit receiver of the
                // DECLARED type (`transform(...)` for a
                // `FlowCollector.(Array) -> Unit` param binds
                // this@combineInternal).
                const head_c: ?ir.ConstId = if (b.receiverLambdaRecvHead(name0)) |h|
                    try b.module.internConst(b.allocator, .{ .String = h })
                else
                    null;
                const dst = b.allocReg();
                try b.push(.{ .CallValueWithThis = .{
                    .dst = dst,
                    .callee = callee_reg,
                    .receiver = tr,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                    .recv_head = head_c,
                } });
                return dst;
            }
        }
        // A bare call to a *local extension* function.
        if (b.isLocalExtFn(name0)) {
            const this_reg = try resolveThisForBareCallNoBind(b);
            if (this_reg) |tr| {
                const recv = b.allocReg();
                try b.push(.{ .Move = .{ .dst = recv, .src = tr } });
                const vals = try b.allocator.alloc(Reg, args.len + 1);
                defer b.allocator.free(vals);
                vals[0] = recv;
                for (args, 0..) |*a, i| vals[i + 1] = try lowerExpr(b, a);
                const args_start = try packContiguous(b, vals);
                // The receiver rides as slot 0: shift the arg-name list one
                // slot right, or a named call (`Composition(a = true, ...)`)
                // labels the RECEIVER "a" and every binding misaligns.
                const shifted: []const ?[]const u8 = blk: {
                    if (ast_arg_names.len == 0) break :blk ast_arg_names;
                    const sh = try b.allocator.alloc(?[]const u8, ast_arg_names.len + 1);
                    sh[0] = null;
                    @memcpy(sh[1..], ast_arg_names);
                    break :blk sh;
                };
                const arg_names = try internArgNames(b.allocator, b.module, shifted);
                const dst = b.allocReg();
                try b.push(.{ .CallValue = .{
                    .dst = dst,
                    .callee = callee_reg,
                    .args = args_start,
                    .n_args = @intCast(vals.len),
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
        const lfp: ?[]const ?[]const u8 = if (allNull(ast_arg_names)) b.localFnParamTys(name0) else null;
        const run = try lowerArgRunFull(b, args, null, lfp);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        try b.push(.{ .CallValue = .{
            .dst = dst,
            .callee = callee_reg,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        return dst;
    }
    return null;
}
