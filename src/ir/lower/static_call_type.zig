//! Static call return-type derivation: the on-demand answer to what type a call
//! expression has. The ladder walks the bare, FQN, member and local-function arms
//! in turn, refusing where the evidence is ambiguous. The answers feed overload
//! selection, receiver typing and local-init typing; nothing here emits code.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");
const applicability = @import("applicability");
const build = @import("../build.zig");

const expr = @import("expr.zig");
const helpers = @import("helpers.zig");
const ast_scan = @import("ast_scan.zig");
const inline_state = @import("inline_state.zig");
const decl_mod = @import("decl.zig");

const Allocator = std.mem.Allocator;

const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Func = ir.Func;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;

const exprSpan = helpers.exprSpan;
const collectDottedFqn = ast_scan.collectDottedFqn;

const allNull = expr.allNull;
const argDeclTypeRefLazy = expr.argDeclTypeRefLazy;
const bareStaticRecvHead = expr.bareStaticRecvHead;
const bareTypeParamHead = expr.bareTypeParamHead;
const buildStaticReturnArgShapes = expr.buildStaticReturnArgShapes;
const ctorInitTypeRef = expr.ctorInitTypeRef;
const eagerLambdaRecvHead = expr.eagerLambdaRecvHead;
const enclosingHasMemberNamed = expr.enclosingHasMemberNamed;
const isPrimitiveTypeName = expr.isPrimitiveTypeName;
const lastArgIsLambda = expr.lastArgIsLambda;
const loweredOwnedLocalTypeRef = expr.loweredOwnedLocalTypeRef;
const loweredTypeName = expr.loweredTypeName;
const overloadPickByCast = expr.overloadPickByCast;
const overloadPickByLambdaReturn = expr.overloadPickByLambdaReturn;
const overloadPickByLambdaReturnFull = expr.overloadPickByLambdaReturnFull;
const receiverHeadServes = expr.receiverHeadServes;
const resolveCtxFor = expr.resolveCtxFor;
const rsplitLast = expr.rsplitLast;
const staticDispatchReceiverTypeRef = expr.staticDispatchReceiverTypeRef;
const staticExprTypeRef = expr.staticExprTypeRef;
const staticTypeClassId = expr.staticTypeClassId;
const typeHead = expr.typeHead;

/// Whether the caller's body has the target's owner type parameters in lexical
/// scope, true only inside the owner's own or a nested declaration context.
fn ownerParamsInScope(b: *FuncBuilder, target: FuncId) bool {
    const ds = b.module.decl_sigs.get(target.int()) orelse return false;
    const oid = ds.enclosing_class orelse return false;
    if (oid.int() >= b.module.classes.items.len) return false;
    const ocls = &b.module.classes.items[oid.int()];
    if (ocls.type_params.len == 0) return false;
    for (ocls.type_params) |tp| {
        if (!b.isTypeParam(tp)) return false;
    }
    return true;
}

/// The bare-call arm's extension attempt: a bare name in a receiver context that
/// no member serves may be an extension of the implicit receiver.
fn bareExtensionTarget(
    b: *FuncBuilder,
    name: ast.Ident,
    recv: ir.TypeRef,
    shapes: []applicability.ArgShape,
    bounds: ?[]const ir.ModuleRegistry.TypeParamBound,
) Allocator.Error!?ir.FuncId {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_BARE_EXT") orelse "1", "0")) return null;
    const implicit_owners = try b.collectImplicitReceiverTower(
        b.allocator,
        eagerLambdaRecvHead(b),
    );
    defer b.allocator.free(implicit_owners);
    const ctx = ir.Module.ExtensionResolveCtx{
        .caller_file = name.span.file,
        .caller_package = b.module.packageOfFile(name.span.file) orelse b.self_package,
        .implicit_dispatch_owners = implicit_owners,
        .lexical_owner = b.ownerClass(),
        .call_name = name.name,
        .actual_type_param_bounds = bounds orelse &.{},
    };
    {
        const r = b.module.resolveExtensionCall(name.name, recv, shapes, ctx);
        // Typing only: a strict-key winner withheld solely on an unknown argument
        // still lends its return type, never an emission.
        if (r.target orelse r.sole_unknown) |t| return t;
    }
    // Kotlin resolves a bare call against every implicit receiver, innermost first,
    // so when the innermost head serves no extension the outer tower entries are the
    // remaining candidates.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_TOWER_EXT") orelse "1", "0")) {
        const recv_head = typeHead(std.mem.trimEnd(u8, recv.name, "?"));
        for (b.implicit_receiver_tower.items) |entry| {
            if (std.mem.eql(u8, entry.head, recv_head)) continue;
            const outer_ref = ir.TypeRef{ .name = entry.head, .nullable = false, .args = &.{} };
            if (b.module.resolveExtensionCall(name.name, outer_ref, shapes, ctx).target) |t| return t;
        }
    }
    return null;
}

/// Replace each use-site-projected argument name (`in#K`, `out#E`) with the plain
/// parameter, recursively. The owned name is re-allocated so `deinit` still frees
/// what `clone` allocated.
fn stripUseSiteProjections(a: Allocator, ty: *ir.TypeRef) Allocator.Error!void {
    for (ty.args) |*arg| {
        const suffix: ?[]const u8 = if (std.mem.startsWith(u8, arg.name, "in#"))
            arg.name["in#".len..]
        else if (std.mem.startsWith(u8, arg.name, "out#"))
            arg.name["out#".len..]
        else
            null;
        if (suffix) |plain| {
            const owned = try a.dupe(u8, plain);
            a.free(arg.name);
            arg.name = owned;
        }
        try stripUseSiteProjections(a, arg);
    }
}

/// The receiver-type chain used by the `Member` and `Index` arms.
fn recvChainTypeRef(b: *FuncBuilder, e: *const Expr) Allocator.Error!?ir.TypeRef {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_RECV_CHAIN") orelse "1", "0")) {
        if (argDeclTypeRefLazy(b, e)) |known| return try known.clone(b.allocator);
        return staticCallReturnTypeRef(b, e);
    }
    return staticExprTypeRef(b, e);
}

/// The user-argument count of a `.Call` expression, named or not.
fn memberArgCount(call_expr: *const Expr) usize {
    if (call_expr.* != .Call) return 0;
    return call_expr.Call.args.len;
}

/// The declared return type of a call whose callee is a function-typed local or
/// parameter, without which the result local carries no type. A lowered function
/// type keeps its return as the last entry of `args`, after the optional `#suspend`
/// marker, the optional receiver, and the parameters.
fn fnTypedCalleeReturnTypeRef(b: *FuncBuilder, call_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (call_expr.* != .Call) return null;
    const callee = call_expr.Call.callee;
    const name: []const u8 = switch (callee.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
        .Member => |m| m.name.name,
        else => return null,
    };
    // A recorded declared type is evidence on its own: a probe builder carries the
    // enclosing scope's decl types without its registers.
    const ty = b.localDeclTypeRef(name) orelse return null;
    // Both fn-type spellings: the registry's `FunctionN` and the local channel's
    // `<function>` head.
    if (!std.mem.startsWith(u8, ty.name, "Function") and
        !std.mem.eql(u8, ty.name, "<function>")) return null;
    if (ty.args.len == 0) return null;
    const ret = ty.args[ty.args.len - 1];
    if (ret.name.len == 0 or ret.name[0] == '#') return null;
    return try ret.clone(b.allocator);
}

/// The return type of a call whose callee spells a dotted FQN, picked the way the
/// emission picks it, by exact FQN and matching arity.
fn fqnCallReturnTypeRef(b: *FuncBuilder, call_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (call_expr.* != .Call) return null;
    const callee = call_expr.Call.callee;
    if (callee.* != .Member) return null;
    const fqn = (try collectDottedFqn(b.allocator, callee)) orelse return null;
    defer b.allocator.free(fqn);
    const tail = rsplitLast(fqn, '.');
    if (std.mem.eql(u8, tail, fqn)) return null;
    const want = call_expr.Call.args.len;
    for (b.module.funcsBySimpleName(tail)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!std.mem.eql(u8, f.fqn, fqn) or f.params.len != want) continue;
        if (f.return_ty.name.len == 0) return null;
        const h = typeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"));
        if (h.len <= 2 and h.len > 0 and std.ascii.isUpper(h[0])) return null;
        if (staticTypeClassId(b, f.return_ty) == null) return null;
        return try f.return_ty.clone(b.allocator);
    }
    return null;
}

/// The declared return of a bare call to a local `fun`, which is lifted under a
/// mangled module name the simple-name index cannot answer for. Only an unambiguous
/// answer is taken: the same return across every same-named declaration in scope.
fn localFnReturnTypeRef(b: *FuncBuilder, call_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (call_expr.* != .Call) return null;
    const callee = call_expr.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const nm = callee.Path.segments[0].name;
    // A local `fun` is also bound to a register holding its closure, so a non-null
    // `resolve` says nothing here; the name is the function.
    if (!b.isLocalFn(nm)) return null;
    const decls = b.localFnDecls(nm) orelse return null;
    var agreed: ?ir.TypeRef = null;
    for (decls) |ov| {
        const rt = b.localFnReturnTy(ov.mangled) orelse return null;
        if (rt.name.len == 0 or bareTypeParamHead(rt.name)) return null;
        if (agreed) |prev| {
            if (!std.mem.eql(u8, prev.name, rt.name) or prev.nullable != rt.nullable) return null;
        } else agreed = rt;
    }
    const ret = agreed orelse return null;
    if (staticTypeClassId(b, ret) == null) return null;
    return try ret.clone(b.allocator);
}

/// The declared return of a bare top-level or extension call when the call-site
/// evidence commits one candidate: an `as`-cast pick, the trailing lambda's derived
/// return, or a sole arity-matching body-carrying candidate.
fn bareCallReturnTypeRef(b: *FuncBuilder, call_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (call_expr.* != .Call) return null;
    const call = call_expr.Call;
    if (call.callee.* != .Path or call.callee.Path.segments.len != 1) return null;
    const seg = call.callee.Path.segments[0];
    const nm = seg.name;
    if (b.resolve(nm) != null or b.knowsOuter(nm) or b.isLocalFn(nm)) {
        if (runtime.envOnce("KLIO_VARARG_TRACE") != null and std.mem.eql(u8, nm, "listOf"))
            std.debug.print("[vaf-guard] {s} resolve={} outer={} localfn={}\n", .{ nm, b.resolve(nm) != null, b.knowsOuter(nm), b.isLocalFn(nm) });
        return null;
    }
    const cands = try b.module.bareCallCandidates(b.allocator, nm, seg.span.file);
    defer b.allocator.free(cands);
    if (cands.len == 0) {
        if (runtime.envOnce("KLIO_VARARG_TRACE") != null and std.mem.eql(u8, nm, "listOf"))
            std.debug.print("[vaf-nocands] {s}\n", .{nm});
        return null;
    }
    const want = call.args.len;
    var pick: ?FuncId = (try overloadPickByCast(b, cands, call.args, want)) orelse
        try overloadPickByLambdaReturn(b, cands, call.args, want);
    if (pick == null and want != 0 and want <= 4) exact: {
        // Exact argument-head discrimination for a scalar overload family, where
        // the Int and Long siblings pick by the derived heads.
        var heads: [4]?ir.TypeRef = .{ null, null, null, null };
        defer for (heads[0..want]) |*h| if (h.*) |*t| t.deinit(b.allocator);
        if (expr.od_depth >= 3) break :exact;
        expr.od_depth += 1;
        for (call.args[0..want], 0..) |*arg, i| {
            heads[i] = staticExprTypeRef(b, arg) catch null;
        }
        expr.od_depth -= 1;
        for (heads[0..want]) |h| {
            if (h == null) break :exact;
        }
        var match: ?FuncId = null;
        for (cands) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (!f.hasBody()) continue;
            const base: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            if (f.params.len -| base != want) continue;
            var all_exact = true;
            for (f.params[base..], 0..) |*p2, i| {
                const ah = typeHead(std.mem.trimEnd(u8, heads[i].?.name, "?"));
                const ph = typeHead(std.mem.trimEnd(u8, p2.ty.name, "?"));
                if (!std.mem.eql(u8, ah, ph)) {
                    all_exact = false;
                    break;
                }
            }
            if (!all_exact) continue;
            if (match != null) break :exact;
            match = fid;
        }
        pick = match;
    }
    if (runtime.envOnce("KLIO_VARARG_TRACE") != null and std.mem.eql(u8, nm, "listOf"))
        std.debug.print("[vaf-enter] {s} pick={} want={d} depth={d}\n", .{ nm, pick != null, want, expr.od_depth });
    if (pick == null and want != 0 and want <= 8 and expr.od_depth < 3) vararg_full: {
        // A sole trailing-vararg candidate whose every argument derives one concrete
        // head yields its return fully instantiated, which is what kotlinc infers.
        // Every qualifying candidate has a trailing vararg, one value param, one fn
        // type param, and a declared return `Head<T>`; the record derives only when
        // they all agree on the return head.
        var sole_v: ?FuncId = null;
        var agree_head: ?[]const u8 = null;
        for (cands) |fid| {
            const f3 = b.module.funcById(fid) orelse continue;
            // No body requirement: this arm derives from the declared signature
            // alone, and the image's lazy-header `listOf` is bodyless until
            // materialized.
            const base: usize = if (f3.params.len != 0 and std.mem.eql(u8, f3.params[0].name, "this")) 1 else 0;
            const has_va = f3.params.len != 0 and f3.params[f3.params.len - 1].is_vararg;
            if (!has_va or f3.params.len -| base != 1) continue;
            const vtr = runtime.envOnce("KLIO_VARARG_TRACE") != null and std.mem.eql(u8, nm, "listOf");
            const tps3 = b.module.registry.func_type_params.get(fid) orelse {
                if (vtr) std.debug.print("[vaf-cand] {s} no-tps\n", .{f3.fqn});
                break :vararg_full;
            };
            if (tps3.items.len != 1) {
                if (vtr) std.debug.print("[vaf-cand] {s} tps={d}\n", .{ f3.fqn, tps3.items.len });
                break :vararg_full;
            }
            if (!f3.return_ty_declared or f3.return_ty.args.len != 1) {
                if (vtr) std.debug.print("[vaf-cand] {s} ret_decl={} ret_args={d}\n", .{ f3.fqn, f3.return_ty_declared, f3.return_ty.args.len });
                break :vararg_full;
            }
            var ra3 = std.mem.trimEnd(u8, f3.return_ty.args[0].name, "?");
            if (std.mem.startsWith(u8, ra3, "in#")) ra3 = ra3[3..];
            if (std.mem.startsWith(u8, ra3, "out#")) ra3 = ra3[4..];
            var tp3: []const u8 = tps3.items[0];
            // Identity-mangled spellings (`T#owner`) compare by their bare parameter
            // name.
            if (std.mem.findScalar(u8, ra3, '#')) |hx| ra3 = ra3[0..hx];
            if (std.mem.findScalar(u8, tp3, '#')) |hx| tp3 = tp3[0..hx];
            if (!std.mem.eql(u8, ra3, tp3)) {
                if (vtr) std.debug.print("[vaf-cand] {s} ra={s} tp={s}\n", .{ f3.fqn, ra3, tp3 });
                break :vararg_full;
            }
            const head3 = typeHead(std.mem.trimEnd(u8, f3.return_ty.name, "?"));
            if (agree_head) |h| {
                if (!std.mem.eql(u8, h, head3)) {
                    if (vtr) std.debug.print("[vaf-cand] {s} head={s} vs {s}\n", .{ f3.fqn, head3, h });
                    break :vararg_full;
                }
            } else {
                agree_head = head3;
                sole_v = fid;
            }
        }
        if (runtime.envOnce("KLIO_VARARG_TRACE") != null and std.mem.eql(u8, nm, "listOf"))
            std.debug.print("[vaf-sole] {s} sole={}\n", .{ nm, sole_v != null });
        const vf = sole_v orelse break :vararg_full;
        const f2 = b.module.funcById(vf) orelse break :vararg_full;
        var elem_owned: ?ir.TypeRef = null;
        var elem_ok = true;
        // Heterogeneous elements infer their least upper bound, and the head this
        // record needs is `Any`. A null literal contributes only nullability.
        var diverged = false;
        var saw_null = false;
        var heads_buf: [16][]const u8 = undefined;
        var nheads: usize = 0;
        expr.od_depth += 1;
        for (call.args[0..want]) |*a2| {
            if (a2.* == .NullLit) {
                saw_null = true;
                continue;
            }
            var t2 = (staticExprTypeRef(b, a2) catch null) orelse expr.valueClassCtorTypeRef(b, a2) orelse {
                if (runtime.envOnce("KLIO_VARARG_TRACE") != null)
                    std.debug.print("[vaf] {s} elem underived tag={s}\n", .{ nm, @tagName(std.meta.activeTag(a2.*)) });
                elem_ok = false;
                break;
            };
            if (t2.nullable or std.mem.endsWith(u8, t2.name, "?")) {
                if (runtime.envOnce("KLIO_VARARG_TRACE") != null)
                    std.debug.print("[vaf] {s} elem nullable {s}\n", .{ nm, t2.name });
                t2.deinit(b.allocator);
                elem_ok = false;
                break;
            }
            const th = typeHead(t2.name);
            if (nheads < heads_buf.len) {
                // The qualified head, not the simple one: a nested class resolves by
                // its qualified name.
                var full = std.mem.trimEnd(u8, t2.name, "?");
                if (std.mem.findScalar(u8, full, '<')) |lt| full = full[0..lt];
                heads_buf[nheads] = b.allocator.dupe(u8, full) catch th;
                nheads += 1;
            }
            const bare2 = (th.len > 0 and th.len <= 2 and std.ascii.isUpper(th[0])) or
                b.isTypeParam(th) or ir.parseClassTypeParamIdentity(th) != null;
            if (th.len == 0 or bare2) {
                if (runtime.envOnce("KLIO_VARARG_TRACE") != null)
                    std.debug.print("[vaf] {s} elem bare {s}\n", .{ nm, t2.name });
                t2.deinit(b.allocator);
                elem_ok = false;
                break;
            }
            if (elem_owned) |prev| {
                const same = std.mem.eql(u8, prev.name, t2.name);
                if (!same) {
                    // Kotlin joins heterogeneous elements at their least upper bound,
                    // not at `Any`, and the declared element is what extensions bind
                    // against; unrelated heads keep the Any degrade.
                    const ph = typeHead(std.mem.trimEnd(u8, prev.name, "?"));
                    const th2 = typeHead(std.mem.trimEnd(u8, t2.name, "?"));
                    if (b.module.classIsOrExtends(th2, ph)) {
                        t2.deinit(b.allocator);
                    } else if (b.module.classIsOrExtends(ph, th2)) {
                        var old = elem_owned.?;
                        old.deinit(b.allocator);
                        elem_owned = t2;
                    } else {
                        t2.deinit(b.allocator);
                        diverged = true;
                    }
                } else {
                    t2.deinit(b.allocator);
                }
            } else {
                elem_owned = t2;
            }
        }
        expr.od_depth -= 1;
        if (!elem_ok or elem_owned == null) {
            if (elem_owned) |*t| t.deinit(b.allocator);
            break :vararg_full;
        }
        if (diverged) {
            // Unrelated element classes widen to their least upper bound, `Any` only
            // when no common class exists.
            elem_owned.?.deinit(b.allocator);
            const lub = leastUpperBoundOfHeads(b, heads_buf[0..nheads]) orelse "Any";
            elem_owned = .{ .name = try b.allocator.dupe(u8, lub), .nullable = saw_null, .args = &.{} };
        } else if (saw_null) {
            elem_owned.?.nullable = true;
        }
        // An explicit type argument outranks argument-head inference, as kotlinc
        // instantiates it, and the static extension binding downstream depends on
        // the declared element.
        if (call.type_args.len == 1) {
            const ta = &call.type_args[0];
            if (ta.name.name.len != 0 and !b.isTypeParam(ta.name.name)) {
                elem_owned.?.deinit(b.allocator);
                elem_owned = .{
                    .name = try b.allocator.dupe(u8, loweredTypeName(b, ta)),
                    .nullable = ta.nullable,
                    .args = &.{},
                };
            }
        }
        const ret_head = try b.allocator.dupe(u8, std.mem.trimEnd(u8, f2.return_ty.name, "?"));
        errdefer b.allocator.free(ret_head);
        const out_args = try b.allocator.alloc(ir.TypeRef, 1);
        out_args[0] = elem_owned.?;
        return .{ .name = ret_head, .nullable = f2.return_ty.nullable, .args = out_args };
    }
    if (pick == null) {
        // The sole-survivor rule must respect the extension receiver: with the
        // stdlib bodyless in a pack-loaded universe, the one bodied same-arity
        // candidate can be an unrelated-receiver extension.
        const actual_head: ?[]const u8 = blk_ah: {
            const h = b.recvTy() orelse b.spliceRecvTy() orelse b.enclosingRecvTy() orelse break :blk_ah null;
            break :blk_ah typeHead(std.mem.trimEnd(u8, h, "?"));
        };
        var sole: ?FuncId = null;
        for (cands) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (!f.hasBody()) continue;
            if (f.low_priority) continue;
            const base: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            if (f.params.len -| base != want) continue;
            if (base == 1) {
                var dr = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
                if (std.mem.findScalar(u8, dr, '<')) |lt| dr = dr[0..lt];
                const dh = typeHead(dr);
                const generic = dh.len <= 2 or
                    ir.parseClassTypeParamIdentity(f.params[0].ty.name) != null;
                if (!generic) {
                    const ah = actual_head orelse continue;
                    if (!(std.mem.eql(u8, ah, dh) or receiverHeadServes(b, ah, dh))) continue;
                }
            }
            if (sole != null) return null;
            sole = fid;
        }
        pick = sole;
    }
    const fid = pick orelse return null;
    const f = b.module.funcById(fid) orelse return null;
    if (!f.return_ty_declared or f.return_ty.name.len == 0) return null;
    if (bareTypeParamHead(f.return_ty.name) or
        ir.parseClassTypeParamIdentity(f.return_ty.name) != null) return null;
    if (staticTypeClassId(b, f.return_ty) == null) return null;
    // A generic return keeps only its head unless every argument is concrete; a
    // poisoned `List<T>` record disproves more than it types.
    for (f.return_ty.args) |arg| {
        if (bareTypeParamHead(arg.name) or ir.parseClassTypeParamIdentity(arg.name) != null) {
            // The implicit receiver instantiates an extension's generic return, so
            // a bare `toMutableList()` inside `Iterable<Base>.f()` is
            // `MutableList<Base>`; without it the local stays untyped.
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) recv_inst: {
                const fr: ir.TypeRef = if (b.spliceRecvTyRef()) |r| r.* else (b.recvTypeRef() orelse break :recv_inst);
                if (fr.args.len == 0) break :recv_inst;
                var shape_set0 = try buildStaticReturnArgShapes(b, call.args, &.{});
                defer shape_set0.deinit(b.allocator);
                if (try b.module.instantiatedCallReturnType(b.allocator, fid, fr, null, shape_set0.shapes, &.{})) |inst| {
                    var out2 = inst;
                    const oh = typeHead(std.mem.trimEnd(u8, out2.name, "?"));
                    var concrete = oh.len > 2 and !b.isTypeParam(oh) and
                        ir.parseClassTypeParamIdentity(oh) == null;
                    if (concrete) for (out2.args) |a2| {
                        const ah = typeHead(std.mem.trimEnd(u8, a2.name, "?"));
                        if (bareTypeParamHead(ah) or ir.parseClassTypeParamIdentity(ah) != null) {
                            concrete = false;
                            break;
                        }
                    };
                    if (concrete) return out2;
                    out2.deinit(b.allocator);
                }
            }
            // An explicit type-argument list instantiates the generic return
            // directly, and kotlinc resolves the overload set on it statically.
            if (call.type_args.len != 0) explicit: {
                const expl_trace = if (runtime.envOnce("KLIO_SCRT_TRACE")) |w| std.mem.eql(u8, w, nm) else false;
                const tp = b.module.registry.func_type_params.get(fid) orelse {
                    if (expl_trace) std.debug.print("[expl] {s} no func_type_params fid={d}\n", .{ nm, fid.int() });
                    break :explicit;
                };
                if (expl_trace) std.debug.print("[expl] {s} tp={d} targs={d}\n", .{ nm, tp.items.len, call.type_args.len });
                if (tp.items.len != call.type_args.len) break :explicit;
                const out_args = try b.allocator.alloc(ir.TypeRef, f.return_ty.args.len);
                var filled: usize = 0;
                for (f.return_ty.args, out_args) |*ra, *oa| {
                    const rah = typeHead(std.mem.trimEnd(u8, ra.name, "?"));
                    var sub: ?*const ast.TypeRef = null;
                    for (tp.items, 0..) |pn, pi| {
                        if (std.mem.eql(u8, pn, rah)) {
                            sub = &call.type_args[pi];
                            break;
                        }
                    }
                    const s = sub orelse break;
                    if (s.name.name.len == 0 or b.isTypeParam(s.name.name)) break;
                    oa.* = .{
                        .name = try b.allocator.dupe(u8, loweredTypeName(b, s)),
                        .nullable = s.nullable or ra.nullable,
                        .args = &.{},
                    };
                    filled += 1;
                }
                if (filled != out_args.len) {
                    if (expl_trace) std.debug.print("[expl] {s} filled={d}/{d} ra0={s} tp0={s}\n", .{ nm, filled, out_args.len, if (f.return_ty.args.len > 0) f.return_ty.args[0].name else "-", tp.items[0] });
                    for (out_args[0..filled]) |*oa| oa.deinit(b.allocator);
                    b.allocator.free(out_args);
                    break :explicit;
                }
                return .{
                    .name = try b.allocator.dupe(u8, std.mem.trimEnd(u8, f.return_ty.name, "?")),
                    .nullable = f.return_ty.nullable,
                    .args = out_args,
                };
            }
            return .{
                .name = try b.allocator.dupe(u8, f.return_ty.name),
                .nullable = f.return_ty.nullable,
                .args = &.{},
            };
        }
    }
    return try f.return_ty.clone(b.allocator);
}

fn scrtVia(call_expr: *const Expr, via: []const u8, t: ir.TypeRef) ir.TypeRef {
    if (runtime.envOnce("KLIO_SCRT_TRACE")) |w| {
        if (call_expr.* == .Call and call_expr.Call.callee.* == .Path and
            call_expr.Call.callee.Path.segments.len == 1 and
            std.mem.eql(u8, w, call_expr.Call.callee.Path.segments[0].name))
        {
            std.debug.print("[scrt-via] {s} via={s} ty={s}\n", .{ w, via, t.name });
        }
        if (call_expr.* == .Call and call_expr.Call.callee.* == .Member and
            std.mem.eql(u8, w, call_expr.Call.callee.Member.name.name))
        {
            std.debug.print("[scrt-via] member {s} via={s} ty={s}\n", .{ w, via, t.name });
        }
    }
    return t;
}

/// Whether `target` belongs to an overload family whose members return different
/// primitive types and whose choice this call cannot prove: every candidate takes
/// one scalar parameter and returns it. A bare-name call only.
fn scalarOverloadUnproven(b: *FuncBuilder, call: anytype, target: FuncId) Allocator.Error!bool {
    if (call.callee.* != .Path or call.callee.Path.segments.len != 1) return false;
    if (call.args.len != 1) return false;
    const tf = b.module.funcById(target) orelse return false;
    if (!isPrimitiveTypeName(typeHead(std.mem.trimEnd(u8, tf.return_ty.name, "?")))) return false;
    const nm = call.callee.Path.segments[0].name;
    const cands = b.module.funcsBySimpleName(nm);
    if (cands.len < 2) return false;
    var disagree = false;
    for (cands) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (f.params.len - @intFromBool(has_this) != 1) return false;
        const rh = typeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"));
        if (!isPrimitiveTypeName(rh)) return false;
        if (!std.mem.eql(u8, rh, typeHead(std.mem.trimEnd(u8, tf.return_ty.name, "?")))) disagree = true;
    }
    if (!disagree) return false;
    if (expr.od_depth >= 3) return true;
    expr.od_depth += 1;
    var arg_ty = staticExprTypeRef(b, &call.args[0]) catch null;
    expr.od_depth -= 1;
    if (arg_ty) |*t| {
        defer t.deinit(b.allocator);
        return !isPrimitiveTypeName(typeHead(std.mem.trimEnd(u8, t.name, "?")));
    }
    return true;
}

/// The nearest class every head is or extends, walking the first head's supertype
/// chain outward breadth-first; null when no class short of `Any` is common.
fn leastUpperBoundOfHeads(b: *const FuncBuilder, heads: []const []const u8) ?[]const u8 {
    if (heads.len < 2) return null;
    const lub_trace = runtime.envOnce("KLIO_LUB_TRACE") != null;
    if (lub_trace) {
        std.debug.print("[lub] heads:", .{});
        for (heads) |h| std.debug.print(" {s}", .{h});
        std.debug.print("\n", .{});
    }
    var queue: [64]ir.ClassId = undefined;
    var qlen: usize = 0;
    var qhead: usize = 0;
    const first = b.module.classIdByFqn(heads[0]) orelse b.module.classId(heads[0]) orelse return null;
    queue[qlen] = first;
    qlen += 1;
    while (qhead < qlen) : (qhead += 1) {
        const cid = queue[qhead];
        if (cid.int() >= b.module.classes.items.len) continue;
        const cls = &b.module.classes.items[cid.int()];
        var all = true;
        for (heads[1..]) |h| {
            if (!(std.mem.eql(u8, h, cls.name) or std.mem.eql(u8, h, cls.fqn) or
                b.module.classIsOrExtends(h, cls.fqn) or b.module.classIsOrExtends(h, cls.name)))
            {
                all = false;
                break;
            }
        }
        if (lub_trace) std.debug.print("[lub] cand {s} (name={s}) supers={d} all={}\n", .{ cls.fqn, cls.name, cls.supertypes.len, all });
        if (all) return cls.fqn;
        for (cls.supertypes) |sup| {
            if (qlen < queue.len) {
                queue[qlen] = sup;
                qlen += 1;
            }
        }
    }
    return null;
}

/// A bare type-parameter result takes the explicit type argument written at the
/// call, type arguments included, so a local initialized by it is typed by that
/// argument rather than by `T`.
fn explicitBareReturn(b: *FuncBuilder, call_expr: *const Expr, r: ?ir.TypeRef) Allocator.Error!?ir.TypeRef {
    const t = r orelse return null;
    if (call_expr.* != .Call) return r;
    const c = call_expr.Call;
    if (c.type_args.len == 0 or !bareTypeParamHead(t.name)) return r;
    const cname: []const u8 = switch (c.callee.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return r,
        .Member => |m| m.name.name,
        else => return r,
    };
    const tn = std.mem.trimEnd(u8, t.name, "?");
    for (b.module.funcsBySimpleName(cname)) |fid| {
        const tp = b.module.registry.func_type_params.get(fid) orelse continue;
        if (tp.items.len != c.type_args.len) continue;
        for (tp.items, 0..) |pn, pi| {
            if (!std.mem.eql(u8, pn, tn)) continue;
            const s = &c.type_args[pi];
            if (s.name.name.len == 0 or b.isTypeParam(s.name.name)) return r;
            var lowered = try decl_mod.loweredTypeRef(b.allocator, s, true);
            if (t.nullable) lowered.nullable = true;
            return lowered;
        }
    }
    return r;
}

pub fn staticCallReturnTypeRef(
    b: *FuncBuilder,
    call_expr: *const Expr,
) Allocator.Error!?ir.TypeRef {
    if (expr.tyMemoCall(b, call_expr)) |hit| return hit.ty;
    const owns = expr.tyMemoCallEnter(b);
    var r = try staticCallReturnTypeRefInner(b, call_expr);
    r = try explicitBareReturn(b, call_expr, r);
    expr.tyMemoCallLeave(b, owns, call_expr, r);
    if (runtime.envOnce("KLIO_SCRT_TRACE")) |w| {
        if (call_expr.* == .Call and call_expr.Call.callee.* == .Path and
            call_expr.Call.callee.Path.segments.len == 1 and
            std.mem.eql(u8, w, call_expr.Call.callee.Path.segments[0].name))
        {
            std.debug.print("[scrt-out] {s} ty={s}\n", .{ w, if (r) |t| t.name else "-" });
        }
        if (call_expr.* == .Call and call_expr.Call.callee.* == .Member and
            std.mem.eql(u8, w, call_expr.Call.callee.Member.name.name))
        {
            std.debug.print("[scrt-out] member {s} ty={s}\n", .{ w, if (r) |t| t.name else "-" });
        }
    }
    return r;
}

fn staticCallReturnTypeRefInner(
    b: *FuncBuilder,
    call_expr: *const Expr,
) Allocator.Error!?ir.TypeRef {
    if (runtime.envOnce("KLIO_SCRT_TRACE")) |w| {
        if (call_expr.* == .Call and call_expr.Call.callee.* == .Path and call_expr.Call.callee.Path.segments.len == 1 and
            std.mem.eql(u8, w, call_expr.Call.callee.Path.segments[0].name))
        {
            std.debug.print("[scrt-in] {s} nargs={d}\n", .{ w, call_expr.Call.args.len });
        }
    }
    // The `Any` members' returns are fixed by their signatures, every override
    // keeping them, so a chain does not die on an untypeable receiver. A safe call
    // carries the `?`.
    if (call_expr.* == .Call) {
        const c = call_expr.Call;
        if (c.callee.* == .Member) {
            const m = c.callee.Member;
            const nm2 = m.name.name;
            if (c.args.len == 0 and std.mem.eql(u8, nm2, "toString")) {
                return .{ .name = try b.allocator.dupe(u8, "String"), .nullable = m.safe, .args = &.{} };
            }
            if (c.args.len == 0 and std.mem.eql(u8, nm2, "hashCode")) {
                return .{ .name = try b.allocator.dupe(u8, "Int"), .nullable = m.safe, .args = &.{} };
            }
            if (c.args.len == 1 and std.mem.eql(u8, nm2, "equals")) {
                return .{ .name = try b.allocator.dupe(u8, "Boolean"), .nullable = m.safe, .args = &.{} };
            }
            // The scalar conversions have fixed returns on a primitive receiver,
            // whose builtin class rows carry no method ids to resolve through.
            if (c.args.len == 0 and !m.safe and expr.od_depth < 4) conv: {
                const table = [_]struct { n: []const u8, t: []const u8 }{
                    .{ .n = "toInt", .t = "Int" },       .{ .n = "toLong", .t = "Long" },
                    .{ .n = "toDouble", .t = "Double" }, .{ .n = "toFloat", .t = "Float" },
                    .{ .n = "toShort", .t = "Short" },   .{ .n = "toByte", .t = "Byte" },
                    .{ .n = "toChar", .t = "Char" },     .{ .n = "toUInt", .t = "UInt" },
                    .{ .n = "toULong", .t = "ULong" },   .{ .n = "toUShort", .t = "UShort" },
                    .{ .n = "toUByte", .t = "UByte" },
                };
                var hit: ?[]const u8 = null;
                for (table) |cv| {
                    if (std.mem.eql(u8, nm2, cv.n)) {
                        hit = cv.t;
                        break;
                    }
                }
                const out_head = hit orelse break :conv;
                expr.od_depth += 1;
                const rt0 = staticExprTypeRef(b, m.receiver) catch null;
                expr.od_depth -= 1;
                var rt = rt0 orelse break :conv;
                defer rt.deinit(b.allocator);
                if (rt.nullable) break :conv;
                const rh0 = typeHead(std.mem.trimEnd(u8, rt.name, "?"));
                if (!isPrimitiveTypeName(rh0)) break :conv;
                return .{ .name = try b.allocator.dupe(u8, out_head), .nullable = false, .args = &.{} };
            }
        }
    }
    // The universal scope functions have fixed semantics, the emission already
    // treating them as no-dispatch splices: `.also`/`.apply` return their receiver,
    // `.let`/`.run` their lambda's tail. Depth-guarded like every recursive derivation.
    if (call_expr.* == .Call) scope_fns: {
        const c = call_expr.Call;
        if (c.callee.* != .Member) break :scope_fns;
        const m = c.callee.Member;
        const nm2 = m.name.name;
        const is_echo = std.mem.eql(u8, nm2, "also") or std.mem.eql(u8, nm2, "apply");
        const is_tail = std.mem.eql(u8, nm2, "let") or std.mem.eql(u8, nm2, "run");
        if (!is_echo and !is_tail) break :scope_fns;
        const sfx_trace = runtime.envOnce("KLIO_SCOPEFN_TRACE") != null;
        if (sfx_trace) std.debug.print("[scopefn] {s} enter depth={d}\n", .{ nm2, expr.od_depth });
        // The ambient derivation chain often sits at depth 3 when a local's `.let`
        // init derives, and this arm does constant work per level, so it gets a
        // slightly higher bound.
        if (expr.od_depth >= 6) {
            if (sfx_trace) std.debug.print("[scopefn] {s} bail=depth {d}\n", .{ nm2, expr.od_depth });
            break :scope_fns;
        }
        if (c.args.len != 1 or c.args[0] != .Lambda) {
            if (sfx_trace) std.debug.print("[scopefn] {s} bail=args n={d}\n", .{ nm2, c.args.len });
            break :scope_fns;
        }
        // Only when no competing declaration could own the name: every
        // same-simple-name candidate must be a kotlin-package extension, and the
        // receiver's hierarchy must not declare a member of the name.
        for (b.module.funcsBySimpleName(nm2)) |fid2| {
            const f2 = b.module.funcById(fid2) orelse continue;
            const is_ext2 = f2.params.len != 0 and std.mem.eql(u8, f2.params[0].name, "this");
            const kotlin_pkg = std.mem.eql(u8, f2.package, "kotlin") or
                std.mem.startsWith(u8, f2.package, "kotlin.");
            if (!is_ext2 or !kotlin_pkg) {
                if (sfx_trace) std.debug.print("[scopefn] {s} bail=candidate {s} pkg={s}\n", .{ nm2, f2.fqn, f2.package });
                break :scope_fns;
            }
        }
        expr.od_depth += 1;
        defer expr.od_depth -= 1;
        var recv_owned = (staticExprTypeRef(b, m.receiver) catch null) orelse {
            if (sfx_trace) std.debug.print("[scopefn] {s} bail=recv_untyped\n", .{nm2});
            break :scope_fns;
        };
        // No hierarchy-name check here: the registry lists the scope functions as
        // reachable on every builtin head, and a user class's member registers in
        // the simple-name index the gate above walks.
        if (is_echo) {
            var echo = recv_owned;
            if (m.safe) echo.nullable = true;
            return echo;
        }
        defer recv_owned.deinit(b.allocator);
        const lam = c.args[0].Lambda;
        const stmts2 = lam.body.stmts;
        if (stmts2.len == 0 or stmts2[stmts2.len - 1] != .Expr) break :scope_fns;
        var nb2 = FuncBuilder.init(b.allocator, b.module) catch break :scope_fns;
        nb2.census_quiet = true;
        defer nb2.deinit();
        // The lambda's free names resolve in the enclosing scope, so seed the probe
        // builder with its declared types; the receiver-bound parameter shadows.
        {
            var dit2 = b.local_decl_types.iterator();
            while (dit2.next()) |e2| {
                nb2.setLocalDeclTypeOwned(e2.key_ptr.*, e2.value_ptr.clone(b.allocator) catch continue) catch {};
            }
        }
        if (std.mem.eql(u8, nm2, "let")) {
            const pname = if (lam.params.len != 0) lam.params[0].name else "it";
            var seed = recv_owned.clone(b.allocator) catch break :scope_fns;
            // A safe call unwraps: the parameter inside `x?.let { }` is non-null.
            if (m.safe) seed.nullable = false;
            nb2.setLocalDeclTypeOwned(pname, seed) catch break :scope_fns;
        } else {
            nb2.setRecvTypeRefOwned(recv_owned.clone(b.allocator) catch break :scope_fns);
        }
        if (staticExprTypeRef(&nb2, &stmts2[stmts2.len - 1].Expr) catch null) |derived| {
            var dt = derived;
            var h = std.mem.trimEnd(u8, dt.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                ir.parseClassTypeParamIdentity(h) != null;
            if (h.len != 0 and !bare) {
                // `x?.let { ... }` yields the tail type OR null.
                if (m.safe) dt.nullable = true;
                if (sfx_trace) std.debug.print("[scopefn] {s} ret={s}\n", .{ nm2, dt.name });
                return dt;
            }
            if (sfx_trace) std.debug.print("[scopefn] {s} bail=bare_tail {s}\n", .{ nm2, dt.name });
            dt.deinit(b.allocator);
        } else if (sfx_trace) std.debug.print("[scopefn] {s} bail=tail_underived\n", .{nm2});
        break :scope_fns;
    }
    if (try fnTypedCalleeReturnTypeRef(b, call_expr)) |t| return scrtVia(call_expr, "fnTyped", t);
    if (try fqnCallReturnTypeRef(b, call_expr)) |t| return scrtVia(call_expr, "fqn", t);
    if (try localFnReturnTypeRef(b, call_expr)) |t| return scrtVia(call_expr, "localFn", t);
    if (try bareCallReturnTypeRef(b, call_expr)) |t| return scrtVia(call_expr, "bareCall", t);
    if (try memberCallReturnTypeRef(b, call_expr)) |t| return scrtVia(call_expr, "memberCall", t);
    if (try bareMemberReturnTypeRef(b, call_expr)) |t| {
        if (runtime.envOnce("KLIO_SCRT_TRACE")) |w| {
            if (call_expr.* == .Call and call_expr.Call.callee.* == .Path and call_expr.Call.callee.Path.segments.len == 1 and std.mem.eql(u8, w, call_expr.Call.callee.Path.segments[0].name)) {
                std.debug.print("[scrt] {s} via=bareMember ty={s}\n", .{ w, t.name });
            }
        }
        return t;
    }
    if (call_expr.* == .Binary) {
        const bin = call_expr.Binary;
        const method: []const u8 = switch (bin.op) {
            .Add => "plus",
            .Sub => "minus",
            .Mul, .Div, .Rem, .Range, .RangeUntil => blk: {
                if (std.mem.eql(u8, runtime.envOnce("KLIO_OPERATOR_TY") orelse "1", "0")) return null;
                break :blk switch (bin.op) {
                    .Mul => "times",
                    .Div => "div",
                    .Rem => "rem",
                    .Range => "rangeTo",
                    else => "rangeUntil",
                };
            },
            else => return null,
        };
        var inferred_receiver: ?ir.TypeRef = null;
        defer if (inferred_receiver) |*ty| ty.deinit(b.allocator);
        const receiver = argDeclTypeRefLazy(b, bin.lhs) orelse blk: {
            // The full deriver, not the call-return subset: an Index lhs types
            // through the element arm only there.
            inferred_receiver = try staticExprTypeRef(b, bin.lhs);
            break :blk inferred_receiver orelse return null;
        };
        if (isPrimitiveTypeName(typeHead(receiver.name))) {
            // A primitive operand's arithmetic result type is table-driven, needing
            // no operator resolution.
            if (primitiveBinResultHead(b, typeHead(std.mem.trimEnd(u8, receiver.name, "?")), bin)) |head| {
                return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
            }
            return null;
        }

        const args = bin.rhs[0..1];
        var shape_set = try buildStaticReturnArgShapes(b, args, &.{});
        defer shape_set.deinit(b.allocator);
        const owned_bounds = try b.typeParamBoundsSlice();
        defer if (owned_bounds) |bounds| b.allocator.free(bounds);

        var target: ?FuncId = null;
        var member_applicable = false;
        var identity = std.mem.trimEnd(u8, receiver.name, "?");
        if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
        const head = typeHead(identity);
        const owner_id = if (std.mem.findScalar(u8, identity, '.') != null)
            b.module.classIdByFqn(identity)
        else
            b.module.uniqueClassIdBySimpleName(head);
        if (owner_id) |owner| {
            const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
                (if (std.mem.findScalar(u8, owner_name, '.') != null)
                    b.module.classIdByFqn(owner_name)
                else
                    (b.module.classIdIndexed(
                        owner_name,
                        b.self_package,
                        bin.span.file,
                    ) orelse b.module.classId(owner_name)))
            else
                null;
            const resolved = b.module.resolveMemberCall(
                owner,
                method,
                shape_set.shapes,
                .{
                    .caller_file = bin.span.file,
                    .lexical_owner = lexical_owner,
                    .actual_type_param_bounds = owned_bounds orelse &.{},
                    .receiver_type = receiver,
                },
            );
            member_applicable = resolved.applicable;
            if (resolved.dispatch != .deferred) target = resolved.target;
        }
        if (target == null) {
            if (member_applicable) return null;
            const implicit_owners = try b.collectImplicitReceiverTower(
                b.allocator,
                eagerLambdaRecvHead(b),
            );
            defer b.allocator.free(implicit_owners);
            target = b.module.resolveExtensionCall(
                method,
                receiver,
                shape_set.shapes,
                .{
                    .caller_file = bin.span.file,
                    .caller_package = b.module.packageOfFile(bin.span.file) orelse b.self_package,
                    .implicit_dispatch_owners = implicit_owners,
                    .lexical_owner = b.ownerClass(),
                    .call_name = method,
                    .actual_type_param_bounds = owned_bounds orelse &.{},
                },
            ).target;
        }
        const resolved_target = target orelse return null;
        var dispatch_receiver = try staticDispatchReceiverTypeRef(
            b,
            resolved_target,
            receiver,
            bin.span.file,
        );
        defer if (dispatch_receiver) |*ty| ty.deinit(b.allocator);
        return try b.module.instantiatedCallReturnType(
            b.allocator,
            resolved_target,
            receiver,
            dispatch_receiver,
            shape_set.shapes,
            &.{},
        );
    }
    // `a[i]` is `a.get(i)`, so the element's static type is `get`'s return type on
    // the container, the ordinary member question even though lowering emits Index.
    if (call_expr.* == .Index and
        !std.mem.eql(u8, runtime.envOnce("KLIO_OPERATOR_TY") orelse "1", "0"))
    {
        const idx = call_expr.Index;
        const opty_trace = runtime.envOnce("KLIO_OPTY_TRACE") != null;
        var recv_owned = (try recvChainTypeRef(b, idx.receiver)) orelse {
            if (opty_trace) std.debug.print("[opty] recv untyped\n", .{});
            return null;
        };
        defer recv_owned.deinit(b.allocator);
        var shape_set = try buildStaticReturnArgShapes(b, idx.args, &.{});
        defer shape_set.deinit(b.allocator);
        const owned_bounds = try b.typeParamBoundsSlice();
        defer if (owned_bounds) |bounds| b.allocator.free(bounds);
        var identity = std.mem.trimEnd(u8, recv_owned.name, "?");
        if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
        const owner = (if (std.mem.findScalar(u8, identity, '.') != null)
            b.module.classIdByFqn(identity)
        else
            b.module.uniqueClassIdBySimpleName(typeHead(identity))) orelse {
            if (opty_trace) std.debug.print("[opty] recv={s} owner unresolved\n", .{identity});
            return null;
        };
        const resolved = b.module.resolveMemberCall(owner, "get", shape_set.shapes, .{
            .caller_file = idx.span.file,
            .lexical_owner = null,
            .actual_type_param_bounds = owned_bounds orelse &.{},
            .receiver_type = recv_owned,
        });
        const target = resolved.target orelse {
            if (opty_trace) std.debug.print("[opty] recv={s} get unresolved n_shapes={d} shape0_ty={s}\n", .{ identity, shape_set.shapes.len, if (shape_set.shapes.len != 0 and shape_set.shapes[0].ty != null) shape_set.shapes[0].ty.?.name else "-" });
            return null;
        };
        var dispatch_receiver = try staticDispatchReceiverTypeRef(b, target, recv_owned, idx.span.file);
        defer if (dispatch_receiver) |*ty| ty.deinit(b.allocator);
        const idx_ret = try b.module.instantiatedCallReturnType(
            b.allocator,
            target,
            recv_owned,
            dispatch_receiver,
            shape_set.shapes,
            &.{},
        );
        if (opty_trace) std.debug.print("[opty] recv={s} get -> {s}\n", .{ identity, if (idx_ret) |r| r.name else "<null>" });
        return idx_ret;
    }
    if (call_expr.* != .Call) return null;
    // A direct constructor expression names its own type, and the guards inside
    // decline shadowing locals and functions.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_CTOR_RET") orelse "1", "0")) {
        if (try ctorInitTypeRef(b, call_expr)) |ctor_ty| return ctor_ty;
    }
    const call = call_expr.Call;
    if (call.is_infix and call.args.len == 2 and call.callee.* == .Path and
        call.callee.Path.segments.len == 1)
    {
        var member_callee = Expr{ .Member = .{
            .receiver = &call.args[0],
            .name = call.callee.Path.segments[0],
            .safe = false,
            .span = call.span,
        } };
        var member_call = Expr{ .Call = .{
            .callee = &member_callee,
            .args = call.args[1..],
            .arg_names = call.arg_names[1..],
            .type_args = call.type_args,
            .is_infix = false,
            .span = call.span,
        } };
        return staticCallReturnTypeRef(b, &member_call);
    }
    var shape_set = try buildStaticReturnArgShapes(b, call.args, call.arg_names);
    defer shape_set.deinit(b.allocator);
    const owned_type_param_bounds = try b.typeParamBoundsSlice();
    defer if (owned_type_param_bounds) |bounds| b.allocator.free(bounds);

    var receiver: ?ir.TypeRef = null;
    defer if (receiver) |*ty| ty.deinit(b.allocator);
    var target: FuncId = undefined;
    switch (call.callee.*) {
        .Path => |path| {
            if (path.segments.len != 1) return null;
            const name = path.segments[0];
            const own_init = expr.init_self_name != null and
                std.mem.eql(u8, expr.init_self_name.?, name.name);
            if (!own_init and (b.resolve(name.name) != null or b.isLocalFn(name.name) or
                b.knowsOuter(name.name)))
            {
                if (bareRetTraceFor(b, name.name)) std.debug.print("[bareret] {s} shadowed local={} localfn={} outer={}\n", .{
                    name.name,
                    b.resolve(name.name) != null,
                    b.isLocalFn(name.name),
                    b.knowsOuter(name.name),
                });
                return null;
            }
            // A name the enclosing receiver declares is a member call written
            // without `this.`, which the implicit-receiver resolution below answers.
            const member_of_enclosing = enclosingHasMemberNamed(b, name.name);
            const res = if (member_of_enclosing)
                ir.Module.Resolution{ .target = null, .confidence = .deferred, .emit_form = .Call }
            else
                try b.module.resolveCall(
                    b.allocator,
                    name.name,
                    b.self_package,
                    name.span.file,
                    shape_set.shapes,
                    lastArgIsLambda(call.args),
                    resolveCtxFor(
                        b,
                        name.name,
                        call.type_args,
                        null,
                        owned_type_param_bounds orelse &.{},
                    ),
                );
            defer b.allocator.free(res.candidate_set);
            var from_implicit_receiver = false;
            // A top-level pick made under a lambda's conservative receiver is not
            // evidence, and neither is no pick, but the implicit receiver may still
            // prove one. An inline splice window is a receiver context too, its
            // receiver living in the window hint rather than `recvTy`, and a
            // non-exact pick there poisons every chained call after it.
            const top_level_usable = res.target != null and
                (res.confidence == .exact or
                    (b.recvTy() == null and b.spliceRecvTy() == null and
                        !b.isParamThunk()));
            // A refused top-level pick is still the only answer when the name has
            // exactly one declaration program-wide and no enclosing receiver
            // declares a member of it. Used only where the receiver walk finds none.
            const sole_global: ?FuncId = blk_sole: {
                if (std.mem.eql(u8, runtime.envOnce("KLIO_SOLE_GLOBAL") orelse "1", "0")) break :blk_sole null;
                if (top_level_usable) break :blk_sole null;
                const t = res.target orelse break :blk_sole null;
                if (b.module.funcsBySimpleName(name.name).len != 1) break :blk_sole null;
                if (enclosingHasMemberNamed(b, name.name)) break :blk_sole null;
                const f = b.module.funcById(t) orelse break :blk_sole null;
                if (f.kind != .plain) break :blk_sole null;
                break :blk_sole t;
            };
            // When every plain declaration of the name agrees on a concrete return
            // head, that head is authoritative without picking a fid, the receiver
            // context blocking the pick not changing what any pick returns. Args are
            // kept only when every declaration's full return matches.
            const agreed_return: ?ir.TypeRef = blk_agree: {
                const atrace = if (runtime.envOnce("KLIO_AGREED_TRACE")) |w|
                    (std.mem.eql(u8, w, "*") or std.mem.eql(u8, w, name.name))
                else
                    false;
                if (std.mem.eql(u8, runtime.envOnce("KLIO_AGREED_RET") orelse "1", "0")) break :blk_agree null;
                if (top_level_usable) {
                    if (atrace) std.debug.print("[agreed] {s}: top_level_usable\n", .{name.name});
                    break :blk_agree null;
                }
                if (enclosingHasMemberNamed(b, name.name)) {
                    if (atrace) std.debug.print("[agreed] {s}: enclosing has member\n", .{name.name});
                    break :blk_agree null;
                }
                // A name any class declares as a member may be a receiver member
                // here, which the agreed top-level return would type wrongly.
                if (b.module.registry.class_member_names.contains(name.name)) {
                    if (atrace) std.debug.print("[agreed] {s}: some class declares this member name\n", .{name.name});
                    break :blk_agree null;
                }
                const fids = b.module.funcsBySimpleName(name.name);
                if (fids.len < 2) {
                    if (atrace) std.debug.print("[agreed] {s}: {d} declaration(s)\n", .{ name.name, fids.len });
                    break :blk_agree null;
                }
                var seen: ?ir.TypeRef = null;
                var args_agree = true;
                for (fids) |fid2| {
                    const f2 = b.module.funcById(fid2) orelse break :blk_agree null;
                    if (f2.kind != .plain) continue;
                    if (seen) |prev| {
                        if (!std.mem.eql(u8, prev.name, f2.return_ty.name)) break :blk_agree null;
                        if (prev.args.len != f2.return_ty.args.len) args_agree = false;
                    } else seen = f2.return_ty;
                }
                var ret = seen orelse break :blk_agree null;
                const h = typeHead(std.mem.trimEnd(u8, ret.name, "?"));
                if (h.len == 0 or std.mem.eql(u8, h, "Unit") or
                    (h.len <= 2 and std.ascii.isUpper(h[0])) or b.isTypeParam(h))
                    break :blk_agree null;
                if (staticTypeClassId(b, ret) == null) break :blk_agree null;
                if (!args_agree) ret.args = &.{};
                break :blk_agree ret;
            };
            if (runtime.envOnce("KLIO_SCRT_TRACE")) |w3| {
                if (std.mem.eql(u8, w3, name.name)) {
                    std.debug.print("[scrt-path] {s} usable={} target={?} conf={s}\n", .{ name.name, top_level_usable, if (res.target) |t| t.int() else null, @tagName(res.confidence) });
                }
            }
            target = (if (top_level_usable) res.target else null) orelse blk: {
                from_implicit_receiver = true;
                // A bare call in a receiver context is usually a member of the
                // implicit receiver written without `this.`.
                const bt = bareRetTraceFor(b, name.name);
                // Inside a plain method body the implicit receiver is the owner class
                // itself; the head channels cover only extension receivers and narrows.
                const head_name = bareStaticRecvHead(b) orelse b.ownerClass() orelse {
                    if (bt) std.debug.print("[bareret] {s} no recv head\n", .{name.name});
                    break :blk sole_global orelse {
                        if (agreed_return) |ar| {
                            if (runtime.envOnce("KLIO_SCRT_TRACE")) |w2| {
                                if (std.mem.eql(u8, w2, name.name)) std.debug.print("[scrt-agreed] {s} ty={s}\n", .{ name.name, ar.name });
                            }
                            return try ar.clone(b.allocator);
                        }
                        return null;
                    };
                };
                const recv_ref = if (b.spliceHintActive())
                    // The window's actual receiver type wins over the declared one,
                    // instantiating the bare call's return where the declared type
                    // leaves the callee's own parameter in it.
                    (if (b.spliceRecvTyRef()) |art|
                        try art.clone(b.allocator)
                    else if (b.spliceHintRecvRef()) |rt|
                        try decl_mod.loweredTypeRef(b.allocator, &rt, true)
                    else
                        null)
                else
                    (if (b.recvTypeRef()) |declared| try declared.clone(b.allocator) else null);
                var bare_recv = recv_ref orelse ir.TypeRef{
                    .name = try b.allocator.dupe(u8, head_name),
                    .nullable = false,
                    .args = &.{},
                };
                if (!std.mem.eql(u8, typeHead(bare_recv.name), head_name)) {
                    // A window receiver whose head differs from the declared one is
                    // usually its subtype, so project it and keep the type arguments;
                    // a bare head star-fills the return and untypes every spliced
                    // selector's parameter after it.
                    const projected: ?ir.TypeRef = blk_pj: {
                        const head_cid = (if (std.mem.findScalar(u8, head_name, '.') != null)
                            b.module.classIdByFqn(head_name)
                        else
                            b.module.uniqueClassIdBySimpleName(typeHead(head_name))) orelse break :blk_pj null;
                        // `projectTypeToClass` borrows from its input under arena
                        // semantics and may return the input, so project in a scratch
                        // arena and clone out before the input dies.
                        var pj_scratch = std.heap.ArenaAllocator.init(b.allocator);
                        defer pj_scratch.deinit();
                        const p = (try b.module.projectTypeToClass(pj_scratch.allocator(), bare_recv, head_cid)) orelse break :blk_pj null;
                        break :blk_pj try p.clone(b.allocator);
                    };
                    bare_recv.deinit(b.allocator);
                    bare_recv = projected orelse ir.TypeRef{
                        .name = try b.allocator.dupe(u8, head_name),
                        .nullable = false,
                        .args = &.{},
                    };
                }
                // The bare receiver may be a type parameter, so resolve against its
                // full declared bound and let instantiation carry the bound's type
                // arguments, the substitution the `.Member` arm applies.
                if (!std.mem.eql(u8, runtime.envOnce("KLIO_TP_RECV") orelse "1", "0")) {
                    const cur_head = typeHead(std.mem.trimEnd(u8, bare_recv.name, "?"));
                    const head_names_class = (if (std.mem.findScalar(u8, cur_head, '.') != null)
                        b.module.classIdByFqn(cur_head)
                    else
                        b.module.uniqueClassIdBySimpleName(cur_head)) != null;
                    if (!head_names_class) {
                        if (b.typeParamBoundRef(cur_head)) |bref| {
                            bare_recv.deinit(b.allocator);
                            bare_recv = try bref.clone(b.allocator);
                            try stripUseSiteProjections(b.allocator, &bare_recv);
                        }
                    }
                }
                receiver = bare_recv;
                var ident = std.mem.trimEnd(u8, bare_recv.name, "?");
                if (std.mem.findScalar(u8, ident, '<')) |lt| ident = ident[0..lt];
                const bare_head = typeHead(ident);
                const owner = (if (std.mem.findScalar(u8, ident, '.') != null)
                    b.module.classIdByFqn(ident)
                else
                    b.module.classIdIndexed(bare_head, b.self_package, name.span.file) orelse
                        b.module.classId(bare_head)) orelse {
                    // A receiver head with no class id still has extensions;
                    // resolution over them never needed the class.
                    if (try bareExtensionTarget(b, name, bare_recv, shape_set.shapes, owned_type_param_bounds)) |t| {
                        if (bt) std.debug.print("[bareret] {s} on {s} ext target\n", .{ name.name, ident });
                        break :blk t;
                    }
                    if (bt) std.debug.print("[bareret] {s} no owner for {s}\n", .{ name.name, ident });
                    break :blk sole_global orelse {
                        if (agreed_return) |ar| {
                            if (runtime.envOnce("KLIO_SCRT_TRACE")) |w2| {
                                if (std.mem.eql(u8, w2, name.name)) std.debug.print("[scrt-agreed] {s} ty={s}\n", .{ name.name, ar.name });
                            }
                            return try ar.clone(b.allocator);
                        }
                        return null;
                    };
                };
                // The lexical owner makes private members visible to their own
                // class's bodies.
                const bare_lexical: ?ir.ClassId = if (b.ownerClass()) |oc|
                    (if (std.mem.findScalar(u8, oc, '.') != null)
                        b.module.classIdByFqn(oc)
                    else
                        b.module.classIdIndexed(oc, b.self_package, name.span.file) orelse
                            b.module.classId(oc))
                else
                    null;
                const bare_resolved = b.module.resolveMemberCall(
                    owner,
                    name.name,
                    shape_set.shapes,
                    .{
                        .caller_file = name.span.file,
                        .lexical_owner = bare_lexical,
                        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
                        .receiver_type = bare_recv,
                    },
                );
                if (bt) std.debug.print("[bareret] {s} on {s} target={s} owner_fqn={s} applicable={} stub={} fn={s}\n", .{
                    name.name,
                    ident,
                    if (bare_resolved.target != null) "yes" else "no",
                    b.module.classFqnById(owner) orelse "-",
                    bare_resolved.applicable,
                    if (owner.int() < b.module.classes.items.len) b.module.classes.items[owner.int()].is_stub else false,
                    build.currentRealFn() orelse "-",
                });
                if (bt and bare_resolved.target == null) {
                    std.debug.print("[bareret]   tower_n={d} encl={s} recv={s}\n", .{
                        b.implicit_receiver_tower.items.len,
                        b.enclosingRecvTy() orelse "-",
                        b.recvTy() orelse "-",
                    });
                    for (b.implicit_receiver_tower.items) |entry| {
                        std.debug.print("[bareret]   tower entry head={s}\n", .{entry.head});
                    }
                }
                if (bare_resolved.target) |member_target| break :blk member_target;
                // No member serves it and none is even applicable, so a bare call in
                // a receiver context may be an extension of the implicit receiver.
                // Members were tried first, as Kotlin orders them, and an applicable
                // but unproven member still wins the deferral.
                if (!bare_resolved.applicable) {
                    if (try bareExtensionTarget(b, name, bare_recv, shape_set.shapes, owned_type_param_bounds)) |t| {
                        if (bt) std.debug.print("[bareret] {s} on {s} ext target\n", .{ name.name, ident });
                        break :blk t;
                    }
                }
                // Same-class forward reference: while a class's own bodies lower its
                // method list is incomplete, so the pre-pass AST registry answers the
                // declared return.
                if (bare_resolved.target == null) {
                    if (inline_state.exprBodyMemberAst(bare_head, name.name, call.args.len)) |fa| {
                        if (fa.return_type) |*rt| {
                            const fwd = try loweredOwnedLocalTypeRef(b, rt);
                            if (bt) std.debug.print("[bareret] {s} on {s} ast-declared return={s}\n", .{ name.name, ident, fwd.name });
                            return fwd;
                        }
                    }
                    // The outer implicit receivers: a bare call inside a receiver
                    // lambda resolves against the enclosing extension's receiver when
                    // the inner one misses.
                    for (b.implicit_receiver_tower.items) |entry| {
                        var outer_head = std.mem.trimEnd(u8, entry.head, "?");
                        if (std.mem.findScalar(u8, outer_head, '<')) |lt| outer_head = outer_head[0..lt];
                        if (std.mem.eql(u8, typeHead(outer_head), bare_head)) continue;
                        const outer_cid = (if (std.mem.findScalar(u8, outer_head, '.') != null)
                            b.module.classIdByFqn(outer_head)
                        else
                            b.module.uniqueClassIdBySimpleName(typeHead(outer_head))) orelse continue;
                        var outer_recv = ir.TypeRef{
                            .name = try b.allocator.dupe(u8, entry.head),
                            .nullable = false,
                            .args = &.{},
                        };
                        const outer_resolved = b.module.resolveMemberCall(
                            outer_cid,
                            name.name,
                            shape_set.shapes,
                            .{
                                .caller_file = name.span.file,
                                .lexical_owner = null,
                                .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
                                .receiver_type = outer_recv,
                            },
                        );
                        if (outer_resolved.target) |t| {
                            if (bt) std.debug.print("[bareret] {s} tower {s} target\n", .{ name.name, outer_head });
                            if (receiver) |*old| old.deinit(b.allocator);
                            receiver = outer_recv;
                            break :blk t;
                        }
                        if (try bareExtensionTarget(b, name, outer_recv, shape_set.shapes, owned_type_param_bounds)) |t| {
                            if (bt) std.debug.print("[bareret] {s} tower {s} ext target\n", .{ name.name, outer_head });
                            if (receiver) |*old| old.deinit(b.allocator);
                            receiver = outer_recv;
                            break :blk t;
                        }
                        outer_recv.deinit(b.allocator);
                    }
                }
                break :blk sole_global orelse {
                        if (agreed_return) |ar| return try ar.clone(b.allocator);
                        return null;
                    };
            };
            // A plain lambda capturing its lexical class receiver makes bare-call
            // emission conservative, but an unknown receiver lambda still cannot lend
            // its target's return type to another proof.
            _ = &from_implicit_receiver;
        },
        .Member => |member| {
            const mt = bareRetTraceFor(b, member.name.name);
            // The full chain, not just the declared-type probe: a local whose only
            // type comes from its own initializer is invisible to the lazy answer.
            receiver = try recvChainTypeRef(b, member.receiver);
            if (receiver == null) {
                if (mt) {
                    var loc_buf: [256]u8 = undefined;
                    const cs = member.name.span;
                    const loc: []const u8 = lblk: {
                        if (span.active_map) |m| {
                            if (m.getChecked(cs.file)) |sf| {
                                const lc = sf.lineCol(cs.start);
                                const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |i| sf.path[i + 1 ..] else sf.path;
                                break :lblk std.fmt.bufPrint(&loc_buf, "{s}:{d}", .{ base, lc.line }) catch "?";
                            }
                        }
                        break :lblk "?";
                    };
                    std.debug.print("[bareret] .{s} no receiver type at={s} fn={s}\n", .{ member.name.name, loc, build.currentRealFn() orelse "-" });
                }
                return null;
            }
            var identity = std.mem.trimEnd(u8, receiver.?.name, "?");
            if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
            var head = typeHead(identity);
            // `invoke` on a function-typed receiver returns the function type's
            // declared return, the last type argument of the lowered `FunctionN`
            // head, alias-resolved.
            if (std.mem.eql(u8, member.name.name, "invoke")) {
                var fn_ref: ?ir.TypeRef = null;
                defer if (fn_ref) |*t| t.deinit(b.allocator);
                var fn_ty: *const ir.TypeRef = &receiver.?;
                if (!std.mem.startsWith(u8, typeHead(fn_ty.name), "Function")) {
                    var alias_arena = std.heap.ArenaAllocator.init(b.allocator);
                    defer alias_arena.deinit();
                    const resolved_alias = b.module.resolveTypeAliasAt(
                        alias_arena.allocator(),
                        receiver.?,
                        null,
                        b.self_package,
                    ) catch receiver.?;
                    if (std.mem.startsWith(u8, typeHead(resolved_alias.name), "Function")) {
                        fn_ref = try resolved_alias.clone(b.allocator);
                        fn_ty = &fn_ref.?;
                    }
                }
                if (std.mem.startsWith(u8, typeHead(fn_ty.name), "Function") and fn_ty.args.len != 0) {
                    var out = try fn_ty.args[fn_ty.args.len - 1].clone(b.allocator);
                    if (member.safe or receiver.?.nullable) out.nullable = true;
                    if (mt) std.debug.print("[bareret] .invoke fn-return={s}\n", .{out.name});
                    return out;
                }
            }
            var owner_id = if (std.mem.findScalar(u8, identity, '.') != null)
                b.module.classIdByFqn(identity)
            else
                b.module.uniqueClassIdBySimpleName(head);
            // A receiver typed by a type parameter names no class, so Kotlin resolves
            // the call against its declared upper bound, whose full form carries the
            // type arguments instantiation needs.
            if (owner_id == null and
                !std.mem.eql(u8, runtime.envOnce("KLIO_TP_RECV") orelse "1", "0"))
            {
                if (b.typeParamBoundRef(head)) |bref| {
                    receiver.?.deinit(b.allocator);
                    receiver = try bref.clone(b.allocator);
                    // A use-site projection in the bound would need capture conversion
                    // the engine does not model. For a return type the captured
                    // argument behaves as the plain parameter, and a projected one
                    // surviving into the result is refused by later guards anyway.
                    try stripUseSiteProjections(b.allocator, &receiver.?);
                    identity = std.mem.trimEnd(u8, receiver.?.name, "?");
                    if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
                    head = typeHead(identity);
                    owner_id = if (std.mem.findScalar(u8, identity, '.') != null)
                        b.module.classIdByFqn(identity)
                    else
                        b.module.uniqueClassIdBySimpleName(head);
                }
            }
            const recv_ty = receiver.?;

            var resolved_target: ?FuncId = null;
            var member_applicable = false;
            if (owner_id) |owner| {
                const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
                    (if (std.mem.findScalar(u8, owner_name, '.') != null)
                        b.module.classIdByFqn(owner_name)
                    else
                        (b.module.classIdIndexed(
                            owner_name,
                            b.self_package,
                            member.name.span.file,
                        ) orelse b.module.classId(owner_name)))
                else
                    null;
                const resolved = b.module.resolveMemberCall(
                    owner,
                    member.name.name,
                    shape_set.shapes,
                    .{
                        .caller_file = member.name.span.file,
                        .lexical_owner = lexical_owner,
                        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
                        .receiver_type = recv_ty,
                    },
                );
                member_applicable = resolved.applicable;
                // A deferred resolution that still names one declaration is enough
                // for a return type; an override may only narrow it.
                resolved_target = resolved.target;
            }
                // Same-class forward references: while a class's own bodies lower its
                // IR method list is incomplete, so the pre-pass AST registry answers
                // directly, a declared annotation as-is and an expression body by
                // derivation.
            if (resolved_target == null) {
                // A member extension registers under its declaring class, not its
                // receiver head, so consult the lexical owner too and let an
                // un-annotated expression body derive at its call sites.
                const fa_hit = inline_state.exprBodyMemberAst(head, member.name.name, memberArgCount(call_expr)) orelse blk_fa: {
                    const ow2 = b.ownerClass() orelse {
                        if (mt) std.debug.print("[bareret] .{s} fa: no owner\n", .{member.name.name});
                        break :blk_fa null;
                    };
                    const cand = inline_state.exprBodyMemberAst(ow2, member.name.name, memberArgCount(call_expr)) orelse {
                        if (mt) std.debug.print("[bareret] .{s} fa: miss (owner={s} argc={d})\n", .{ member.name.name, ow2, memberArgCount(call_expr) });
                        break :blk_fa null;
                    };
                    // Only a member extension whose declared receiver serves this
                    // head qualifies; a plain same-named member is a different callee.
                    const rt2 = cand.receiver_type orelse break :blk_fa null;
                    const dh2 = typeHead(std.mem.trimEnd(u8, rt2.name.name, "?"));
                    if (!(std.mem.eql(u8, dh2, head) or b.module.classIsOrExtends(head, dh2))) break :blk_fa null;
                    break :blk_fa cand;
                };
                if (fa_hit) |fa| {
                    if (fa.return_type) |*rt| {
                        var out = try loweredOwnedLocalTypeRef(b, rt);
                        if (member.safe) out.nullable = true;
                        // A bare type-parameter return resolves in the declaring
                        // scope, not the caller's: a fn-level `<T : Bound>` on the
                        // declaration, else the declaring class's. Kotlin types the
                        // call at that upper bound.
                        if (bareTypeParamHead(out.name)) resolve_bound: {
                            const h2 = typeHead(std.mem.trimEnd(u8, out.name, "?"));
                            var bound: ?[]const u8 = null;
                            var fn_level = false;
                            for (fa.type_params) |*tp2| {
                                if (!std.mem.eql(u8, tp2.name.name, h2)) continue;
                                fn_level = true;
                                if (tp2.upper_bound) |*ub| bound = ub.name.name;
                                break;
                            }
                            if (fn_level and bound == null) break :resolve_bound;
                            if (bound == null) {
                                const declaring: []const u8 = if (inline_state.exprBodyMemberAst(head, member.name.name, memberArgCount(call_expr)) != null)
                                    head
                                else
                                    (b.ownerClass() orelse break :resolve_bound);
                                const cbs = b.module.registry.class_type_param_bounds.get(declaring) orelse break :resolve_bound;
                                for (cbs) |cb| {
                                    if (std.mem.eql(u8, cb.param, h2)) {
                                        bound = cb.bound;
                                        break;
                                    }
                                }
                            }
                            const bd = bound orelse break :resolve_bound;
                            const bh = typeHead(std.mem.trimEnd(u8, bd, "?"));
                            if (bh.len <= 2 or std.mem.eql(u8, bh, "Any") or
                                std.mem.eql(u8, bh, "kotlin.Any") or b.isTypeParam(bh) or
                                ir.parseClassTypeParamIdentity(bh) != null) break :resolve_bound;
                            const keep_nullable = out.nullable;
                            out.deinit(b.allocator);
                            out = .{
                                .name = try b.allocator.dupe(u8, std.mem.trimEnd(u8, bd, "?")),
                                .nullable = keep_nullable,
                                .args = &.{},
                            };
                        }
                        if (mt) std.debug.print("[bareret] .{s} on {s} ast-declared return={s}\n", .{ member.name.name, head, out.name });
                        return out;
                    }
                    if (fa.body) |*fbody| {
                        if (fbody.* == .Expr and expr.od_depth < 3) {
                            expr.od_depth += 1;
                            defer expr.od_depth -= 1;
                            var nb = try FuncBuilder.init(b.allocator, b.module);
    nb.census_quiet = true;
                            defer nb.deinit();
                            nb.setOwnerClass(head);
                            nb.setRecvTy(head);
                            // The owner's ctor properties are the body's lexical
                            // bindings.
                            if (b.module.uniqueClassIdBySimpleName(head)) |ocid| {
                                if (ocid.int() < b.module.classes.items.len) {
                                    for (b.module.classes.items[ocid.int()].primary_params) |*pp| {
                                        try nb.setLocalDeclTypeOwned(pp.name, try pp.ty.clone(b.allocator));
                                        if (pp.ty.nullable) try nb.setLocalDeclNullable(pp.name);
                                    }
                                }
                            }
                            for (fa.params) |*ap| {
                                try nb.setLocalDeclTypeOwned(ap.name.name, try loweredOwnedLocalTypeRef(&nb, &ap.ty));
                                if (ap.ty.nullable) try nb.setLocalDeclNullable(ap.name.name);
                            }
                            if (try staticExprTypeRef(&nb, &fbody.Expr)) |derived| {
                                var out = derived;
                                if (member.safe) out.nullable = true;
                                if (mt) std.debug.print("[bareret] .{s} on {s} ast-derived return={s}\n", .{ member.name.name, head, out.name });
                                return out;
                            }
                        }
                    }
                }
                if (member_applicable) {
                    if (mt) std.debug.print("[bareret] .{s} on {s} member applicable but deferred\n", .{ member.name.name, head });
                    return null;
                }
                const implicit_owners = try b.collectImplicitReceiverTower(
                    b.allocator,
                    eagerLambdaRecvHead(b),
                );
                defer b.allocator.free(implicit_owners);
                resolved_target = b.module.resolveExtensionCall(
                    member.name.name,
                    recv_ty,
                    shape_set.shapes,
                    .{
                        .caller_file = member.name.span.file,
                        .caller_package = b.module.packageOfFile(member.name.span.file) orelse b.self_package,
                        .implicit_dispatch_owners = implicit_owners,
                        .lexical_owner = b.ownerClass(),
                        .call_name = member.name.name,
                        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
                    },
                ).target;
            }
            target = resolved_target orelse {
                if (mt) std.debug.print("[bareret] .{s} on {s} no target (recv_ty={s} args={d} nshapes={d})\n", .{ member.name.name, head, recv_ty.name, recv_ty.args.len, shape_set.shapes.len });
                return null;
            };
            if (mt) std.debug.print("[bareret] .{s} on {s} target ok fqn={s}\n", .{ member.name.name, head, if (b.module.funcById(target)) |tf| tf.fqn else "?" });
        },
        else => return null,
    }

    try enrichLambdaArgShapes(b, target, call.args, &shape_set);
    try enrichCallableRefArgShapes(b, target, call.args, &shape_set);
    const explicit = try b.allocator.alloc(ir.TypeRef, call.type_args.len);
    defer {
        for (explicit) |*ty| ty.deinit(b.allocator);
        b.allocator.free(explicit);
    }
    for (call.type_args, explicit) |*ty, *out| {
        out.* = try decl_mod.loweredTypeRef(b.allocator, ty, true);
    }
    var dispatch_receiver = try staticDispatchReceiverTypeRef(
        b,
        target,
        receiver,
        call.span.file,
    );
    defer if (dispatch_receiver) |*ty| ty.deinit(b.allocator);
    var inferred = try b.module.instantiatedCallReturnTypeScoped(
        b.allocator,
        target,
        receiver,
        dispatch_receiver,
        shape_set.shapes,
        explicit,
        ownerParamsInScope(b, target),
    );
    if (runtime.envOnce("KLIO_LAMRET_TRACE") != null and call.callee.* == .Path) {
        std.debug.print("[lamret-inst] callee={s} inferred={s}\n", .{
            call.callee.Path.segments[0].name,
            if (inferred) |t| t.name else "<null>",
        });
    }
    if (runtime.envOnce("KLIO_SCRT_TRACE")) |w| {
        if (call.callee.* == .Path and call.callee.Path.segments.len == 1 and
            std.mem.eql(u8, w, call.callee.Path.segments[0].name))
        {
            const tf0 = b.module.funcById(target);
            std.debug.print("[scrt-target] {s} fid={d} fqn={s} inferred={s}\n", .{
                w,
                target.int(),
                if (tf0) |tf| tf.fqn else "?",
                if (inferred) |t| t.name else "-",
            });
        }
    }
    // A scalar overload family answers a different type per argument type, so a
    // target picked without proving the argument's type is a guess, and a wrongly
    // widened result drops a local extension as inapplicable. Withdraw the claim.
    if (inferred != null and try scalarOverloadUnproven(b, call, target)) {
        inferred.?.deinit(b.allocator);
        inferred = null;
    }
    // Invoke convention: the pick is a fn-typed property's accessor, with zero value
    // params, while the call supplies arguments, so the call's type is the fn type's
    // declared return. The zero-params-with-args guard discriminates it.
    if (inferred == null) {
        if (b.module.funcById(target)) |tf| {
            const has_this = tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this");
            const value_params = tf.params.len - @intFromBool(has_this);
            const rt = &tf.return_ty;
            if (value_params == 0 and call.args.len != 0 and
                std.mem.startsWith(u8, typeHead(rt.name), "Function") and rt.args.len != 0)
            {
                var hi = rt.args.len;
                while (hi > 0 and rt.args[hi - 1].name.len != 0 and
                    rt.args[hi - 1].name[0] == '#') hi -= 1;
                if (hi != 0) {
                    inferred = try rt.args[hi - 1].clone(b.allocator);
                }
            }
        }
    }
    // Declaration order must not decide whether a caller's local types: when the
    // target is an un-annotated expression body whose decl pass has not run, derive
    // the return from the registered AST in the target's own class context.
    if (inferred == null and expr.od_depth < 3) {
        expr.od_depth += 1;
        defer expr.od_depth -= 1;
        if (b.module.decl_sigs.get(target.int())) |dsg| {
            if (dsg.enclosing_class) |oid| {
                if (oid.int() < b.module.classes.items.len) {
                    const oc = &b.module.classes.items[oid.int()];
                    if (b.module.funcById(target)) |tf| {
                        const has_this = tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this");
                        const nparams = tf.params.len - @intFromBool(has_this);
                        if (inline_state.exprBodyMemberAst(oc.name, tf.name, nparams)) |fa| {
                            if (fa.body) |*fbody| {
                                if (fbody.* == .Expr) {
                                    var nb = try FuncBuilder.init(b.allocator, b.module);
    nb.census_quiet = true;
                                    defer nb.deinit();
                                    nb.setOwnerClass(oc.name);
                                    nb.setRecvTy(oc.name);
                                    // The owner's ctor properties are the body's
                                    // lexical bindings, so seed their declared types.
                                    for (oc.primary_params) |*pp| {
                                        try nb.setLocalDeclTypeOwned(pp.name, try pp.ty.clone(b.allocator));
                                        if (pp.ty.nullable) try nb.setLocalDeclNullable(pp.name);
                                    }
                                    for (fa.params) |*ap| {
                                        try nb.setLocalDeclTypeOwned(ap.name.name, try loweredOwnedLocalTypeRef(&nb, &ap.ty));
                                        if (ap.ty.nullable) try nb.setLocalDeclNullable(ap.name.name);
                                    }
                                    inferred = try staticExprTypeRef(&nb, &fbody.Expr);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (inferred != null and
        call.callee.* == .Member and call.callee.Member.safe)
    {
        inferred.?.nullable = true;
    }
    if (call.callee.* == .Path and call.callee.Path.segments.len == 1 and
        bareRetTraceFor(b, call.callee.Path.segments[0].name))
    {
        std.debug.print("[bareret] {s} return={s} args={d} arg0={s} fn={s}\n", .{
            call.callee.Path.segments[0].name,
            if (inferred) |i| i.name else "<null>",
            if (inferred) |i| i.args.len else 0,
            if (inferred) |i| (if (i.args.len != 0) i.args[0].name else "-") else "-",
            build.currentRealFn() orelse "-",
        });
    }
    if (call.callee.* == .Member and bareRetTraceFor(b, call.callee.Member.name.name)) {
        std.debug.print("[bareret] .{s} return={s} rargs={d} fn={s}\n", .{
            call.callee.Member.name.name,
            if (inferred) |i| i.name else "<null>",
            if (inferred) |i| i.args.len else 0,
            build.currentRealFn() orelse "-",
        });
    }
    return inferred;
}

/// `KLIO_BARERET=<name>` or `*` traces why a bare call does or does not lend its
/// return type to the local it initializes.
fn bareRetTraceFor(b: *const FuncBuilder, name: []const u8) bool {
    _ = b;
    const want = runtime.envOnce("KLIO_BARERET") orelse return false;
    return std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, name);
}

pub const StaticReturnArgShapes = struct {
    shapes: []applicability.ArgShape,
    inferred: []?ir.TypeRef,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.inferred) |*ty| {
            if (ty.*) |*owned| owned.deinit(allocator);
        }
        allocator.free(self.inferred);
        allocator.free(self.shapes);
    }
};

/// Static call shapes enriched by recursively resolved call return types. Unlike
/// the eager type-head channel, every inferred entry comes from a unique
/// declaration identity and can participate in exact overload selection.
/// `enrichLambdaReturnShapes` adds lambda return types: when the target's declared
/// parameter is a `Function{N}` whose return names a bare type parameter and whose
/// value-parameter types are concrete, an unannotated lambda literal's single-block
/// tail is derived in a scratch builder under those types and the shape gains the
/// instantiated function type. Return-channel evidence only.
/// `binaryResultHead` is the result-type head of a primitive-operand binary
/// arithmetic op under Kotlin's numeric promotion: Byte and Short promote to Int,
/// the wider of the two otherwise, unsigned only same-kind, `String + x` is String.
fn primitiveBinResultHead(b: *FuncBuilder, lhs_head: []const u8, bin: anytype) ?[]const u8 {
    switch (bin.op) {
        .Add, .Sub, .Mul, .Div, .Rem => {},
        else => return null,
    }
    if (std.mem.eql(u8, lhs_head, "String"))
        return if (bin.op == .Add) "String" else null;
    if (std.mem.eql(u8, lhs_head, "Char")) {
        const rh = binOperandHead(b, bin.rhs) orelse return null;
        // kotlinc's Char arithmetic: Char - Char = Int; Char +/- Int = Char.
        if (bin.op == .Sub and std.mem.eql(u8, rh, "Char")) return "Int";
        if ((bin.op == .Add or bin.op == .Sub) and std.mem.eql(u8, rh, "Int")) return "Char";
        return null;
    }
    const rhs_head = binOperandHead(b, bin.rhs) orelse return null;
    return numericPromoteHead(lhs_head, rhs_head);
}

fn binOperandHead(b: *FuncBuilder, e: *const Expr) ?[]const u8 {
    switch (e.*) {
        .CharLit => return "Char",
        .IntLit => |il| return switch (il.kind) {
            .Long => "Long",
            .UInt => "UInt",
            .ULong => "ULong",
            else => "Int",
        },
        .FloatLit => |fl| return switch (fl.kind) {
            .Float => "Float",
            .Double => "Double",
        },
        else => {},
    }
    if (argDeclTypeRefLazy(b, e)) |ty| return typeHead(std.mem.trimEnd(u8, ty.name, "?"));
    return null;
}

fn numericRank(head: []const u8) ?u8 {
    if (std.mem.eql(u8, head, "Byte") or std.mem.eql(u8, head, "Short") or
        std.mem.eql(u8, head, "Int")) return 2;
    if (std.mem.eql(u8, head, "Long")) return 3;
    if (std.mem.eql(u8, head, "Float")) return 4;
    if (std.mem.eql(u8, head, "Double")) return 5;
    return null;
}

fn numericPromoteHead(a: []const u8, c: []const u8) ?[]const u8 {
    const unsigned_a = a.len > 1 and a[0] == 'U' and numericRank(a[1..]) != null;
    const unsigned_c = c.len > 1 and c[0] == 'U' and numericRank(c[1..]) != null;
    if (unsigned_a or unsigned_c) {
        return if (std.mem.eql(u8, a, c)) a else null;
    }
    const ra = numericRank(a) orelse return null;
    const rc = numericRank(c) orelse return null;
    const r = @max(ra, rc);
    return switch (r) {
        2 => "Int",
        3 => "Long",
        4 => "Float",
        else => "Double",
    };
}

fn enrichLambdaArgShapes(
    b: *FuncBuilder,
    target: FuncId,
    args: []const Expr,
    shape_set: *StaticReturnArgShapes,
) Allocator.Error!void {
    if (expr.od_depth >= 3) return;
    if (std.mem.eql(u8, runtime.envOnce("KLIO_LAMBDA_RET") orelse "1", "0")) return;
    const tf = b.module.funcById(target) orelse return;
    const has_this = tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this");
    const first = @intFromBool(has_this);
    for (args, 0..) |*arg, i| {
        if (arg.* != .Lambda) continue;
        if (shape_set.shapes[i].ty != null or shape_set.inferred[i] != null) continue;
        const pi = first + i;
        if (pi >= tf.params.len) break;
        const pty = tf.params[pi].ty;
        if (!std.mem.startsWith(u8, typeHead(pty.name), "Function") or pty.args.len == 0) continue;
        const ret = pty.args[pty.args.len - 1];
        // Only a bare type-parameter return needs the body, and only concrete
        // value-parameter types can seed it.
        if (staticTypeClassId(b, ret) != null) continue;
        var params_concrete = true;
        for (pty.args[0 .. pty.args.len - 1]) |pa| {
            if (staticTypeClassId(b, pa) == null) {
                params_concrete = false;
                break;
            }
        }
        if (!params_concrete) continue;
        const lam = arg.Lambda;
        const stmts = lam.body.stmts;
        if (stmts.len == 0 or stmts[stmts.len - 1] != .Expr) continue;
        const tail = &stmts[stmts.len - 1].Expr;
        // Only self-contained tail kinds derive: a derived call-tail binding narrows
        // generic instantiations in ways that disprove more than the typed local buys.
        switch (tail.*) {
            .Path, .Binary, .StringTemplate, .IntLit, .FloatLit, .BoolLit, .CharLit => {},
            else => continue,
        }
        const value_params = pty.args.len - 1;
        var nb = try FuncBuilder.init(b.allocator, b.module);
    nb.census_quiet = true;
        defer nb.deinit();
        // The block's decls and tail read the enclosing scope's names too, so seed
        // the probe builder with the enclosing builder's declared types first; the
        // lambda's own params and block decls shadow them, as the source scopes.
        {
            var dit = b.local_decl_types.iterator();
            while (dit.next()) |e| {
                nb.setLocalDeclTypeOwned(e.key_ptr.*, e.value_ptr.clone(b.allocator) catch continue) catch {};
            }
        }
        // Derived-init enclosing locals never enter the declared-type map, so derive
        // each recorded init in the enclosing builder and seed the result. Declared
        // types above stay authoritative.
        {
            expr.od_depth += 1;
            var iit = b.localInitExprIterator();
            while (iit.next()) |e| {
                if (nb.localDeclTypeRef(e.key_ptr.*) != null) continue;
                var dt = (staticExprTypeRef(b, e.value_ptr.*) catch null) orelse continue;
                var h = std.mem.trimEnd(u8, dt.name, "?");
                if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
                const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                    ir.parseClassTypeParamIdentity(h) != null;
                if (h.len == 0 or bare) {
                    dt.deinit(b.allocator);
                    continue;
                }
                nb.setLocalDeclTypeOwned(e.key_ptr.*, dt) catch {
                    dt.deinit(b.allocator);
                };
            }
            expr.od_depth -= 1;
        }
        if (lam.params.len == 0 and value_params == 1) {
            try nb.setLocalDeclTypeOwned("it", try pty.args[0].clone(b.allocator));
        } else {
            const n = @min(lam.params.len, value_params);
            for (lam.params[0..n], pty.args[0..n]) |p, pa| {
                try nb.setLocalDeclTypeOwned(p.name, try pa.clone(b.allocator));
            }
        }
        // The tail may read the block's own earlier declarations, so record each
        // preceding local whose annotated or derivable init type is concrete.
        expr.od_depth += 1;
        for (stmts[0 .. stmts.len - 1]) |*st| {
            if (st.* != .Decl or st.Decl != .Property) continue;
            const prop = st.Decl.Property;
            if (prop.receiver_type != null or prop.delegate != null) continue;
            var decl_owned: ?ir.TypeRef = null;
            if (prop.ty) |*annotated| {
                decl_owned = loweredOwnedLocalTypeRef(&nb, annotated) catch null;
            } else if (prop.init) |*init| {
                decl_owned = staticExprTypeRef(&nb, init) catch null;
            }
            var dt = decl_owned orelse continue;
            var h = std.mem.trimEnd(u8, dt.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                ir.parseClassTypeParamIdentity(h) != null;
            if (h.len == 0 or bare) {
                dt.deinit(b.allocator);
                continue;
            }
            nb.setLocalDeclTypeOwned(prop.name.name, dt) catch {
                dt.deinit(b.allocator);
            };
        }
        const derived = staticExprTypeRef(&nb, tail) catch null;
        expr.od_depth -= 1;
        if (runtime.envOnce("KLIO_LAMRET_TRACE") != null) {
            std.debug.print("[lamret] target={s} arg#{d} pty={s} tail={s} p0={s} derived={s}\n", .{
                tf.name,                              i,                pty.name,
                @tagName(std.meta.activeTag(tail.*)), pty.args[0].name, if (derived) |d| d.name else "<null>",
            });
        }
        var body_ty = derived orelse continue;
        const fn_args = b.allocator.alloc(ir.TypeRef, pty.args.len) catch {
            body_ty.deinit(b.allocator);
            return error.OutOfMemory;
        };
        var ok_args = true;
        var filled: usize = 0;
        for (pty.args[0 .. pty.args.len - 1], 0..) |pa, k| {
            fn_args[k] = pa.clone(b.allocator) catch {
                ok_args = false;
                break;
            };
            filled += 1;
        }
        if (!ok_args) {
            for (fn_args[0..filled]) |*t| t.deinit(b.allocator);
            b.allocator.free(fn_args);
            body_ty.deinit(b.allocator);
            return error.OutOfMemory;
        }
        fn_args[pty.args.len - 1] = body_ty;
        const fn_name = b.allocator.dupe(u8, pty.name) catch {
            for (fn_args) |*t| t.deinit(b.allocator);
            b.allocator.free(fn_args);
            return error.OutOfMemory;
        };
        shape_set.inferred[i] = .{ .name = fn_name, .nullable = false, .args = fn_args };
        shape_set.shapes[i].ty = shape_set.inferred[i].?;
    }
}

/// A callable-reference argument's function type, read from the referenced
/// declaration, so the callee's `R` binds from its declared return as kotlinc sees
/// it. Declaration-read, never derived from a body, so it is authoritative. An
/// unbound class reference contributes its receiver as the leading parameter; a
/// bound one contributes the member's own parameters only. With no expected arity
/// the member is probed at arities 0 to 2 and the first commitment wins.
pub fn callableRefDeclTypeRef(
    b: *FuncBuilder,
    mr: anytype,
    want_arity: ?usize,
) Allocator.Error!?ir.TypeRef {
    var unbound = false;
    var recv_ty: ir.TypeRef = .{ .name = "", .nullable = false, .args = &.{} };
    if (mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1 and
        b.resolve(mr.receiver.Path.segments[0].name) == null and
        !b.knowsOuter(mr.receiver.Path.segments[0].name))
    {
        const rn = mr.receiver.Path.segments[0].name;
        if (b.module.classIdIndexed(rn, b.self_package, mr.name.span.file) != null) {
            unbound = true;
            recv_ty = .{ .name = rn, .nullable = false, .args = &.{} };
        }
    }
    if (!unbound) {
        recv_ty = argDeclTypeRefLazy(b, mr.receiver) orelse return null;
    }
    const owner = staticTypeClassId(b, recv_ty) orelse return null;
    var mf: ?*const ir.Func = null;
    var member_arity: usize = 0;
    if (want_arity) |wa| {
        if (wa < @intFromBool(unbound)) return null;
        member_arity = wa - @intFromBool(unbound);
        mf = resolveRefMemberAtArity(b, owner, mr.name, recv_ty, member_arity);
    } else {
        while (member_arity <= 2) : (member_arity += 1) {
            mf = resolveRefMemberAtArity(b, owner, mr.name, recv_ty, member_arity);
            if (mf != null) break;
        }
    }
    const f = mf orelse return null;
    if (!f.return_ty_declared or f.return_ty.name.len == 0) return null;
    // A bare type-parameter return says nothing the solver can bind.
    if (staticTypeClassId(b, f.return_ty) == null) return null;
    const m_has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
    const m_params = f.params[@intFromBool(m_has_this)..];
    if (m_params.len != member_arity) return null;
    const fn_arity = member_arity + @intFromBool(unbound);
    const fn_args = try b.allocator.alloc(ir.TypeRef, fn_arity + 1);
    var filled: usize = 0;
    errdefer {
        for (fn_args[0..filled]) |*t| t.deinit(b.allocator);
        b.allocator.free(fn_args);
    }
    if (unbound) {
        fn_args[0] = try recv_ty.clone(b.allocator);
        filled = 1;
    }
    for (m_params) |*mp| {
        fn_args[filled] = try mp.ty.clone(b.allocator);
        filled += 1;
    }
    fn_args[filled] = try f.return_ty.clone(b.allocator);
    filled += 1;
    const fn_name = try std.fmt.allocPrint(b.allocator, "Function{d}", .{fn_arity});
    if (runtime.envOnce("KLIO_LAMRET_TRACE") != null) {
        std.debug.print("[refshape] {s}::{s} -> {s} ret={s} unbound={}\n", .{
            recv_ty.name, mr.name.name, fn_name, f.return_ty.name, unbound,
        });
    }
    return .{ .name = fn_name, .nullable = false, .args = fn_args };
}

fn resolveRefMemberAtArity(
    b: *FuncBuilder,
    owner: ir.ClassId,
    name: ast.Ident,
    recv_ty: ir.TypeRef,
    arity: usize,
) ?*const ir.Func {
    var shape_buf: [3]applicability.ArgShape = @splat(.{ .ty_authoritative = false });
    if (arity > shape_buf.len) return null;
    const resolved = b.module.resolveMemberCall(owner, name.name, shape_buf[0..arity], .{
        .caller_file = name.span.file,
        .lexical_owner = null,
        .receiver_type = recv_ty,
    });
    if (resolved.target) |fid| return b.module.funcById(fid);
    // `Int::toUInt` names an extension, so the reference resolves through the same
    // extension engine its call form uses.
    const ext = b.module.resolveExtensionCall(name.name, recv_ty, shape_buf[0..arity], .{
        .caller_file = name.span.file,
        .caller_package = b.module.packageOfFile(name.span.file) orelse b.self_package,
        .lexical_owner = b.ownerClass(),
        .call_name = name.name,
    });
    const fid = ext.target orelse return null;
    return b.module.funcById(fid);
}

fn enrichCallableRefArgShapes(
    b: *FuncBuilder,
    target: FuncId,
    args: []const Expr,
    shape_set: *StaticReturnArgShapes,
) Allocator.Error!void {
    const tf = b.module.funcById(target) orelse return;
    const has_this = tf.params.len != 0 and std.mem.eql(u8, tf.params[0].name, "this");
    const first = @intFromBool(has_this);
    for (args, 0..) |*arg, i| {
        if (arg.* != .MemberRef) continue;
        if (shape_set.shapes[i].ty != null or shape_set.inferred[i] != null) continue;
        const pi = first + i;
        if (pi >= tf.params.len) break;
        const pty = tf.params[pi].ty;
        if (!std.mem.startsWith(u8, typeHead(pty.name), "Function") or pty.args.len == 0) continue;
        shape_set.inferred[i] = try callableRefDeclTypeRef(b, &arg.MemberRef, pty.args.len - 1);
        if (shape_set.inferred[i] != null) {
            shape_set.shapes[i].ty = shape_set.inferred[i].?;
            shape_set.shapes[i].ty_authoritative = true;
        }
    }
}

/// The declared return type of a member call, so a chained call types its receiver.
/// Resolution mirrors `memberCallArgArities`: the receiver's static type picks
/// candidates whose declared receiver it extends, ranked by scope tier, and the
/// answer counts only when every best-tier candidate agrees. A declared return is
/// evidence only when it names something, a bare type parameter resolving to no
/// class and disproving candidates a null type leaves open.
/// `ownerTypeArgFromReceiver` is the type the receiver gives one of the owner
/// class's type parameters, only for the direct-instantiation case where the
/// receiver's head is the declaring class so the arguments line up positionally.
fn ownerTypeParamSubstitution(
    b: *FuncBuilder,
    member_fid: FuncId,
    recv_ty: ir.TypeRef,
    ret_name: []const u8,
) ?ir.TypeRef {
    if (recv_ty.args.len == 0) return null;
    const ds = b.module.decl_sigs.get(member_fid.int()) orelse return null;
    const oid = ds.enclosing_class orelse return null;
    if (oid.int() >= b.module.classes.items.len) return null;
    const ocls = &b.module.classes.items[oid.int()];
    const recv_head = typeHead(std.mem.trimEnd(u8, recv_ty.name, "?"));
    if (!std.mem.eql(u8, ocls.name, recv_head)) return null;
    if (ocls.type_params.len != recv_ty.args.len) return null;
    const rh = typeHead(std.mem.trimEnd(u8, ret_name, "?"));
    for (ocls.type_params, 0..) |tp, i| {
        if (!std.mem.eql(u8, tp, rh)) continue;
        const arg = recv_ty.args[i];
        if (arg.name.len == 0 or std.mem.eql(u8, arg.name, "*")) return null;
        if (bareTypeParamHead(arg.name)) return null;
        return arg;
    }
    return null;
}

fn memberCallReturnTypeRef(b: *FuncBuilder, call_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (call_expr.* != .Call) return null;
    const call = call_expr.Call;
    if (call.callee.* != .Member) return null;
    const mname = call.callee.Member.name.name;
    if (runtime.envOnce("KLIO_MCRT_TRACE")) |w| {
        if (std.mem.eql(u8, w, mname))
            std.debug.print("[mcrt] {s} recv_tag={s}\n", .{ mname, @tagName(std.meta.activeTag(call.callee.Member.receiver.*)) });
    }
    const recv = call.callee.Member.receiver;

    var recv_owned: ?ir.TypeRef = null;
    defer if (recv_owned) |*t| t.deinit(b.allocator);
    const recv_ty: ir.TypeRef = blk: {
        if (argDeclTypeRefLazy(b, recv)) |known| {
            // A bare type-parameter lazy answer blocks the full deriver, whose
            // implicit-property channel substitutes the receiver's instantiation.
            const kh = typeHead(std.mem.trimEnd(u8, known.name, "?"));
            const bare_k = (kh.len > 0 and kh.len <= 2 and std.ascii.isUpper(kh[0])) or
                b.isTypeParam(kh) or ir.parseClassTypeParamIdentity(kh) != null;
            if (!bare_k) break :blk known;
        }
        recv_owned = try staticExprTypeRef(b, recv);
        break :blk recv_owned orelse return null;
    };
    // A nullable receiver reaches its member only through a safe call, and then the
    // result is nullable in turn, so the member is looked up on the non-null type
    // and the answer carries the `?` back.
    const safe_call = call.callee.Member.safe;
    if (runtime.envOnce("KLIO_MCRT_TRACE")) |w| {
        if (std.mem.eql(u8, w, mname))
            std.debug.print("[mcrt] {s} recv_ty={s} args={d} owned={}\n", .{ mname, recv_ty.name, recv_ty.args.len, recv_owned != null });
    }
    if (recv_ty.nullable and !safe_call) return null;
    const recv_head = typeHead(std.mem.trimEnd(u8, recv_ty.name, "?"));
    if (recv_head.len == 0) return null;

    const caller_file = exprSpan(recv).file;
    const caller_pkg = b.module.packageOfFile(caller_file) orelse b.self_package;
    var best_tier: u8 = 255;
    var agreed: ?ir.TypeRef = null;
    var agreed_fid: ?FuncId = null;

    // A declared member of the receiver's own class outranks every extension,
    // exactly as Kotlin resolves it.
    {
        var probe: usize = call.args.len;
        while (probe <= call.args.len + 3) : (probe += 1) {
            const key = std.fmt.allocPrint(b.allocator, "{s}\x00{s}\x00{d}", .{ recv_head, mname, probe }) catch break;
            defer b.allocator.free(key);
            const fid = b.module.registry.member_method_fids.get(key) orelse continue;
            const f = b.module.funcById(fid) orelse continue;
            // An expression body with no annotation records `Unit` as a placeholder,
            // so an undeclared return is not a fact.
            if (!f.return_ty_declared or f.return_ty.name.len == 0) return null;
            // A generic member returns one of its owner's type parameters, and the
            // receiver carries the arguments that say which. The member stays the
            // declaration, Kotlin picking it over any extension.
            if (bareTypeParamHead(f.return_ty.name)) {
                const sub = ownerTypeParamSubstitution(b, fid, recv_ty, f.return_ty.name) orelse return null;
                var out_sub = try sub.clone(b.allocator);
                if (safe_call or f.return_ty.nullable) out_sub.nullable = true;
                if (staticTypeClassId(b, out_sub) == null) {
                    out_sub.deinit(b.allocator);
                    return null;
                }
                return out_sub;
            }
            if (staticTypeClassId(b, f.return_ty) == null) return null;
            var out = try f.return_ty.clone(b.allocator);
            if (safe_call) out.nullable = true;
            return out;
        }
    }

    for (b.module.funcsBySimpleName(mname)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.kind == .instance_method or f.params.len == 0 or
            !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (f.kind == .member_extension) {
            const owner = b.module.registry.member_ext_owner_class.get(fid) orelse continue;
            const lexical_owner = b.ownerClass() orelse continue;
            if (!b.module.classIsOrExtends(lexical_owner, owner)) continue;
        }
        const candidate_head = typeHead(f.params[0].ty.name);
        // An identity extension returns its own receiver: `fun <T> T.apply(block:
        // T.() -> Unit): T`. Its declared receiver is a bare type parameter, so the
        // head filter below never admits it, but the receiver instantiates both.
        if (f.return_ty_declared and bareTypeParamHead(candidate_head) and
            bareTypeParamHead(f.return_ty.name) and
            std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, f.return_ty.name, "?")), candidate_head))
        {
            const tier_i = b.module.scopeTier(f.fqn, f.package, mname, caller_pkg, caller_file);
            if (tier_i > 3) continue;
            if (agreed) |*old| old.deinit(b.allocator);
            var ident = try recv_ty.clone(b.allocator);
            ident.nullable = recv_ty.nullable or f.return_ty.nullable;
            return ident;
        }
        if (!b.module.classIsOrExtends(recv_head, candidate_head)) continue;
        const tier = b.module.scopeTier(f.fqn, f.package, mname, caller_pkg, caller_file);
        if (tier > 3 or tier > best_tier) continue;
        if (!f.return_ty_declared or f.return_ty.name.len == 0 or
            bareTypeParamHead(f.return_ty.name))
        {
            // An un-annotated member-extension expression body derives its return on
            // demand from the registered AST, the channel class members use for
            // forward references; without it the result fails to refute a same-name
            // member's invariant generic parameter.
            if (!f.return_ty_declared) {
                const owner: ?[]const u8 = blk_own: {
                    break :blk_own b.module.registry.member_ext_owner_class.get(fid) orelse b.ownerClass();
                };
                if (owner) |ow| {
                    if (inline_state.exprBodyMemberAst(ow, mname, call.args.len)) |fa| {
                        if (fa.body) |*fbody| {
                            if (fbody.* == .Expr and expr.od_depth < 3) {
                                expr.od_depth += 1;
                                defer expr.od_depth -= 1;
                                var nb3 = try FuncBuilder.init(b.allocator, b.module);
                                nb3.census_quiet = true;
                                defer nb3.deinit();
                                if (fa.receiver_type) |*frt| {
                                    nb3.setRecvTypeRefOwned(try loweredOwnedLocalTypeRef(&nb3, frt));
                                }
                                for (fa.params) |*ap| {
                                    try nb3.setLocalDeclTypeOwned(ap.name.name, try loweredOwnedLocalTypeRef(&nb3, &ap.ty));
                                }
                                if (try staticExprTypeRef(&nb3, &fbody.Expr)) |derived| {
                                    var out2 = derived;
                                    const oh2 = typeHead(std.mem.trimEnd(u8, out2.name, "?"));
                                    if (oh2.len > 2 and !b.isTypeParam(oh2) and
                                        ir.parseClassTypeParamIdentity(oh2) == null)
                                    {
                                        if (agreed) |*old| old.deinit(b.allocator);
                                        return out2;
                                    }
                                    out2.deinit(b.allocator);
                                }
                            }
                        }
                    }
                }
            }
            // A declared bare-parameter return resolves in the callee's own scope,
            // the owner class's `<T : Bound>`. Kotlin types the call at the
            // parameter's upper bound even for a caller whose own `T` shadows the
            // name. A fn-level `<T>` stays unknown, its default bound naming nothing.
            if (f.return_ty_declared and bareTypeParamHead(f.return_ty.name) and
                b.module.staticFuncTypeParamBound(fid, typeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"))) == null)
            {
                const head = typeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"));
                if (b.module.registry.member_ext_owner_class.get(fid)) |ow| {
                    const cbs = b.module.registry.class_type_param_bounds.get(ow) orelse blk_cb: {
                        if (b.module.classIdByFqn(ow)) |cid| {
                            if (cid.int() < b.module.classes.items.len) {
                                break :blk_cb b.module.registry.class_type_param_bounds.get(b.module.classes.items[cid.int()].fqn) orelse &.{};
                            }
                        }
                        break :blk_cb &.{};
                    };
                    for (cbs) |cb| {
                        if (!std.mem.eql(u8, cb.param, head)) continue;
                        const bh = typeHead(std.mem.trimEnd(u8, cb.bound, "?"));
                        if (bh.len <= 2 or std.mem.eql(u8, bh, "Any") or
                            std.mem.eql(u8, bh, "kotlin.Any") or b.isTypeParam(bh) or
                            ir.parseClassTypeParamIdentity(bh) != null) break;
                        var out = ir.TypeRef{
                            .name = try b.allocator.dupe(u8, std.mem.trimEnd(u8, cb.bound, "?")),
                            .nullable = f.return_ty.nullable or safe_call,
                            .args = &.{},
                        };
                        if (staticTypeClassId(b, out) == null) {
                            out.deinit(b.allocator);
                            break;
                        }
                        if (agreed) |*old| old.deinit(b.allocator);
                        return out;
                    }
                }
            }
            if (agreed) |*old| old.deinit(b.allocator);
            return null;
        }
        if (tier < best_tier) {
            if (agreed) |*old| old.deinit(b.allocator);
            agreed = try f.return_ty.clone(b.allocator);
            agreed_fid = fid;
            best_tier = tier;
            continue;
        }
        if (agreed) |*old| {
            if (!std.mem.eql(u8, old.name, f.return_ty.name)) {
                // A return-variant family discriminates by the trailing lambda's
                // derived return, as the emission's pick does; without a pick the
                // disagreement stands and the record refuses.
                old.deinit(b.allocator);
                agreed = null;
                agreed_fid = null;
                // No lambda to discriminate: an exactly-instantiated receiver variant
                // outranks the generic sibling, per kotlinc's most-specific rule.
                if (recv_ty.args.len == 1 and allNull(call.arg_names)) {
                    const actual_arg_head = typeHead(std.mem.trimEnd(u8, recv_ty.args[0].name, "?"));
                    var exact_fid: ?FuncId = null;
                    var exact_dup = false;
                    for (b.module.funcsBySimpleName(mname)) |fid2| {
                        const f2 = b.module.funcById(fid2) orelse continue;
                        if (f2.kind == .instance_method or f2.params.len == 0 or
                            !std.mem.eql(u8, f2.params[0].name, "this")) continue;
                        if (!b.module.classIsOrExtends(recv_head, typeHead(f2.params[0].ty.name))) continue;
                        if (f2.params.len - 1 != call.args.len) continue;
                        if (f2.params[0].ty.args.len != 1) continue;
                        var dah = std.mem.trimEnd(u8, f2.params[0].ty.args[0].name, "?");
                        if (std.mem.startsWith(u8, dah, "in#")) dah = dah[3..];
                        if (std.mem.startsWith(u8, dah, "out#")) dah = dah[4..];
                        const dh2 = typeHead(dah);
                        if (dh2.len == 0 or (dh2.len <= 2 and std.ascii.isUpper(dh2[0])) or
                            b.isTypeParam(dh2) or ir.parseClassTypeParamIdentity(dh2) != null) continue;
                        if (!std.mem.eql(u8, dh2, actual_arg_head)) continue;
                        if (exact_fid != null) {
                            exact_dup = true;
                            break;
                        }
                        exact_fid = fid2;
                    }
                    if (!exact_dup) if (exact_fid) |efid| {
                        if (b.module.funcById(efid)) |ef| {
                            if (ef.return_ty_declared and ef.return_ty.name.len != 0 and
                                !bareTypeParamHead(ef.return_ty.name))
                            {
                                agreed = try ef.return_ty.clone(b.allocator);
                                agreed_fid = efid;
                                break;
                            }
                        }
                    };
                }
                if (call.args.len != 0 and allNull(call.arg_names)) {
                    const pcands = try b.module.bareCallCandidates(b.allocator, mname, caller_file);
                    defer b.allocator.free(pcands);
                    expr.lamret_allow_bodyless = true;
                    defer expr.lamret_allow_bodyless = false;
                    if (try overloadPickByLambdaReturnFull(b, pcands, call.args, call.args.len, recv_head, recv)) |picked| {
                        const pf = b.module.funcById(picked) orelse return null;
                        if (!pf.return_ty_declared or pf.return_ty.name.len == 0 or
                            bareTypeParamHead(pf.return_ty.name)) return null;
                        agreed = try pf.return_ty.clone(b.allocator);
                        agreed_fid = picked;
                        break;
                    }
                }
                return null;
            }
        } else {
            agreed = try f.return_ty.clone(b.allocator);
            agreed_fid = fid;
        }
    }
    if (agreed) |*ret| {
        if (staticTypeClassId(b, ret.*) == null) {
            ret.deinit(b.allocator);
            return null;
        }
        // The winning extension's return can mention its own fn type params in
        // argument position, which the receiver instantiates; a raw `T` in the record
        // poisons every downstream binding. An unsolvable param keeps the raw record.
        if (agreed_fid != null and tyMentionsBareTp(ret.*)) sub_ret: {
            const wf = b.module.funcById(agreed_fid.?) orelse break :sub_ret;
            var sc = std.heap.ArenaAllocator.init(b.allocator);
            defer sc.deinit();
            const a2 = sc.allocator();
            const solved = (b.module.solveCallBindings(
                a2,
                agreed_fid.?,
                wf,
                recv_ty,
                null,
                &.{},
                &.{},
                false,
            ) catch null) orelse break :sub_ret;
            const substituted = ir.Module.substituteBoundType(a2, ret.*, solved.bindings) catch break :sub_ret;
            // With every one of the callee's own type parameters solved the
            // substitution is complete, and a residual bare head belongs to the
            // caller's scope. Keeping the raw record types a loop variable as the
            // callee's erased parameter, refuting extensions on the real element type.
            var all_solved = true;
            if (b.module.registry.func_type_params.get(agreed_fid.?)) |tps| {
                for (tps.items) |tp| {
                    var found = false;
                    for (solved.bindings) |bd| {
                        if (std.mem.eql(u8, bd.name, tp)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        all_solved = false;
                        break;
                    }
                }
            }
            if (!all_solved and tyMentionsBareTp(substituted)) break :sub_ret;
            const out2 = try substituted.clone(b.allocator);
            ret.deinit(b.allocator);
            ret.* = out2;
        }
        if (safe_call) ret.nullable = true;
        return ret.*;
    }
    return null;
}

/// Whether any head in the type, itself or a nested argument, is a bare function or
/// class type parameter rather than a nameable class.
fn tyMentionsBareTp(ty: ir.TypeRef) bool {
    var h = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.startsWith(u8, h, "in#")) h = h[3..];
    if (std.mem.startsWith(u8, h, "out#")) h = h[4..];
    if (bareTypeParamHead(h) or ir.parseClassTypeParamIdentity(h) != null) return true;
    for (ty.args) |a2| {
        if (tyMentionsBareTp(a2)) return true;
    }
    return false;
}

/// The declared return of a bare call that is really a member call on the implicit
/// receiver, the shape a spliced inline body is written in. Every other return
/// channel expects a spelled-out receiver.
fn bareMemberReturnTypeRef(b: *FuncBuilder, call_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (call_expr.* != .Call) return null;
    const call = call_expr.Call;
    if (call.callee.* != .Path or call.callee.Path.segments.len != 1) return null;
    const nm = call.callee.Path.segments[0].name;
    // A local binding, a local `fun`, or a top-level namesake resolves the call some
    // other way; only a name the receiver's class declares and nothing else shadows
    // is unambiguously the member.
    if (b.resolve(nm) != null or b.knowsOuter(nm) or b.isLocalFn(nm)) return null;
    // No top-level-namesake bail: when the implicit receiver's own class declares
    // the member, Kotlin's receiver scope resolves it over any top-level namesake.
    const recv_head = b.spliceRecvTy() orelse b.recvTy() orelse b.ownerClass() orelse return null;
    const rh = typeHead(std.mem.trimEnd(u8, recv_head, "?"));
    if (rh.len == 0) return null;
    var probe: usize = call.args.len;
    while (probe <= call.args.len + 3) : (probe += 1) {
        const key = std.fmt.allocPrint(b.allocator, "{s}\x00{s}\x00{d}", .{ rh, nm, probe }) catch return null;
        defer b.allocator.free(key);
        const fid = b.module.registry.member_method_fids.get(key) orelse continue;
        const f = b.module.funcById(fid) orelse continue;
        if (!f.return_ty_declared or f.return_ty.name.len == 0) return null;
        // Instantiate through the full implicit receiver when it carries arguments,
        // so the return keeps the caller's element type.
        const full_recv: ?ir.TypeRef = if (b.spliceRecvTyRef()) |r| r.* else b.recvTypeRef();
        if (full_recv) |fr| {
            if (fr.args.len != 0) {
                var shape_set0 = try buildStaticReturnArgShapes(b, call.args, &.{});
                defer shape_set0.deinit(b.allocator);
                if (try b.module.instantiatedCallReturnType(b.allocator, fid, fr, null, shape_set0.shapes, &.{})) |inst| {
                    var out2 = inst;
                    const oh = typeHead(std.mem.trimEnd(u8, out2.name, "?"));
                    if (oh.len > 2 and !b.isTypeParam(oh) and ir.parseClassTypeParamIdentity(oh) == null) {
                        return out2;
                    }
                    out2.deinit(b.allocator);
                }
            }
        }
        if (bareTypeParamHead(f.return_ty.name)) return null;
        if (staticTypeClassId(b, f.return_ty) == null) return null;
        return try f.return_ty.clone(b.allocator);
    }
    return null;
}
