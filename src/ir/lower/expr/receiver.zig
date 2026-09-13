//! Receiver lowering: the shared `this`-register resolver and the overload picks
//! a receiver's static shape decides.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const inline_state = @import("../inline_state.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const isTopLevelProp = inline_state.isTopLevelProp;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const binary_mod = @import("binary.zig");
const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;

const paths_mod = @import("paths.zig");
const enclosingMemberShadowsClass = paths_mod.enclosingMemberShadowsClass;
const scopeTypeRename = paths_mod.scopeTypeRename;

const static_type_mod = @import("static_type.zig");
const iterableElementTypeRef = static_type_mod.iterableElementTypeRef;
const staticExprTypeRef = static_type_mod.staticExprTypeRef;
const staticTypeClassId = static_type_mod.staticTypeClassId;

const probe_mod = @import("probe.zig");
const typeHead = probe_mod.typeHead;

const block_mod = @import("block.zig");
const rsplitLast = block_mod.rsplitLast;

/// The single lowering-time `this`-register resolver shared by the bare
/// `::name`/member-ref site and the bare-extension-call sites. A bound local
/// `this` wins; otherwise it is recovered from an outer capture when the name is
/// a known outer, and with `in_lambda_body` set, for any lambda body, whose
/// implicit `this` arrives via the closure's capture slot without a `knowsOuter`
/// record. `bind_local` binds the recovered register as the frame's `this` so
/// later references reuse it. Null at top level or in a non-receiver context.
pub fn resolveThisRegKind(b: *FuncBuilder, in_lambda_body: bool, bind_local: bool) Allocator.Error!?Reg {
    if (b.resolve("this")) |r| return r;
    if (b.knowsOuter("this") or (in_lambda_body and b.capturesThisSlot())) {
        const dst = try b.loadCaptureHoisted("this");
        if (bind_local) try b.bind("this", dst);
        if (runtime.envOnce("KLIO_THIS_TRACE") != null) {
            std.debug.print("[this-recover] bind={} reg={d} depth={d} in={s}\n", .{ bind_local, dst.int(), b.scopeDepth(), build.currentRealFn() orelse "-" });
        }
        return dst;
    }
    return null;
}

/// The register holding the current implicit receiver, bound directly in a
/// method, extension or receiver-lambda body, or reachable as an outer capture.
/// Null at top level or in a non-receiver context. Binds a bare `::name` member
/// reference to its receiver at creation time.
fn resolveThisReg(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, false, false);
}

/// Resolve the instance selected by `super`. A lambda nested in a class member
/// keeps the member's lexical receiver in its closure capture slot, though the
/// lambda frame has no locally bound `this` parameter.
pub fn resolveSuperThisReg(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, true, false);
}

/// Lower an expression appearing as the receiver or qualifier head of a member
/// access or call. A bare single-segment class or interface name here is a
/// qualifier and stays the class value, so nested-class and companion-member
/// forwarding work, unlike the same Path in value position, which resolves to the
/// companion object. Everything else defers to `lowerExpr`.
pub fn lowerReceiver(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    // A receiver is a nested expression, so the enclosing call's per-arg typing
    // stash must never reach the receiver's own lambdas. Shield the stash for the
    // whole receiver lowering.
    const sh_bm = b.pending_arg_broad_masks;
    const sh_fg = b.pending_arg_fn_generic;
    const sh_lp = b.pending_arg_lambda_param_types;
    // The `-> Unit` coercion mask belongs to the enclosing call's args too: a
    // receiver splicing a `-> Unit` operator must not tag the outer call's lambda.
    const sh_lu = b.pending_arg_lambda_unit;
    b.pending_arg_broad_masks = null;
    b.pending_arg_fn_generic = null;
    b.pending_arg_lambda_param_types = null;
    b.pending_arg_lambda_unit = null;
    defer {
        b.pending_arg_broad_masks = sh_bm;
        b.pending_arg_fn_generic = sh_fg;
        b.pending_arg_lambda_param_types = sh_lp;
        if (b.pending_arg_lambda_unit) |m| b.allocator.free(m);
        b.pending_arg_lambda_unit = sh_lu;
    }
    if (expr.* == .Path and expr.Path.segments.len == 1) {
        const segments = expr.Path.segments;
        const n = segments[0].name;
        // Skip the class-name shortcut when the scope renames this name to a
        // mangled nested class or a file-private type: a bare `Inner` inside
        // `Outer` must reach `Outer$Inner` even though a same-named top-level
        // class owns the bare `class_id`. `lowerExpr`'s Path arm applies it.
        const aliased = scopeTypeRename(b, n, segments[0].span.file.int()) != null;
        // A class whose bare simple name is unregistered because it
        // collision-mangled is still pinned by the file's named import, so resolve
        // it through its FQN; otherwise the receiver falls to a member access on
        // the implicit receiver.
        var imported_fqn: ?[]const u8 = null;
        const imported_cid: ?ir.ClassId = if (!aliased and b.module.classId(n) == null) blk: {
            for (b.module.importAliasPathsIn(segments[0].span.file, n)) |p| {
                if (b.module.classIdByFqn(p.fqn)) |cid| {
                    imported_fqn = p.fqn;
                    break :blk cid;
                }
            }
            break :blk null;
        } else null;
        if (!aliased and b.resolve(n) == null and !b.knowsOuter(n) and
            (b.module.classId(n) != null or imported_cid != null) and !enclosingMemberShadowsClass(b, n))
        {
            const dst = b.allocReg();
            // A collision-mangled import has no name-published singleton under its
            // bare simple name, so key the load on the FQN and let the name-keyed
            // fallback drive the object or companion init by that name.
            const nm = try b.module.internConst(b.allocator, .{ .String = imported_fqn orelse n });
            // The index-resolved class rides as the exact identity so a
            // same-simple-name class from an invisible package cannot swap in at
            // runtime. A same-named top-level property keeps the name-keyed read,
            // winning in value position, but only when at least as visible as the
            // class at this site.
            const cls_pick: ?ir.ClassId = blk: {
                if (imported_cid) |cid| break :blk cid;
                if (isTopLevelProp(n)) {
                    const pt = b.module.topLevelPropRefTier(n, b.self_package, segments[0].span.file) orelse 255;
                    const ct = b.module.classRefTier(n, b.self_package, segments[0].span.file) orelse 255;
                    if (pt <= ct) break :blk b.module.classIdExactImport(n, segments[0].span.file);
                }
                break :blk b.module.classIdIndexed(n, b.self_package, segments[0].span.file);
            };
            // A collision-mangled import target has no name-published singleton to
            // fall back on, so load the class value by id directly; the subsequent
            // `.EMPTY` reads its companion off that value.
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = cls_pick, .ctor_ref = imported_cid != null } });
            return dst;
        }
    }
    // A receiver is not in the call's tail position, so drop the expected-type
    // hint before it reaches a reified inline call here.
    const prev_expected = b.pushExpected(null);
    const r = try lowerExpr(b, expr);
    b.restoreExpected(prev_expected);
    return r;
}

/// Among same-name overload candidates, prefer the one whose parameter type at an
/// explicitly cast argument position matches the cast target. Null when no cast
/// argument disambiguates an arity-matching candidate.
pub fn overloadPickByCast(
    b: *FuncBuilder,
    cands: []const FuncId,
    args: []const Expr,
    want: usize,
) Allocator.Error!?FuncId {
    // Collect (arg index, cast simple-name) pairs.
    var casts: std.ArrayList(struct { i: usize, name: []const u8 }) = .empty;
    defer casts.deinit(b.allocator);
    for (args, 0..) |a, i| {
        if (a == .As) {
            const full = a.As.ty.name.name;
            const simple = rsplitLast(full, '.');
            try casts.append(b.allocator, .{ .i = i, .name = simple });
        }
    }
    if (casts.items.len == 0) return null;

    var best: ?FuncId = null;
    var best_score: i32 = 0;
    for (cands) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!f.hasBody() or (f.params.len != 0 and f.params[f.params.len - 1].is_vararg)) continue;
        const base: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (f.params.len -| base != want) continue;
        var score: i32 = 0;
        for (casts.items) |c| {
            if (base + c.i < f.params.len) {
                const p = f.params[base + c.i];
                const pn = rsplitLast(p.ty.name, '.');
                if (std.mem.eql(u8, pn, c.name)) score += 2;
            }
        }
        if (score > 0 and (best == null or score > best_score)) {
            best = fid;
            best_score = score;
        }
    }
    return best;
}

/// Candidates agreeing on a trailing lambda parameter's parameter types but
/// differing only in its declared return discriminate by the literal's derived
/// return under the agreed binding, exactly as kotlinc infers. The derivation
/// feeds only this pick among a fixed set and never instantiates a type variable.
/// No unique match leaves the tie.
pub fn receiverHeadServes(b: *const FuncBuilder, actual: []const u8, declared: []const u8) bool {
    if (std.mem.eql(u8, actual, declared)) return true;
    for (applicability.builtinSupersOf(actual)) |sup| {
        if (std.mem.eql(u8, applicability.simpleName(sup), declared)) return true;
    }
    if (b.module.registry.class_super_names.get(actual)) |chain| {
        for (chain) |sup| {
            if (std.mem.eql(u8, applicability.simpleName(sup), declared)) return true;
        }
    }
    return false;
}

pub fn overloadPickByLambdaReturn(
    b: *FuncBuilder,
    cands: []const FuncId,
    args: []const Expr,
    want: usize,
) Allocator.Error!?FuncId {
    return overloadPickByLambdaReturnRecv(b, cands, args, want, null);
}

fn overloadPickByLambdaReturnRecv(
    b: *FuncBuilder,
    cands: []const FuncId,
    args: []const Expr,
    want: usize,
    explicit_recv_head: ?[]const u8,
) Allocator.Error!?FuncId {
    return overloadPickByLambdaReturnFull(b, cands, args, want, explicit_recv_head, null);
}

pub fn overloadPickByLambdaReturnFull(
    b: *FuncBuilder,
    cands: []const FuncId,
    args: []const Expr,
    want: usize,
    explicit_recv_head: ?[]const u8,
    recv_expr: ?*const Expr,
) Allocator.Error!?FuncId {
    if (args.len == 0) return null;
    const li = args.len - 1;
    if (args[li] != .Lambda) return null;
    const lam = args[li].Lambda;
    const stmts = lam.body.stmts;
    if (stmts.len == 0 or stmts[stmts.len - 1] != .Expr) return null;
    const Entry = struct { fid: FuncId, ret: []const u8, params: []const ir.TypeRef, exact_recv: bool };
    var family: std.ArrayList(Entry) = .empty;
    defer family.deinit(b.allocator);
    // The implicit receiver's head filters extension candidates before the
    // agreement check, so an unrelated family's parameter spelling cannot
    // disagree the pick into a bail.
    const actual_recv_head: ?[]const u8 = blk: {
        if (explicit_recv_head) |h| break :blk h;
        const h = b.recvTy() orelse b.spliceRecvTy() orelse b.enclosingRecvTy() orelse break :blk null;
        break :blk typeHead(std.mem.trimEnd(u8, h, "?"));
    };
    const lamret_why = runtime.envOnce("KLIO_LAMRET_WHY");
    for (cands) |fid| {
        const f = b.module.funcById(fid) orelse {
            if (lamret_why != null) std.debug.print("[lamret-why] #{d} skip=null_func\n", .{fid.int()});
            continue;
        };
        const why = lamret_why != null and std.mem.find(u8, f.fqn, lamret_why.?) != null;
        if (!f.hasBody() and !expr_mod.lamret_allow_bodyless) {
            if (why) std.debug.print("[lamret-why] {s}#{d} skip=no_body\n", .{ f.fqn, fid.int() });
            continue;
        }
        const base: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        if (f.params.len -| base != want) {
            if (why) std.debug.print("[lamret-why] {s}#{d} skip=arity params={d} want={d}\n", .{ f.fqn, fid.int(), f.params.len, want });
            continue;
        }
        var exact_recv = false;
        if (base == 1) {
            const ah = actual_recv_head orelse {
                if (why) std.debug.print("[lamret-why] {s}#{d} skip=no_recv_head\n", .{ f.fqn, fid.int() });
                continue;
            };
            var dr = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
            if (std.mem.findScalar(u8, dr, '<')) |lt| dr = dr[0..lt];
            const dh = typeHead(dr);
            exact_recv = std.mem.eql(u8, ah, dh);
            if (!(exact_recv or dh.len <= 2 or ir.parseClassTypeParamIdentity(f.params[0].ty.name) != null or
                receiverHeadServes(b, ah, dh)))
            {
                if (why) std.debug.print("[lamret-why] {s}#{d} skip=recv ah={s} dh={s}\n", .{ f.fqn, fid.int(), ah, dh });
                continue;
            }
        }
        const pty = f.params[f.params.len - 1].ty;
        if (!std.mem.startsWith(u8, typeHead(pty.name), "Function") or pty.args.len < 1) {
            if (why) std.debug.print("[lamret-why] {s}#{d} skip=fn_ty pty={s} args={d}\n", .{ f.fqn, fid.int(), pty.name, pty.args.len });
            continue;
        }
        const params = pty.args[0 .. pty.args.len - 1];
        const ret_head = typeHead(std.mem.trimEnd(u8, pty.args[pty.args.len - 1].name, "?"));
        if (ret_head.len == 0) continue;
        try family.append(b.allocator, .{ .fid = fid, .ret = ret_head, .params = params, .exact_recv = exact_recv });
    }
    const lamret_trace = runtime.envOnce("KLIO_LAMRET_TRACE") != null;
    // Receiver specificity narrows before the return pick, as kotlinc ranks: an
    // exact-receiver family beats supertype-receiver applicables, whose different
    // param spelling must not disagree the pick into a bail.
    var any_exact = false;
    for (family.items) |e| any_exact = any_exact or e.exact_recv;
    if (any_exact) {
        var w: usize = 0;
        for (family.items) |e| {
            if (e.exact_recv) {
                family.items[w] = e;
                w += 1;
            }
        }
        family.items.len = w;
    }
    // The surviving set must agree on the lambda slot's parameter types; return
    // variety is what the pick discriminates.
    var agreed_params: ?[]const ir.TypeRef = null;
    var distinct_returns: usize = 0;
    for (family.items) |e| {
        if (agreed_params) |prev| {
            if (prev.len != e.params.len) return null;
            for (prev, e.params) |pa, pb2| {
                if (!std.mem.eql(u8, pa.name, pb2.name)) return null;
            }
        } else {
            agreed_params = e.params;
        }
    }
    for (family.items, 0..) |e, ei| {
        var seen = false;
        for (family.items[0..ei]) |prior| {
            if (std.mem.eql(u8, prior.ret, e.ret)) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct_returns += 1;
    }
    if (family.items.len < 2 or distinct_returns < 2) {
        if (lamret_trace and family.items.len != 0) {
            std.debug.print("[lamret-bail] family={d} distinct={d} first={s}\n", .{
                family.items.len,
                distinct_returns,
                if (b.module.funcById(family.items[0].fid)) |f| f.fqn else "?",
            });
        }
        return null;
    }
    const fparams = agreed_params orelse return null;
    // Bind the lambda's value parameters from the agreed declared types; a sole
    // bare-type-parameter param is the receiver's element.
    var nb = try FuncBuilder.init(b.allocator, b.module);
    nb.census_quiet = true;
    defer nb.deinit();
    // The lambda body's calls resolve in the caller's lexical class scope, so
    // `it.toLong()` binds the enclosing class's private member extension.
    if (b.ownerClass()) |oc0| nb.setOwnerClass(oc0);
    var elem_owned: ?ir.TypeRef = null;
    defer if (elem_owned) |*t| t.deinit(b.allocator);
    var i: usize = 0;
    while (i < fparams.len) : (i += 1) {
        const pname = if (lam.params.len == 0 and fparams.len == 1)
            "it"
        else if (i < lam.params.len)
            lam.params[i].name
        else
            return null;
        const declared = fparams[i];
        const dh = typeHead(std.mem.trimEnd(u8, declared.name, "?"));
        // A scalar head has no class row, but the deriver types its members from
        // the declaration tables, so the declared param type still binds.
        if (staticTypeClassId(b, declared) != null or isPrimitiveTypeName(dh)) {
            try nb.setLocalDeclTypeOwned(pname, try declared.clone(b.allocator));
        } else if (dh.len <= 2 or ir.parseClassTypeParamIdentity(declared.name) != null) {
            if (fparams.len != 1) return null;
            if (elem_owned == null) {
                if (recv_expr) |re| {
                    elem_owned = try iterableElementTypeRef(b, re);
                } else {
                    const this_expr: Expr = .{ .This = .{ .qualifier = null, .span = args[li].span() } };
                    elem_owned = try iterableElementTypeRef(b, &this_expr);
                }
                if (lamret_trace) {
                    std.debug.print("[lamret-elem] recv_expr={} recvTy={s} elem={s}\n", .{
                        recv_expr != null,
                        b.recvTy() orelse "-",
                        if (elem_owned) |e2| e2.name else "<null>",
                    });
                }
            }
            const elem = elem_owned orelse return null;
            try nb.setLocalDeclTypeOwned(pname, try elem.clone(b.allocator));
        } else {
            return null;
        }
    }
    expr_mod.od_depth += 1;
    const derived = staticExprTypeRef(&nb, &stmts[stmts.len - 1].Expr) catch null;
    expr_mod.od_depth -= 1;
    if (lamret_trace and derived == null) {
        std.debug.print("[lamret-bail] derive=null family={d} first={s}\n", .{
            family.items.len,
            if (b.module.funcById(family.items[0].fid)) |f| f.fqn else "?",
        });
    }
    var derived_ty = derived orelse return null;
    defer derived_ty.deinit(b.allocator);
    const derived_head = typeHead(std.mem.trimEnd(u8, derived_ty.name, "?"));
    var pick: ?FuncId = null;
    for (family.items) |e| {
        if (std.mem.eql(u8, e.ret, derived_head)) {
            if (pick != null) return null;
            pick = e.fid;
        }
    }
    if (runtime.envOnce("KLIO_LAMRET_TRACE") != null and pick != null) {
        const pf = b.module.funcById(pick.?);
        std.debug.print("[lamret-pick] derived={s} -> {s}\n", .{ derived_head, if (pf) |f2| f2.fqn else "?" });
    }
    return pick;
}
