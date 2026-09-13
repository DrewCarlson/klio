//! Expected-type solving for sibling arguments and reified parameters.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const inline_state = @import("../inline_state.zig");
const inline_call = @import("../inline_call.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const FuncId = ir.FuncId;
const exprSpan = helpers.exprSpan;

const expr_mod = @import("../expr.zig");

const receiver_mod = @import("receiver.zig");
const receiverHeadServes = receiver_mod.receiverHeadServes;

const binary_mod = @import("binary.zig");
const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;

const paths_mod = @import("paths.zig");
const scopeTypeRename = paths_mod.scopeTypeRename;

const lambda_mod = @import("lambda.zig");
const expectedReturnTypeArgsFor = lambda_mod.expectedReturnTypeArgsFor;

const local_call_mod = @import("local_call.zig");
const allUppercase = local_call_mod.allUppercase;

const static_type_mod = @import("static_type.zig");
const iterableElementTypeRef = static_type_mod.iterableElementTypeRef;
const ownedClassSelfType = static_type_mod.ownedClassSelfType;
const staticExprTypeRef = static_type_mod.staticExprTypeRef;
const staticTypeClassId = static_type_mod.staticTypeClassId;

const type_probe_mod = @import("type_probe.zig");
const buildStaticArgShapes = type_probe_mod.buildStaticArgShapes;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const typeHead = probe_mod.typeHead;

const SibSolved = struct { site: *const Expr, ty: ast.TypeRef };

/// Candidate walk for the comparator-sibling solve: same-simple-name
/// functions filtered by ARITY fit and by whether the declared receiver can
/// SERVE the call's actual receiver head — first-fit by arity alone handed
/// `List<String>.minOfWith` to the CharSequence variant, whose `(Char) -> R`
/// selector poisons the element binding.
fn solveComparatorSiblingByName(
    b: *FuncBuilder,
    callee: *const Expr,
    name: []const u8,
    args: []const Expr,
) ?SibSolved {
    var actual_owned: ?ir.TypeRef = switch (callee.*) {
        .Member => |m| (staticExprTypeRef(b, m.receiver) catch null),
        else => null,
    };
    defer if (actual_owned) |*t| t.deinit(b.allocator);
    const actual_head: ?[]const u8 = blk: {
        if (actual_owned) |t| break :blk typeHead(std.mem.trimEnd(u8, t.name, "?"));
        const h = b.recvTy() orelse b.spliceRecvTy() orelse b.enclosingRecvTy() orelse break :blk null;
        break :blk typeHead(std.mem.trimEnd(u8, h, "?"));
    };
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!outerArityFits(f, args.len)) continue;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (recv_off == 1) {
            const ah = actual_head orelse continue;
            var dr = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
            if (std.mem.indexOfScalar(u8, dr, '<')) |lt| dr = dr[0..lt];
            const dh = typeHead(dr);
            if (!(std.mem.eql(u8, ah, dh) or dh.len <= 2 or
                ir.parseClassTypeParamIdentity(f.params[0].ty.name) != null or
                receiverHeadServes(b, ah, dh))) continue;
        }
        if (solveComparatorSibling(b, callee, f, recv_off, args)) |solved| return solved;
    }
    return null;
}

/// `minOfWith(compareBy { it.reversed() }) { it.take(3) }`: the outer call's
/// `R` lives only in the trailing selector's RETURN, so it solves by
/// deriving that literal's tail under the receiver-element binding — any
/// tail kind, because the result feeds one sibling argument's EXPECTED type
/// and never instantiates a type variable of the outer callee (the recorded
/// member-tail hazard). The sibling declared `Comparator<in R>` then lowers
/// with `Comparator<derived>` expected, which binds compareBy's own type
/// parameter and types its lambda.
fn solveComparatorSibling(
    b: *FuncBuilder,
    callee: *const Expr,
    f: *const ir.Func,
    recv_off: usize,
    args: []const Expr,
) ?SibSolved {
    const sib_trace = runtime.envOnce("KLIO_SIBEXP_TRACE") != null;
    if (args[args.len - 1] != .Lambda) return null;
    const lam = args[args.len - 1].Lambda;
    const stmts = lam.body.stmts;
    if (stmts.len == 0 or stmts[stmts.len - 1] != .Expr) return null;
    const pk = recv_off + args.len - 1;
    if (pk >= f.params.len) return null;
    const sel_ty = f.params[pk].ty;
    if (!std.mem.startsWith(u8, typeHead(sel_ty.name), "Function") or sel_ty.args.len < 2) {
        if (sib_trace) std.debug.print("[sibexp-bail] outer={s} sel_head={s} sel_args={d}\n", .{ f.fqn, sel_ty.name, sel_ty.args.len });
        return null;
    }
    const r_name = std.mem.trimEnd(u8, sel_ty.args[sel_ty.args.len - 1].name, "?");
    if (r_name.len == 0 or r_name.len > 2 or !std.ascii.isUpper(r_name[0])) {
        if (sib_trace) std.debug.print("[sibexp-bail] outer={s} r_name={s}\n", .{ f.fqn, r_name });
        return null;
    }
    var site: ?*const Expr = null;
    var head: []const u8 = "";
    for (args[0 .. args.len - 1], 0..) |*arg, j| {
        const pj = recv_off + j;
        if (pj >= f.params.len) continue;
        const pt = f.params[pj].ty;
        if (pt.args.len != 1) continue;
        var a0 = std.mem.trimEnd(u8, pt.args[0].name, "?");
        if (std.mem.startsWith(u8, a0, "in#")) a0 = a0[3..];
        if (std.mem.startsWith(u8, a0, "out#")) a0 = a0[4..];
        if (!std.mem.eql(u8, a0, r_name)) continue;
        if (arg.* != .Call) continue;
        site = arg;
        head = typeHead(std.mem.trimEnd(u8, pt.name, "?"));
        break;
    }
    const s = site orelse {
        if (sib_trace) {
            std.debug.print("[sibexp-bail] outer={s} no_sibling_site r={s}\n", .{ f.fqn, r_name });
            for (args[0 .. args.len - 1], 0..) |*arg, j| {
                const pj = recv_off + j;
                if (pj >= f.params.len) continue;
                const pt = f.params[pj].ty;
                std.debug.print("[sibexp-bail]   arg{d} tag={s} p_name={s} p_args={d} p_arg0={s}\n", .{
                    j,
                    @tagName(arg.*),
                    pt.name,
                    pt.args.len,
                    if (pt.args.len != 0) pt.args[0].name else "-",
                });
            }
        }
        return null;
    };
    if (head.len == 0 or head.len <= 2) return null;
    const inputs = sel_ty.args[0 .. sel_ty.args.len - 1];
    var nb = FuncBuilder.init(b.allocator, b.module) catch return null;
    nb.census_quiet = true;
    defer nb.deinit();
    var elem_owned: ?ir.TypeRef = null;
    defer if (elem_owned) |*t| t.deinit(b.allocator);
    var i: usize = 0;
    while (i < inputs.len) : (i += 1) {
        const pname = if (lam.params.len == 0 and inputs.len == 1)
            "it"
        else if (i < lam.params.len)
            lam.params[i].name
        else
            return null;
        const declared = inputs[i];
        const dh = typeHead(std.mem.trimEnd(u8, declared.name, "?"));
        if (staticTypeClassId(b, declared) != null or isPrimitiveTypeName(dh)) {
            nb.setLocalDeclTypeOwned(pname, declared.clone(b.allocator) catch return null) catch return null;
        } else if (dh.len <= 2 or ir.parseClassTypeParamIdentity(declared.name) != null) {
            if (inputs.len != 1) return null;
            if (elem_owned == null) {
                elem_owned = switch (callee.*) {
                    .Member => |m| iterableElementTypeRef(b, m.receiver) catch null,
                    else => blk: {
                        const this_expr: Expr = .{ .This = .{ .qualifier = null, .span = exprSpan(s) } };
                        break :blk iterableElementTypeRef(b, &this_expr) catch null;
                    },
                };
            }
            const elem = elem_owned orelse return null;
            nb.setLocalDeclTypeOwned(pname, elem.clone(b.allocator) catch return null) catch return null;
        } else return null;
    }
    expr_mod.od_depth += 1;
    const derived = staticExprTypeRef(&nb, &stmts[stmts.len - 1].Expr) catch null;
    expr_mod.od_depth -= 1;
    var derived_ty = derived orelse {
        if (sib_trace) std.debug.print("[sibexp-bail] outer={s} derive=null\n", .{f.fqn});
        return null;
    };
    defer derived_ty.deinit(b.allocator);
    const derived_head = typeHead(std.mem.trimEnd(u8, derived_ty.name, "?"));
    if (derived_head.len <= 2) return null;
    if (staticTypeClassId(b, derived_ty) == null and !isPrimitiveTypeName(derived_head)) {
        if (sib_trace) std.debug.print("[sibexp-bail] outer={s} derived_no_class={s}\n", .{ f.fqn, derived_head });
        return null;
    }
    const sp = exprSpan(s);
    const head_owned = b.allocator.dupe(u8, head) catch return null;
    const derived_owned = b.allocator.dupe(u8, derived_head) catch return null;
    const ta = b.allocator.alloc(ast.TypeArg, 1) catch return null;
    ta[0] = .{
        .variance = .Invariant,
        .is_star = false,
        .ty = .{ .name = .{ .name = derived_owned, .span = sp }, .nullable = false, .span = sp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .span = sp,
    };
    if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) {
        std.debug.print("[sibexp] outer={s} head={s} derived={s}\n", .{ f.fqn, head_owned, derived_owned });
    }
    return .{ .site = s, .ty = .{ .name = .{ .name = head_owned, .span = sp }, .nullable = false, .span = sp, .type_args = ta, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null } };
}

/// Whether every head in `ty` (through its arguments) names something the
/// receiving scope can resolve — no bare type parameters, no class-param
/// identity mangles. Variance prefixes are spelling, not structure.
fn irTypeFullyConcrete(b: *const FuncBuilder, ty: ir.TypeRef) bool {
    var h = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.startsWith(u8, h, "in#")) h = h[3..];
    if (std.mem.startsWith(u8, h, "out#")) h = h[4..];
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
    const head = typeHead(h);
    if (head.len == 0) return false;
    if ((head.len <= 2 and std.ascii.isUpper(head[0])) or b.isTypeParam(head) or
        ir.parseClassTypeParamIdentity(head) != null) return false;
    for (ty.args) |a| {
        if (!irTypeFullyConcrete(b, a)) return false;
    }
    return true;
}

/// A lowered type as source-shaped AST, for the expected-type stack.
/// Variance mangles strip; a trailing-`?` spelling folds into `nullable`.
pub fn astTypeRefFromIr(b: *FuncBuilder, ty: ir.TypeRef, sp: ast.Span) ?ast.TypeRef {
    var nm = std.mem.trimEnd(u8, ty.name, "?");
    const spelled_nullable = nm.len != ty.name.len;
    if (std.mem.startsWith(u8, nm, "in#")) nm = nm[3..];
    if (std.mem.startsWith(u8, nm, "out#")) nm = nm[4..];
    if (std.mem.indexOfScalar(u8, nm, '<')) |lt| nm = nm[0..lt];
    if (nm.len == 0) return null;
    const owned = b.allocator.dupe(u8, nm) catch return null;
    const tas = b.allocator.alloc(ast.TypeArg, ty.args.len) catch return null;
    for (ty.args, tas) |a, *out| {
        // A star projection is a projection, not a type named `*`: it
        // binds nothing (`DeserializationStrategy<*>` as an expected type
        // must not solve a reified `T := *`).
        if (std.mem.eql(u8, std.mem.trimEnd(u8, a.name, "?"), "*")) {
            out.* = .{ .variance = .Invariant, .is_star = true, .ty = .{
                .name = .{ .name = "*", .span = sp },
                .nullable = false,
                .span = sp,
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            }, .span = sp };
            continue;
        }
        const inner = astTypeRefFromIr(b, a, sp) orelse return null;
        out.* = .{ .variance = .Invariant, .is_star = false, .ty = inner, .span = sp };
    }
    return .{
        .name = .{ .name = owned, .span = sp },
        .nullable = ty.nullable or spelled_nullable,
        .span = sp,
        .type_args = tas,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

/// The general arm: a committed-shape callee's RECEIVER (plus the call
/// site's own expected type) instantiates a call-shaped argument's declared
/// parameter type, which becomes that argument's expected type —
/// `it.sortedWith(nullsFirst(...))` on a `List<String?>` hands `nullsFirst`
/// `Comparator<in String?>`; `nullsFirst`'s own lowering then repeats the
/// same solve one level down for `compareByDescending`. Only a fully
/// concrete instantiation is pushed: a partial one disproves more than it
/// types.
/// Whether `ty` (its head or any type argument, recursively) names one of
/// `names`, or carries a star projection — the shape an unbound type
/// variable is substituted to.
fn irTypeMentionsAny(ty: ir.TypeRef, names: []const []const u8) bool {
    const head = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.eql(u8, head, "*")) return true;
    for (names) |n| if (std.mem.eql(u8, head, n)) return true;
    for (ty.args) |a| if (irTypeMentionsAny(a, names)) return true;
    return false;
}

fn solveInstantiatedArgExpected(
    b: *FuncBuilder,
    callee: *const Expr,
    name: []const u8,
    args: []const Expr,
) ?SibSolved {
    var site: ?*const Expr = null;
    var arg_idx: usize = 0;
    for (args, 0..) |*a, i| {
        if (a.* == .Call) {
            site = a;
            arg_idx = i;
            break;
        }
    }
    const s = site orelse return null;
    const sib_why = if (runtime.envOnce("KLIO_SIBEXP_WHY")) |w| std.mem.eql(u8, w, name) else false;
    var actual_owned: ?ir.TypeRef = switch (callee.*) {
        .Member => |m| (staticExprTypeRef(b, m.receiver) catch null),
        else => null,
    };
    defer if (actual_owned) |*t| t.deinit(b.allocator);
    if (callee.* == .Member and actual_owned == null) {
        if (sib_why) std.debug.print("[sibexp-why] {s} bail=recv_untyped\n", .{name});
        return null;
    }
    const actual_head: ?[]const u8 = blk: {
        if (actual_owned) |t| break :blk typeHead(std.mem.trimEnd(u8, t.name, "?"));
        break :blk null;
    };
    var scratch = std.heap.ArenaAllocator.init(b.allocator);
    defer scratch.deinit();
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!outerArityFits(f, args.len)) continue;
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (recv_off == 1) {
            const ah = actual_head orelse continue;
            var dr = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
            if (std.mem.indexOfScalar(u8, dr, '<')) |lt| dr = dr[0..lt];
            const dh = typeHead(dr);
            if (!(std.mem.eql(u8, ah, dh) or dh.len <= 2 or
                ir.parseClassTypeParamIdentity(f.params[0].ty.name) != null or
                receiverHeadServes(b, ah, dh))) continue;
        } else if (callee.* == .Member) continue;
        const pi = recv_off + arg_idx;
        if (pi >= f.params.len) continue;
        const pt = f.params[pi].ty;
        // Only a GENERIC class type is worth pushing, and only when it is
        // not already concrete (a concrete param adds no information).
        if (pt.args.len == 0 or irTypeFullyConcrete(b, pt)) {
            if (sib_why) std.debug.print("[sibexp-why] {s}#{d} skip=param_shape pt={s} args={d}\n", .{ f.fqn, fid.int(), pt.name, pt.args.len });
            continue;
        }
        const expected_explicit: ?[]ir.TypeRef = expectedReturnTypeArgsFor(b, f) catch null;
        defer if (expected_explicit) |ea| {
            for (ea) |*t| t.deinit(b.allocator);
            b.allocator.free(ea);
        };
        // Project the actual receiver onto the DECLARED head first, so a
        // List<String?> binds an Iterable<T> receiver pattern (the same
        // head-consistency rule the splice window applies).
        var solve_recv: ?ir.TypeRef = if (actual_owned) |t| t else null;
        if (recv_off == 1 and actual_owned != null) {
            if (staticTypeClassId(b, f.params[0].ty)) |dcid| {
                if (b.module.projectTypeToClass(scratch.allocator(), actual_owned.?, dcid) catch null) |p| {
                    solve_recv = p;
                    if (sib_why) std.debug.print("[sibexp-why] {s}#{d} projected={s} args={d}\n", .{ f.fqn, fid.int(), p.name, p.args.len });
                } else if (sib_why) {
                    std.debug.print("[sibexp-why] {s}#{d} project_failed actual={s} dh={s}\n", .{ f.fqn, fid.int(), actual_owned.?.name, f.params[0].ty.name });
                }
            } else if (sib_why) {
                std.debug.print("[sibexp-why] {s}#{d} no_decl_cid dh={s}\n", .{ f.fqn, fid.int(), f.params[0].ty.name });
            }
        }
        // Receiver + expected-type evidence only: the value arguments are
        // exactly the still-untyped nested calls this push exists to type,
        // and their head-only shapes would refuse the bind.
        const solved = (b.module.solveCallBindings(
            scratch.allocator(),
            fid,
            f,
            solve_recv,
            null,
            &.{},
            expected_explicit orelse &.{},
            false,
        ) catch continue) orelse {
            if (sib_why) std.debug.print("[sibexp-why] {s}#{d} skip=no_solve\n", .{ f.fqn, fid.int() });
            continue;
        };
        if (solved.bindings.len == 0) {
            if (sib_why) std.debug.print("[sibexp-why] {s}#{d} skip=no_bindings\n", .{ f.fqn, fid.int() });
            continue;
        }
        const substituted = ir.Module.substituteBoundType(scratch.allocator(), pt, solved.bindings) catch continue;
        if (!irTypeFullyConcrete(b, substituted)) {
            if (sib_why) std.debug.print("[sibexp-why] {s}#{d} skip=not_concrete sub={s}\n", .{ f.fqn, fid.int(), substituted.name });
            continue;
        }
        // The outer's OWN type parameters are not type parameters of the
        // caller's scope, so the concreteness check reads a still-unbound
        // `T` as a concrete class named `T`. Pushing `KSerializer<T>` would
        // bind the nested reified call to the literal `T`; yield to the
        // sibling solvers, which take `T` from the argument that shares it.
        if (b.module.registry.func_type_params.get(fid)) |own_tps| {
            if (irTypeMentionsAny(substituted, own_tps.items)) {
                if (sib_why) std.debug.print("[sibexp-why] {s}#{d} skip=own_type_param sub={s}\n", .{ f.fqn, fid.int(), substituted.name });
                continue;
            }
        }
        const converted = astTypeRefFromIr(b, substituted, exprSpan(s)) orelse continue;
        if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) {
            std.debug.print("[sibexp-inst] outer={s} arg={d} pushed={s} args={d}\n", .{ f.fqn, arg_idx, converted.name.name, converted.type_args.len });
        }
        return .{ .site = s, .ty = converted };
    }
    return null;
}

/// The INSTANTIATED static type of a sibling generic call (`mapOf(1 to 2)`
/// is a `Map<Int, Int>`): the call's own type parameters solve from its
/// arguments' static shapes and substitute into its declared return type.
/// The head-only static type (`Map`) would hand a reified consumer beside
/// it (`serializer<T>()`) a raw classifier.
fn instantiatedSiblingCallTypeRef(b: *FuncBuilder, e: *const Expr) ?*const ast.TypeRef {
    const inst = instantiatedCallIrType(b, e, 0) orelse return null;
    const converted = astTypeRefFromIr(b, inst, exprSpan(e)) orelse return null;
    const out = b.allocator.create(ast.TypeRef) catch return null;
    out.* = converted;
    if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) std.debug.print("[sibexp-zero-inst] -> {s} args={d}\n", .{ converted.name.name, converted.type_args.len });
    return out;
}

/// The instantiated return type of a generic call, solved from its receiver
/// and argument shapes: a bare call (`mapOf(1 to 2)`) or a receiver call,
/// infix included (`1 to 2` is `Pair<Int, Int>`). Arguments that are
/// themselves calls instantiate the same way, two levels deep.
fn instantiatedCallIrType(b: *FuncBuilder, e: *const Expr, depth: usize) ?ir.TypeRef {
    if (depth > 2 or e.* != .Call) return null;
    const call = e.Call;
    if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) std.debug.print("[sibexp-zero-enter] depth={d} callee={s} nargs={d} type_args={d}\n", .{ depth, @tagName(std.meta.activeTag(call.callee.*)), call.args.len, call.type_args.len });
    if (call.type_args.len != 0) return null;
    const name: []const u8 = switch (call.callee.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
        .Member => |m| m.name.name,
        else => return null,
    };
    const receiver: ?*const Expr = if (call.callee.* == .Member) call.callee.Member.receiver else null;
    var scratch = std.heap.ArenaAllocator.init(b.allocator);
    defer scratch.deinit();
    const shapes = buildStaticArgShapes(b, call.args, call.arg_names) catch return null;
    defer b.allocator.free(shapes);
    // An argument that is itself a call (`1 to 2`) carries no declared
    // type; its instantiated (else derived) static type is the evidence.
    for (call.args, shapes) |*a, *shape| {
        if (a.* == .Call) {
            // A nested generic call's instantiation (`Pair("a", "b")` is a
            // `Pair<String, String>`) beats the head-only declared type.
            if (instantiatedCallIrType(b, a, depth + 1)) |inst| {
                shape.ty = inst;
                shape.ty_authoritative = true;
                continue;
            }
        }
        if (shape.ty != null) continue;
        shape.ty = (staticExprTypeRef(b, a) catch null) orelse valueClassCtorTypeRef(b, a);
        shape.ty_authoritative = shape.ty != null;
    }
    const recv_ty: ?ir.TypeRef = if (receiver) |r|
        (instantiatedCallIrType(b, r, depth + 1) orelse (staticExprTypeRef(b, r) catch null))
    else
        null;
    if (receiver != null and recv_ty == null) return null;
    if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) {
        for (shapes, 0..) |sh, i| std.debug.print("[sibexp-zero-shape] call={s} arg{d} ty={s} recv={s}\n", .{ name, i, if (sh.ty) |t| t.name else "<null>", if (recv_ty) |t| t.name else "-" });
    }
    // A bare name that constructs a generic class (`Pair(42, Pair("a", "b"))`)
    // instantiates the class's own parameters from its primary parameters.
    if (receiver == null) ctor: {
        const file = call.callee.Path.segments[0].span.file;
        const scoped: ?ir.ClassId = if (scopeTypeRename(b, name, file.int())) |rn| b.module.classId(rn) else null;
        const cid = scoped orelse b.module.classIdIndexed(name, b.self_package, file) orelse
            b.module.classId(name) orelse break :ctor;
        if (cid.int() >= b.module.classes.items.len) break :ctor;
        const cls = &b.module.classes.items[cid.int()];
        if (cls.type_params.len == 0 or cls.primary_params.len != call.args.len) break :ctor;
        if (b.module.funcsBySimpleName(name).len != 0) break :ctor;
        var bindings: std.ArrayList(ir.Module.TypeBinding) = .empty;
        for (cls.primary_params, shapes) |pp, sh| {
            const at = sh.ty orelse continue;
            positionalBind(scratch.allocator(), pp.ty, at, cls.type_params, &bindings) catch break :ctor;
        }
        if (bindings.items.len != cls.type_params.len) break :ctor;
        const out_args = scratch.allocator().alloc(ir.TypeRef, cls.type_params.len) catch break :ctor;
        for (cls.type_params, 0..) |tp, i| {
            out_args[i] = for (bindings.items) |bd| {
                if (std.mem.eql(u8, bd.name, tp)) break bd.ty;
            } else break :ctor;
        }
        const inst = ir.TypeRef{ .name = cls.fqn, .nullable = false, .args = out_args };
        if (!irTypeFullyConcrete(b, inst)) break :ctor;
        return inst.clone(b.allocator) catch null;
    }
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        const ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (ext != (receiver != null)) continue;
        const value_params = if (ext) f.params.len - 1 else f.params.len;
        const has_va = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
        if (!(value_params == call.args.len or (has_va and call.args.len + 1 >= value_params))) continue;
        if (f.return_ty.args.len == 0) continue;
        const tps = b.module.registry.func_type_params.get(fid) orelse continue;
        if (tps.items.len == 0) continue;
        // A vararg run of DIFFERENT classes (`listOf(ResponseInt(10), NoResponse,
        // ResponseString("foo"))`) binds the element parameter to their least
        // upper bound (the sealed `I`), as kotlinc infers it.
        if (has_va and value_params == 1 and tps.items.len == 1 and shapes.len > 1) {
            if (leastUpperBoundHead(b, shapes)) |lub| {
                for (shapes) |*sh| sh.ty = .{ .name = lub, .nullable = false, .args = &.{} };
            }
        }
        const solved = (b.module.solveCallBindings(scratch.allocator(), fid, f, recv_ty, null, shapes, &.{}, false) catch continue) orelse continue;
        if (solved.bindings.len == 0) continue;
        const substituted = ir.Module.substituteBoundType(scratch.allocator(), f.return_ty, solved.bindings) catch continue;
        if (!irTypeFullyConcrete(b, substituted)) continue;
        if (irTypeMentionsAny(substituted, tps.items)) continue;
        return substituted.clone(b.allocator) catch null;
    }
    return null;
}

/// Bind the class type parameters a declared parameter type mentions from
/// the argument's static type, positionally (`second: B` against
/// `Pair<String, String>` binds `B`; `items: List<T>` against `List<Int>`
/// binds `T`). A parameter already bound to a different type is a conflict.
fn positionalBind(a: Allocator, param: ir.TypeRef, arg: ir.TypeRef, tps: []const []const u8, out: *std.ArrayList(ir.Module.TypeBinding)) !void {
    const pn = std.mem.trimEnd(u8, param.name, "?");
    for (tps) |tp| {
        if (!std.mem.eql(u8, pn, tp)) continue;
        for (out.items) |bd| {
            if (std.mem.eql(u8, bd.name, tp)) {
                if (!std.mem.eql(u8, bd.ty.name, arg.name)) return error.Conflict;
                return;
            }
        }
        var owned = try arg.clone(a);
        owned.nullable = false;
        try out.append(a, .{ .name = tp, .ty = owned });
        return;
    }
    if (param.args.len != 0 and param.args.len == arg.args.len) {
        for (param.args, arg.args) |pa, aa| try positionalBind(a, pa, aa, tps, out);
    }
}

/// The nearest class every argument shape's static head is or extends,
/// walking the first head's supertype chain outward; null when the heads
/// agree (nothing to widen) or when no common class short of `Any` exists.
fn leastUpperBoundHead(b: *FuncBuilder, shapes: []const applicability.ArgShape) ?[]const u8 {
    var heads_buf: [16][]const u8 = undefined;
    if (shapes.len > heads_buf.len) return null;
    var all_same = true;
    for (shapes, 0..) |sh, i| {
        const t = sh.ty orelse return null;
        heads_buf[i] = typeHead(std.mem.trimEnd(u8, t.name, "?"));
        if (i != 0 and !std.mem.eql(u8, heads_buf[i], heads_buf[0])) all_same = false;
    }
    if (all_same) return null;
    const heads = heads_buf[0..shapes.len];
    var queue_buf: [64]ir.ClassId = undefined;
    var qlen: usize = 0;
    var qhead: usize = 0;
    const first = b.module.classIdByFqn(heads[0]) orelse b.module.classId(heads[0]) orelse return null;
    queue_buf[qlen] = first;
    qlen += 1;
    while (qhead < qlen) : (qhead += 1) {
        const cid = queue_buf[qhead];
        if (cid.int() >= b.module.classes.items.len) continue;
        const cls = &b.module.classes.items[cid.int()];
        var all = true;
        for (heads[1..]) |h| {
            if (!(std.mem.eql(u8, h, cls.name) or std.mem.eql(u8, h, cls.fqn) or b.module.classIsOrExtends(h, cls.fqn) or b.module.classIsOrExtends(h, cls.name))) {
                all = false;
                break;
            }
        }
        if (all) return cls.fqn;
        for (cls.supertypes) |sup| {
            if (qlen < queue_buf.len) {
                queue_buf[qlen] = sup;
                qlen += 1;
            }
        }
    }
    return null;
}

/// Whether an outer candidate can take `nargs` written arguments: its
/// receiver slot does not count (`JsonTestBase.assertJsonFormAndRestored`
/// called bare inside a subclass), and missing trailing parameters must
/// carry defaults (`json: Json = default`).
fn outerArityFits(f: *const ir.Func, nargs: usize) bool {
    const ro: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const vp = f.params.len - ro;
    if (vp == nargs) return true;
    if (vp < nargs) return false;
    if (vp - nargs <= 1) return true;
    var i: usize = ro + nargs;
    while (i < f.params.len) : (i += 1) {
        if (!f.params[i].has_default) return false;
    }
    return true;
}

/// The class a VALUE-class constructor call names (`Child1(Child1Value(1, "one"))`),
/// resolved in scope: `ctorInitTypeRef` declines value classes, yet an
/// element or argument typed by one still has that class as its static type
/// (a sealed-interface `List<Parent>` of inline children).
pub fn valueClassCtorTypeRef(b: *FuncBuilder, e: *const Expr) ?ir.TypeRef {
    if (e.* != .Call) return null;
    const call = e.Call;
    if (call.callee.* != .Path or call.callee.Path.segments.len != 1) return null;
    const seg = call.callee.Path.segments[0];
    if (seg.name.len == 0 or !std.ascii.isUpper(seg.name[0])) return null;
    const scoped: ?ir.ClassId = if (scopeTypeRename(b, seg.name, seg.span.file.int())) |rn| b.module.classId(rn) else null;
    const cid = scoped orelse b.module.classIdIndexed(seg.name, b.self_package, seg.span.file) orelse b.module.classId(seg.name) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[cid.int()];
    if (!cls.is_value or cls.type_params.len != 0) return null;
    return .{ .name = b.allocator.dupe(u8, cls.fqn) catch return null, .nullable = false, .args = &.{} };
}

/// Kotlin types an integer literal by its EXPECTED type: `1` under a `Long`
/// parameter is a `Long`, and the expectation flows through a generic
/// factory (`mapOf("a" to 1)` under `Map<String, Long>` makes the `1` a
/// `Long` via `mapOf`'s `V` and `to`'s `B`). The literal node's kind is
/// rewritten in place before lowering; nothing else changes.
pub fn applyExpectedLiteralKinds(b: *FuncBuilder, e: *ast.Expr, expected: ir.TypeRef) void {
    const head = typeHead(std.mem.trimEnd(u8, expected.name, "?"));
    switch (e.*) {
        .IntLit => |*lit| {
            if (lit.kind == .Int and std.mem.eql(u8, head, "Long")) lit.kind = .Long;
        },
        .Unary => |*u| applyExpectedLiteralKinds(b, u.expr, expected),
        .Call => |*c| applyExpectedToGenericCall(b, c, expected),
        else => {},
    }
}

fn applyExpectedToGenericCall(b: *FuncBuilder, c: anytype, expected: ir.TypeRef) void {
    if (c.type_args.len != 0) return;
    if (expected.args.len == 0) return;
    const name: []const u8 = switch (c.callee.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return,
        .Member => |m| m.name.name,
        else => return,
    };
    // An infix call (`"a" to 1`) parses as `to(lhs, rhs)`: the first
    // argument is the extension receiver.
    const infix = c.is_infix and c.callee.* == .Path and c.args.len == 2;
    const receiver: ?*ast.Expr = if (c.callee.* == .Member) c.callee.Member.receiver else if (infix) &c.args[0] else null;
    const value_args: []ast.Expr = if (infix) c.args[1..] else c.args;
    var scratch = std.heap.ArenaAllocator.init(b.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    // A generic class constructor (`Pair(1, 2)` under `Pair<Long, Long>`).
    if (receiver == null) ctor: {
        const cid = b.module.classIdIndexed(name, b.self_package, c.callee.Path.segments[0].span.file) orelse
            b.module.classId(name) orelse break :ctor;
        if (cid.int() >= b.module.classes.items.len) break :ctor;
        const cls = &b.module.classes.items[cid.int()];
        if (cls.type_params.len == 0 or cls.type_params.len != expected.args.len) break :ctor;
        if (b.module.funcsBySimpleName(name).len != 0) break :ctor;
        var bindings: std.ArrayList(ir.Module.TypeBinding) = .empty;
        for (cls.type_params, expected.args) |tp, ea| {
            bindings.append(a, .{ .name = tp, .ty = ea }) catch return;
        }
        for (cls.primary_params, 0..) |pp, i| {
            if (i >= c.args.len) break;
            const sub = ir.Module.substituteBoundType(a, pp.ty, bindings.items) catch continue;
            applyExpectedLiteralKinds(b, &c.args[i], sub);
        }
        return;
    }
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        const ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (ext != (receiver != null)) continue;
        const ro: usize = if (ext) 1 else 0;
        const value_params = f.params.len - ro;
        const has_va = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
        if (!(value_params == value_args.len or (has_va and value_args.len + 1 >= value_params))) continue;
        const tps = b.module.registry.func_type_params.get(fid) orelse continue;
        if (tps.items.len == 0) continue;
        var bindings: std.ArrayList(ir.Module.TypeBinding) = .empty;
        positionalBind(a, f.return_ty, expected, tps.items, &bindings) catch continue;
        if (bindings.items.len == 0) continue;
        if (receiver) |r| {
            const sub = ir.Module.substituteBoundType(a, f.params[0].ty, bindings.items) catch continue;
            applyExpectedLiteralKinds(b, r, sub);
        }
        for (value_args, 0..) |*arg, i| {
            const pi = ro + i;
            const pt: ir.TypeRef = if (pi < f.params.len)
                (if (f.params[pi].is_vararg) applicability.varargElementRef(&f.params[pi].ty) else f.params[pi].ty)
            else if (has_va)
                applicability.varargElementRef(&f.params[f.params.len - 1].ty)
            else
                continue;
            const sub = ir.Module.substituteBoundType(a, pt, bindings.items) catch continue;
            applyExpectedLiteralKinds(b, arg, sub);
        }
        return;
    }
}

/// Rewrite integer literals in a call's arguments by the callee's declared
/// parameter types (the expectation Kotlin applies), skipping parameters
/// that still mention the callee's own type parameters.
pub fn applyExpectedLiteralKindsToArgs(b: *FuncBuilder, f: *const ir.Func, args: []const Expr, ast_arg_names: []const ?[]const u8, recv_off: usize) void {
    for (ast_arg_names) |n| {
        if (n != null) return;
    }
    const own_tps: []const []const u8 = if (b.module.registry.func_type_params.get(f.id)) |l| l.items else &.{};
    for (args, 0..) |*arg, i| {
        const pi = recv_off + i;
        if (pi >= f.params.len) return;
        const p = f.params[pi];
        if (p.is_vararg) return;
        if (irTypeMentionsAny(p.ty, own_tps) or bareTypeParamHead(p.ty.name)) continue;
        applyExpectedLiteralKinds(b, @constCast(arg), p.ty);
    }
}

/// The constructor counterpart of `applyExpectedLiteralKindsToArgs`: the
/// class's primary parameter types are the expectation
/// (`WithValueKeyMap(mapOf(k to 1))` under `map: Map<K, Long>`).
pub fn applyExpectedLiteralKindsToCtorArgs(b: *FuncBuilder, class_id: ir.ClassId, args: []const Expr, ast_arg_names: []const ?[]const u8) void {
    for (ast_arg_names) |n| {
        if (n != null) return;
    }
    if (class_id.int() >= b.module.classes.items.len) return;
    const cls = &b.module.classes.items[class_id.int()];
    for (args, 0..) |*arg, i| {
        if (i >= cls.primary_params.len) return;
        const p = cls.primary_params[i];
        if (p.is_vararg) return;
        if (irTypeMentionsAny(p.ty, cls.type_params) or bareTypeParamHead(p.ty.name)) continue;
        applyExpectedLiteralKinds(b, @constCast(arg), p.ty);
    }
}

pub fn solveSiblingExpected(b: *FuncBuilder, callee: *const Expr, args: []const Expr) ?SibSolved {
    if (args.len == 0) return null;
    const outer_name: []const u8 = switch (callee.*) {
        .Path => |p| blk: {
            if (p.segments.len != 1) return null;
            break :blk p.segments[0].name;
        },
        .Member => |m| m.name.name,
        else => return null,
    };
    // A bare call naming a member of the lexically enclosing class (an
    // inherited `assertJsonFormAndRestored(serializer(), value, …)`) is not
    // in the simple-name index (only member extensions are): read the
    // enclosing chain's method slots, as the reified solver does.
    const own_member_outer = callee.* != .Member and b.hasEnclosingMember(outer_name);
    var chain_buf: [32]FuncId = undefined;
    const cand_fids: []const FuncId = if (own_member_outer)
        enclosingChainMethodsNamed(b, outer_name, callee.Path.segments[0].span.file, &chain_buf) catch &.{}
    else
        b.module.funcsBySimpleName(outer_name);
    var outer: ?*const ir.Func = null;
    for (cand_fids) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (outerArityFits(f, args.len)) {
            outer = f;
            break;
        }
    }
    if (args.len >= 2) {
        if (solveComparatorSiblingByName(b, callee, outer_name, args)) |solved| return solved;
    }
    if (solveInstantiatedArgExpected(b, callee, outer_name, args)) |solved| return solved;
    if (solveReifiedArgExpected(b, callee, outer_name, args)) |solved| return solved;
    if (callee.* == .Member) return null;
    if (args.len < 2) return null;
    const f = outer orelse return null;
    const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    for (args, 0..) |*arg, j| {
        if (arg.* != .Call) continue;
        const c = arg.Call;
        if (c.type_args.len != 0) continue;
        const nested_name: []const u8 = switch (c.callee.*) {
            .Path => |p| if (p.segments.len == 1) p.segments[0].name else continue,
            .Member => |m| m.name.name,
            else => continue,
        };
        // The outer overload judged here is the one whose parameter at this
        // slot is a bare type variable: `assertEquals` also declares the
        // `(Double, Double, tolerance)` forms, and the first arity match
        // may be one of those.
        var f_sel: *const ir.Func = f;
        var pj = recv_off + j;
        var tv_sel: []const u8 = "";
        {
            var found = false;
            for (cand_fids) |fid2| {
                const f2 = b.module.funcById(fid2) orelse continue;
                if (!outerArityFits(f2, args.len)) continue;
                const ro2: usize = if (f2.params.len != 0 and std.mem.eql(u8, f2.params[0].name, "this")) 1 else 0;
                const pj2 = ro2 + j;
                if (pj2 >= f2.params.len) continue;
                const slot2 = f2.params[pj2].ty;
                var tv2 = slot2.name;
                // A slot `C<T>` (`KSerializer<T>`) whose single argument is a
                // bare type variable shares that variable with the sibling's
                // plain `T` slot: the variable is the argument.
                if (!(tv2.len <= 2 and allUppercase(tv2)) and slot2.args.len == 1) {
                    const a0 = std.mem.trimEnd(u8, slot2.args[0].name, "?");
                    if (a0.len != 0 and a0.len <= 2 and allUppercase(a0)) tv2 = a0;
                }
                if (tv2.len > 2 or !allUppercase(tv2)) continue;
                f_sel = f2;
                pj = pj2;
                tv_sel = tv2;
                found = true;
                break;
            }
            if (!found) continue;
        }
        const tv = tv_sel;
        const ro_sel: usize = if (f_sel.params.len != 0 and std.mem.eql(u8, f_sel.params[0].name, "this")) 1 else 0;
        // A nested reified-inline call with arguments (`assertEquals(
        // Holder(1), decodeFromString(text))`) takes the sibling's static
        // type (a constructor call, a typed local, a literal) as its
        // expected type: the reified parameter binds from it where the
        // call's own arguments say nothing.
        if (c.args.len != 0) {
            var reified = false;
            if (inline_state.candidatesForName(nested_name)) |cands| {
                for (cands) |cf| {
                    for (cf.type_params) |*tp| {
                        if (tp.is_reified) reified = true;
                    }
                }
            }
            if (!reified) {
                if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) std.debug.print("[sibexp-why] nested `{s}` not reified-inline\n", .{nested_name});
                continue;
            }
            for (args, 0..) |*sib, k| {
                if (k == j) continue;
                const pk = ro_sel + k;
                if (pk >= f_sel.params.len) continue;
                if (!std.mem.eql(u8, f_sel.params[pk].ty.name, tv)) continue;
                const st = inline_call.ctorArgTypeRef(b.allocator, sib, b) orelse
                    inline_call.staticArgTypeRef(b.allocator, sib, b) orelse {
                    if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) std.debug.print("[sibexp-why] sibling #{d} of `{s}` has no static type (tag={s})\n", .{ k, outer_name, @tagName(std.meta.activeTag(sib.*)) });
                    continue;
                };
                return .{ .site = arg, .ty = st.* };
            }
            continue;
        }
        if (c.callee.* != .Path) continue;
        // The nested ZERO-argument reified overload — `serializer<T>()`
        // beside `serializer(type: KType)` and `KClass<T>.serializer()` —
        // is the receiver-less one with no value parameters and a single
        // type parameter; the simple-name index alone may answer another.
        var nested_pick: ?FuncId = null;
        for (b.module.funcsBySimpleName(nested_name)) |nfid| {
            const nf = b.module.funcById(nfid) orelse continue;
            if (nf.params.len != 0) continue;
            const ntps = b.module.registry.func_type_params.get(nfid) orelse continue;
            if (ntps.items.len != 1) continue;
            nested_pick = nfid;
            break;
        }
        const nested_fid = nested_pick orelse continue;
        const nested_f = b.module.funcById(nested_fid) orelse continue;
        // The lowered ir return type keeps only the head (`EnumEntries`);
        // the splice unifies against the AST declaration's full
        // `Head<T>`, so the head is all the expected type needs here.
        if (nested_f.return_ty.name.len == 0) continue;
        for (args, 0..) |*sib, k| {
            if (k == j) continue;
            const pk = ro_sel + k;
            if (pk >= f_sel.params.len) continue;
            // The sibling slot names `T` directly (`data: T`) or carries it as a
            // type argument (`pair: Pair<K, V>` for a `vSer: KSerializer<V>`),
            // in which case the sibling's instantiated type projects to it.
            const proj: ?usize = blk_proj: {
                if (std.mem.eql(u8, f_sel.params[pk].ty.name, tv)) break :blk_proj null;
                for (f_sel.params[pk].ty.args, 0..) |pa, pi| {
                    if (std.mem.eql(u8, std.mem.trimEnd(u8, pa.name, "?"), tv)) break :blk_proj pi;
                }
                continue;
            };
            const sp = c.callee.Path.segments[0].span;
            // The sibling's static type: an enum-entries expression, else a
            // constructor call / typed value (`check(serializer(), Holder(x), …)`
            // solves `serializer<T>()` from `Holder(x)` at the `data: T` slot).
            const sib_ty_full: ast.TypeRef = blk: {
                if (staticEnumElem(b, sib)) |enum_name| {
                    break :blk .{ .name = .{ .name = enum_name, .span = sp }, .nullable = false, .span = sp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null };
                }
                const st = instantiatedSiblingCallTypeRef(b, sib) orelse
                    inline_call.ctorArgTypeRef(b.allocator, sib, b) orelse
                    inline_call.staticArgTypeRef(b.allocator, sib, b) orelse {
                    if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) std.debug.print("[sibexp-why] zero-arg nested `{s}`: sibling #{d} of `{s}` has no static type (tag={s})\n", .{ nested_name, k, outer_name, @tagName(sib.*) });
                    continue;
                };
                if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null) std.debug.print("[sibexp-zero] outer={s} nested={s} sibling#{d} -> {s}\n", .{ outer_name, nested_name, k, st.name.name });
                break :blk st.*;
            };
            const sib_ty: ast.TypeRef = if (proj) |pi| blk_p: {
                if (pi >= sib_ty_full.type_args.len or sib_ty_full.type_args[pi].is_star) continue;
                break :blk_p sib_ty_full.type_args[pi].ty;
            } else sib_ty_full;
            // Build `Head<Sibling>` as the nested call's expected type; the
            // inline splice's return-type unification (the existing
            // reified oracle) solves T from it.
            var head = nested_f.return_ty.name;
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |i| head = head[i + 1 ..];
            const ta = b.allocator.alloc(ast.TypeArg, 1) catch return null;
            ta[0] = .{ .variance = .Invariant, .is_star = false, .ty = sib_ty, .span = sp };
            return .{ .site = arg, .ty = .{ .name = .{ .name = head, .span = sp }, .nullable = false, .span = sp, .type_args = ta, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null } };
        }
    }
    return null;
}

/// A nested reified-inline call argument (`JsonTreeDecoder(json,
/// cast(currentObject(), descriptor), ...)`) takes the callee's DECLARED
/// parameter type as its expected type: Kotlin infers the reified `T`
/// from the expected type there, and the splice's return-type unification
/// binds it the same way. Only a concrete head-only parameter type that
/// every arity-matching overload agrees on is pushed.
/// The method slots named `name` on the lexically enclosing class and its
/// supertypes (declaration order, nearest class first), for a bare call
/// that reaches them through the implicit `this` receiver.
pub fn enclosingChainMethodsNamed(b: *FuncBuilder, name: []const u8, file: ir.FileId, buf: []FuncId) Allocator.Error![]const FuncId {
    const owner = b.ownerClass() orelse build.currentOwnerClass() orelse return buf[0..0];
    const root = b.module.classIdIndexed(owner, b.self_package, file) orelse b.module.classId(owner) orelse return buf[0..0];
    var out_len: usize = 0;
    // The class row's method slots fill after its bodies lower; while a
    // body is lowering, the registered member resolution (the same
    // authority the private-member call route uses) names the member.
    {
        var owner_type = try ownedClassSelfType(b.allocator, &b.module.classes.items[root.int()]);
        defer owner_type.deinit(b.allocator);
        const owned_bounds = try b.typeParamBoundsSlice();
        defer if (owned_bounds) |bounds| b.allocator.free(bounds);
        var probe_n: usize = 0;
        while (probe_n <= 8) : (probe_n += 1) {
            const shapes = try b.allocator.alloc(applicability.ArgShape, probe_n);
            defer b.allocator.free(shapes);
            for (shapes) |*sh| sh.* = .{};
            const res = b.module.resolveMemberCall(root, name, shapes, .{
                .caller_file = file,
                .lexical_owner = root,
                .actual_type_param_bounds = owned_bounds orelse &.{},
                .receiver_type = owner_type,
            });
            const fid = res.target orelse continue;
            var dup = false;
            for (buf[0..out_len]) |x| {
                if (x == fid) dup = true;
            }
            if (dup) continue;
            if (out_len == buf.len) return buf[0..out_len];
            buf[out_len] = fid;
            out_len += 1;
        }
    }
    var stack: [64]ir.ClassId = undefined;
    var seen: [64]ir.ClassId = undefined;
    var seen_len: usize = 0;
    var sp: usize = 0;
    stack[sp] = root;
    sp += 1;
    while (sp != 0) {
        sp -= 1;
        const cid = stack[sp];
        var dup = false;
        for (seen[0..seen_len]) |s| {
            if (s == cid) dup = true;
        }
        if (dup) continue;
        if (seen_len == seen.len) break;
        seen[seen_len] = cid;
        seen_len += 1;
        if (cid.int() >= b.module.classes.items.len) continue;
        const cls = &b.module.classes.items[cid.int()];
        for (cls.methods) |m| {
            const f = b.module.funcById(m) orelse continue;
            if (!std.mem.eql(u8, f.name, name)) continue;
            if (out_len == buf.len) return buf[0..out_len];
            buf[out_len] = m;
            out_len += 1;
        }
        var i = cls.supertypes.len;
        while (i > 0) : (i -= 1) {
            if (sp == stack.len) break;
            stack[sp] = cls.supertypes[i - 1];
            sp += 1;
        }
    }
    return buf[0..out_len];
}

/// `fid` is declared by the lexically enclosing class or one of its
/// supertypes, so a bare call inside that class can reach it through the
/// implicit `this` receiver.
fn funcInEnclosingChain(b: *FuncBuilder, fid: FuncId, file: ir.FileId) bool {
    const owner = b.ownerClass() orelse build.currentOwnerClass() orelse return false;
    const root = b.module.classIdIndexed(owner, b.self_package, file) orelse b.module.classId(owner) orelse return false;
    var stack: [64]ir.ClassId = undefined;
    var seen: [64]ir.ClassId = undefined;
    var seen_len: usize = 0;
    var sp: usize = 0;
    stack[sp] = root;
    sp += 1;
    while (sp != 0) {
        sp -= 1;
        const cid = stack[sp];
        var dup = false;
        for (seen[0..seen_len]) |s| {
            if (s == cid) dup = true;
        }
        if (dup) continue;
        if (seen_len == seen.len) return false;
        seen[seen_len] = cid;
        seen_len += 1;
        if (cid.int() >= b.module.classes.items.len) continue;
        const cls = &b.module.classes.items[cid.int()];
        for (cls.methods) |m| {
            if (m == fid) return true;
        }
        for (cls.supertypes) |st| {
            if (sp == stack.len) return false;
            stack[sp] = st;
            sp += 1;
        }
    }
    return false;
}

fn solveReifiedArgExpected(b: *FuncBuilder, callee: *const Expr, name: []const u8, args: []const Expr) ?SibSolved {
    for (args, 0..) |*a, i| {
        if (a.* != .Call) continue;
        const c = a.Call;
        if (c.type_args.len != 0) continue;
        var sp: ast.Span = undefined;
        const nested_name: []const u8 = switch (c.callee.*) {
            .Path => |p| blk: {
                if (p.segments.len != 1) continue;
                sp = p.segments[0].span;
                break :blk p.segments[0].name;
            },
            .Member => |m| blk: {
                sp = m.name.span;
                break :blk m.name.name;
            },
            else => continue,
        };
        const cands = inline_state.candidatesForName(nested_name) orelse continue;
        var reified = false;
        for (cands) |cf| {
            for (cf.type_params) |*tp| {
                if (tp.is_reified) reified = true;
            }
        }
        if (!reified) continue;
        var agreed: ?ir.TypeRef = null;
        var conflict = false;
        // A bare call naming a member of the lexically enclosing class
        // resolves to that member (an implicit `this` receiver wins over a
        // top-level namesake), so only the enclosing chain's members
        // supply the parameter type.
        const own_member = callee.* != .Member and b.hasEnclosingMember(name);
        const sib_tr = runtime.envOnce("KLIO_SIBEXP_TRACE") != null;
        if (sib_tr) std.debug.print("[sibexp-reified] outer={s} nested={s} own_member={} owner={?s} cur={?s}\n", .{ name, nested_name, own_member, b.ownerClass(), build.currentOwnerClass() });
        // Plain member functions are not in the simple-name index (only
        // member extensions are); an own-member call reads the enclosing
        // chain's method slots instead.
        var chain_buf: [32]FuncId = undefined;
        const cand_fids: []const FuncId = if (own_member)
            enclosingChainMethodsNamed(b, name, sp.file, &chain_buf) catch &.{}
        else
            b.module.funcsBySimpleName(name);
        for (cand_fids) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            if (sib_tr) std.debug.print("[sibexp-reified]   cand {s} recv_off={d} nparams={d}\n", .{ f.fqn, recv_off, f.params.len });
            if (own_member) {
                if (recv_off != 1) continue;
            } else if (callee.* != .Member and recv_off == 1) continue;
            if (f.params.len - recv_off < args.len) continue;
            const pi = recv_off + i;
            if (pi >= f.params.len) continue;
            const pt = f.params[pi].ty;
            const head = std.mem.trimEnd(u8, pt.name, "?");
            if (head.len == 0 or pt.args.len != 0) {
                conflict = true;
                break;
            }
            if (std.mem.eql(u8, head, "Any") or std.mem.startsWith(u8, head, "Function") or !irTypeFullyConcrete(b, pt)) {
                conflict = true;
                break;
            }
            if (agreed) |g| {
                if (!std.mem.eql(u8, std.mem.trimEnd(u8, g.name, "?"), head)) {
                    conflict = true;
                    break;
                }
            } else agreed = pt;
        }
        if (conflict) continue;
        // A constructor call: the class's primary parameters.
        if (agreed == null and callee.* != .Member) {
            if (b.module.classId(name)) |cid| {
                const cls = &b.module.classes.items[cid.int()];
                if (i < cls.primary_params.len and cls.primary_params.len >= args.len) {
                    const pt = cls.primary_params[i].ty;
                    const head = std.mem.trimEnd(u8, pt.name, "?");
                    if (head.len != 0 and pt.args.len == 0 and !std.mem.eql(u8, head, "Any") and
                        !std.mem.startsWith(u8, head, "Function") and irTypeFullyConcrete(b, pt)) agreed = pt;
                }
            }
        }
        const pt = agreed orelse continue;
        const ty = astTypeRefFromIr(b, pt, sp) orelse continue;
        return .{ .site = a, .ty = ty };
    }
    return null;
}

/// The enum class statically named by an expression's element type:
/// `E.entries` and `E.values().toList()` both yield `E` when `E` resolves
/// to a registered enum class.
fn staticEnumElem(b: *FuncBuilder, e: *const Expr) ?[]const u8 {
    switch (e.*) {
        .Member => |m| {
            if (std.mem.eql(u8, m.name.name, "entries")) return enumClassOfPath(b, m.receiver);
            return null;
        },
        .Call => |c| {
            if (c.callee.* != .Member) return null;
            const outer_m = c.callee.Member;
            if (!std.mem.eql(u8, outer_m.name.name, "toList")) return null;
            if (outer_m.receiver.* != .Call) return null;
            const inner = outer_m.receiver.Call;
            if (inner.callee.* != .Member) return null;
            const vm = inner.callee.Member;
            if (!std.mem.eql(u8, vm.name.name, "values")) return null;
            return enumClassOfPath(b, vm.receiver);
        },
        else => return null,
    }
}

pub fn enumClassOfPath(b: *FuncBuilder, e: *const Expr) ?[]const u8 {
    var name: []const u8 = undefined;
    var qual_cid: ?ir.ClassId = null;
    var owner_hint: ?[]const u8 = null;
    switch (e.*) {
        .Path => |p| {
            name = p.segments[p.segments.len - 1].name;
            // A qualified nested reference (`EnumEntriesListTest.EmptyEnum`)
            // must bind THAT nested class — the simple name may collide
            // with an unrelated top-level or sibling-nested enum.
            if (p.segments.len >= 2) {
                const owner_name = p.segments[p.segments.len - 2].name;
                owner_hint = owner_name;
                if (b.module.classId(owner_name)) |oid| {
                    qual_cid = b.module.classIdNestedIn(oid, name);
                }
            }
        },
        .Member => |m| {
            name = m.name.name;
            if (m.receiver.* == .Path and m.receiver.Path.segments.len >= 1) {
                const owner_name = m.receiver.Path.segments[m.receiver.Path.segments.len - 1].name;
                owner_hint = owner_name;
                if (b.module.classId(owner_name)) |oid| {
                    qual_cid = b.module.classIdNestedIn(oid, name);
                }
            } else if (m.receiver.* == .Member) {
                owner_hint = m.receiver.Member.name.name;
            }
        },
        else => return null,
    }
    if (qual_cid) |cid| {
        if (cid.int() < b.module.classes.items.len) {
            // The registered (lifted) name is what the runtime type-arg
            // lookup resolves — already unique, so no owner qualification
            // on top (a mangled `EnumEntriesListTest$EmptyEnum` must not
            // stamp as `EnumEntriesListTest.EnumEntriesListTest$EmptyEnum`).
            name = b.module.classes.items[cid.int()].name;
            if (std.mem.indexOfScalar(u8, name, '$') != null) owner_hint = null;
        }
    }
    // A nested-enum reference whose class lifted under a mangled name
    // resolves through the rename: a QUALIFIED reference through its
    // owner's alias table (`EnumEntriesListTest.EmptyEnum` ->
    // `EnumEntriesListTest$EmptyEnum`), a bare one through the lexical
    // scope-rename ladder (`EmptyEnum` -> `EnumEntriesFactoryTest$EmptyEnum`).
    if (b.module.classId(name) == null) {
        if (owner_hint) |o| {
            if (b.module.registry.nested_object_aliases.get(o)) |m| {
                if (m.get(name)) |rn| {
                    name = rn;
                    owner_hint = null;
                }
            }
        } else if (scopeTypeRename(b, name, e.span().file.int())) |rn| {
            name = rn;
        }
    }
    if (b.module.classId(name) == null) return null;
    // Enum-ness at lowering: the recorded supertype chain carries
    // `Enum` for every enum class (the implicit supertype is recorded at
    // class lowering).
    const chain = b.module.registry.class_super_names.get(name) orelse return null;
    for (chain) |sup| {
        var sn = sup;
        if (std.mem.lastIndexOfScalar(u8, sn, '.')) |i| sn = sn[i + 1 ..];
        if (std.mem.indexOfScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
        if (!std.mem.eql(u8, sn, "Enum")) continue;
        // A qualified reference stamps the owner-qualified name: the
        // simple name may collide with an unrelated same-named enum, and
        // the runtime resolves the dotted form through the lifted
        // nested-class key.
        if (owner_hint) |o| {
            return std.fmt.allocPrint(b.module.func_name_index.allocator, "{s}.{s}", .{ o, name }) catch name;
        }
        return name;
    }
    return null;
}

/// Static type args synthesized from the enclosing splice's reified
/// substitution: when the call site wrote none and every declared
/// type-parameter name of `func_id` is bound in the active reified name
/// map, the substituted names stamp the call (`enumEntriesIntrinsic()`
/// inside a spliced `enumEntries<E>()` body gets `<E>` — the runtime
/// typed dispatch is blind otherwise). Null when not fully bound.
pub fn spliceReifiedTypeArgs(b: *FuncBuilder, func_id: FuncId, argc: usize) Allocator.Error!?[]ConstId {
    if (b.reified_type_names.count() == 0) return null;
    const tps = b.module.registry.func_type_params.get(func_id) orelse return null;
    if (tps.items.len == 0) return null;
    const out = try b.allocator.alloc(ConstId, tps.items.len);
    for (tps.items, out) |tp, *slot| {
        const actual = b.resolveReifiedTypeName(tp) orelse blk: {
            // The callee names its type parameter differently from the
            // enclosing splice's. Kotlin solves it from the expected type;
            // with NO arguments to solve from and exactly one reified type
            // in scope, that binding is the only candidate there is —
            // `EnumSerializer(serialName, enumValues())` inside
            // `inline fun <reified E : Enum<E>> EnumSerializer(...)`.
            if (argc != 0 or tps.items.len != 1 or b.reified_type_names.count() != 1) {
                b.allocator.free(out);
                return null;
            }
            var it = b.reified_type_names.valueIterator();
            break :blk (it.next() orelse {
                b.allocator.free(out);
                return null;
            }).*;
        };
        slot.* = try b.module.internConst(b.allocator, .{ .String = actual });
    }
    return out;
}
