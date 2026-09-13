//! Static type probes over locals, properties, factories and lateinit
//! markers.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const decl_mod = @import("../decl.zig");
const lambda_body = @import("../lambda_body.zig");
const static_call_type = @import("../static_call_type.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const isLowerAnonCapture = decl_mod.isLowerAnonCapture;
const resolveCapture = lambda_body.resolveCapture;
const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;
const callableRefDeclTypeRef = static_call_type.callableRefDeclTypeRef;
const StaticReturnArgShapes = static_call_type.StaticReturnArgShapes;

const expr_mod = @import("../expr.zig");

const binary_mod = @import("binary.zig");
const staticClassifierArgsComplete = binary_mod.staticClassifierArgsComplete;

const member_mod = @import("member.zig");
const propTypeHeadOn = member_mod.propTypeHeadOn;
const propTypeRefOn = member_mod.propTypeRefOn;

const call_mod = @import("call.zig");
const lastArgIsLambda = call_mod.lastArgIsLambda;

const arg_shape_mod = @import("arg_shape.zig");
const LitKind = arg_shape_mod.LitKind;
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;
const argEvidenceLitKind = arg_shape_mod.argEvidenceLitKind;
const shapeOfAstArg = arg_shape_mod.shapeOfAstArg;

const static_type_mod = @import("static_type.zig");
const ctorInitTypeRef = static_type_mod.ctorInitTypeRef;
const popInitChain = static_type_mod.popInitChain;
const pushInitChain = static_type_mod.pushInitChain;
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const ctorSigRejectsArgs = probe_mod.ctorSigRejectsArgs;
const namedArgsNameParams = probe_mod.namedArgsNameParams;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const norecvCensusOn = audit_mod.norecvCensusOn;

pub fn localInitTypeRef(b: *FuncBuilder, receiver: *const Expr) Allocator.Error!?ir.TypeRef {
    if (receiver.* != .Path or receiver.Path.segments.len != 1) return null;
    return localInitTypeRefNamed(b, receiver.Path.segments[0].name);
}

/// The by-name entry: a local's type derived from its RECORDED initializer.
/// A call initializer is never written into the local's declared type — it is
/// resolved here, on demand, at each use site. Anything asking "is this local
/// typed?" must come through here, not through the declared-type table alone.
pub fn localInitTypeRefNamed(b: *FuncBuilder, name: []const u8) Allocator.Error!?ir.TypeRef {
    if (b.resolve(name) == null) return null;
    const init_expr = b.localInitExpr(name) orelse {
        if (norecvCensusOn()) audit_mod.lm_localinit[0] += 1;
        return null;
    };
    // Same cycle as the declared-type walk: deriving one local's type can
    // reach back into it once every local in the block is bound.
    if (!pushInitChain(name)) return null;
    defer popInitChain();
    if (try ctorInitTypeRef(b, init_expr)) |ctor_ty| {
        if (norecvCensusOn()) audit_mod.lm_localinit[1] += 1;
        return ctor_ty;
    }
    // An ALIAS takes the source local's type, whatever gave the source its
    // own: `val alias = made` where `made` came from a call's return type.
    if (init_expr.* == .Path and init_expr.Path.segments.len == 1) {
        if (try localInitTypeRef(b, init_expr)) |aliased| {
            if (norecvCensusOn()) audit_mod.lm_localinit[1] += 1;
            return aliased;
        }
        // A bare own-member snapshot: `val slots = slots` (the local's own
        // name is not in scope inside its initializer, so the reference is
        // the enclosing class's property) or `val w = writer` under another
        // name. The property's declared head types the local exactly as the
        // qualified `this.slots` read would.
        const src_name = init_expr.Path.segments[0].name;
        if (b.resolve(src_name) == null or std.mem.eql(u8, src_name, name)) {
            if (b.ownerClass()) |owner| {
                if (propTypeHeadOn(b, owner, src_name)) |head| {
                    // Two same-simple-name classes (the gapbuffer and
                    // linkbuffer SlotWriters) make a bare head ambiguous;
                    // resolve it through the reading file's import graph to
                    // the declaring class's FQN when possible.
                    const resolved_name: []const u8 = blk: {
                        const file = init_expr.Path.segments[0].span.file;
                        const cid = b.module.classIdIndexed(typeHead(head), b.self_package, file) orelse
                            b.module.classId(typeHead(head)) orelse break :blk head;
                        if (cid.int() >= b.module.classes.items.len) break :blk head;
                        break :blk b.module.classes.items[cid.int()].fqn;
                    };
                    if (norecvCensusOn()) audit_mod.lm_localinit[1] += 1;
                    return ir.TypeRef{
                        .name = try b.allocator.dupe(u8, resolved_name),
                        .nullable = false,
                        .args = &.{},
                    };
                }
            }
        }
    }
    // A property read carries its own declared type; nothing needs resolving.
    if (init_expr.* == .Member) {
        if (argDeclTypeRef(b, init_expr)) |declared| {
            if (norecvCensusOn()) audit_mod.lm_localinit[1] += 1;
            return try declared.clone(b.allocator);
        }
    }
    // The local's own name is not in scope inside its own initializer, so the
    // initializer's bare calls must not see it. `val iterator = iterator()` is
    // the shape, and the local shadowing the call is what stopped 10,088 of
    // these from lending a type.
    const prev_self = expr_mod.init_self_name;
    if (b.localInitNameFree(name) and !std.mem.eql(u8, runtime.envOnce("KLIO_INIT_SELF") orelse "1", "0")) expr_mod.init_self_name = name;
    defer expr_mod.init_self_name = prev_self;
    var derived = (try staticCallReturnTypeRef(b, init_expr)) orelse {
        if (norecvCensusOn()) {
            audit_mod.lm_localinit[2] += 1;
            if (runtime.envOnce("KLIO_LI_NAMES") != null and init_expr.* == .Call) {
                const c = init_expr.Call.callee;
                if (c.* == .Path and c.Path.segments.len == 1) {
                    std.debug.print("[li-null] {s}\n", .{c.Path.segments[0].name});
                } else if (c.* == .Member) {
                    std.debug.print("[li-null] .{s}\n", .{c.Member.name.name});
                } else std.debug.print("[li-null] <{s}>\n", .{@tagName(std.meta.activeTag(c.*))});
            }
        }
        return null;
    };
    if (!staticClassifierArgsComplete(b, derived)) {
        if (norecvCensusOn()) audit_mod.lm_localinit[3] += 1;
        derived.deinit(b.allocator);
        return null;
    }
    if (norecvCensusOn()) audit_mod.lm_localinit[4] += 1;
    return derived;
}

/// The declared return of the UNIQUE nullary top-level extension of `mname`
/// applicable to the receiver head — the for-loop protocol's answer for a
/// receiver whose `iterator()` is an extension, not a member
/// (`CharSequence.iterator(): CharIterator`). Disagreeing or generic
/// returns refuse.
pub fn extensionNullaryReturnTypeRef(
    b: *FuncBuilder,
    recv_ty: ir.TypeRef,
    mname: []const u8,
    out_fid: ?*?ir.FuncId,
) Allocator.Error!?ir.TypeRef {
    const recv_head = typeHead(std.mem.trimEnd(u8, recv_ty.name, "?"));
    if (recv_head.len == 0) return null;
    var agreed: ?ir.TypeRef = null;
    var agreed_fid: ?ir.FuncId = null;
    for (b.module.funcsBySimpleName(mname)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.kind == .instance_method or f.kind == .member_extension) continue;
        if (f.params.len != 1 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!b.module.classIsOrExtends(recv_head, typeHead(f.params[0].ty.name))) continue;
        if (!f.return_ty_declared or f.return_ty.name.len == 0 or
            bareTypeParamHead(f.return_ty.name))
        {
            if (agreed) |*prev| prev.deinit(b.allocator);
            return null;
        }
        if (agreed) |prev| {
            if (!std.mem.eql(u8, prev.name, f.return_ty.name)) {
                var p = prev;
                p.deinit(b.allocator);
                return null;
            }
            // Same return on a MORE SPECIFIC receiver keeps the more
            // specific declaration (String over CharSequence).
            if (b.module.funcById(agreed_fid.?)) |pf| {
                if (b.module.classIsOrExtends(typeHead(f.params[0].ty.name), typeHead(pf.params[0].ty.name)))
                    agreed_fid = fid;
            }
        } else {
            agreed = try f.return_ty.clone(b.allocator);
            agreed_fid = fid;
        }
    }
    if (out_fid) |slot| slot.* = agreed_fid;
    return agreed;
}

/// The trailing lambda's derived RETURN under concrete input param types —
/// a census-quiet probe. Serves the RECORDER-level star patch only: it
/// never feeds overload shapes (the shape-level variant measured
/// net-negative and is recorded as such in the plan).
fn lambdaReturnUnderParams(
    b: *FuncBuilder,
    lam_expr: *const Expr,
    in_tys: []const ir.TypeRef,
) Allocator.Error!?ir.TypeRef {
    if (lam_expr.* != .Lambda) return null;
    const lam = lam_expr.Lambda;
    const stmts = lam.body.stmts;
    if (stmts.len == 0 or stmts[stmts.len - 1] != .Expr) return null;
    if (expr_mod.od_depth >= 4) return null;
    var nb = try FuncBuilder.init(b.allocator, b.module);
    nb.census_quiet = true;
    defer nb.deinit();
    {
        var dit = b.local_decl_types.iterator();
        while (dit.next()) |e2| {
            nb.setLocalDeclTypeOwned(e2.key_ptr.*, e2.value_ptr.clone(b.allocator) catch continue) catch {};
        }
    }
    var i: usize = 0;
    while (i < in_tys.len) : (i += 1) {
        const pname = if (lam.params.len == 0 and in_tys.len == 1)
            "it"
        else if (i < lam.params.len)
            lam.params[i].name
        else
            return null;
        const dh = typeHead(std.mem.trimEnd(u8, in_tys[i].name, "?"));
        if (dh.len == 0 or bareTypeParamHead(dh) or
            ir.parseClassTypeParamIdentity(dh) != null) return null;
        nb.setLocalDeclTypeOwned(pname, in_tys[i].clone(b.allocator) catch return null) catch return null;
    }
    expr_mod.od_depth += 1;
    defer expr_mod.od_depth -= 1;
    const t = staticExprTypeRef(&nb, &stmts[stmts.len - 1].Expr) catch null;
    if (t) |ty| {
        const th = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
        if (th.len == 0 or bareTypeParamHead(th) or
            ir.parseClassTypeParamIdentity(th) != null)
        {
            var tt = ty;
            tt.deinit(b.allocator);
            return null;
        }
    }
    return t;
}

/// RECORDER-level star patch: a recorded call-return whose args contain
/// `*` (an unbound RETURN-position type parameter, star-erased by the
/// solve) re-derives the star from the call's trailing lambda when the
/// committed candidate's fn-typed last param returns exactly that
/// parameter (`groupBy(keySelector: (T) -> K): Map<K, List<T>>`). The
/// patch runs AFTER resolution — it improves the recorded local type and
/// feeds no overload shape.
pub fn patchStarredCallRecord(
    b: *FuncBuilder,
    recorded: *ir.TypeRef,
    call_expr: *const Expr,
) Allocator.Error!void {
    if (call_expr.* != .Call) return;
    const call = call_expr.Call;
    if (call.args.len == 0 or call.args[call.args.len - 1] != .Lambda) return;
    if (!allNull(call.arg_names)) return;
    var has_star = false;
    for (recorded.args) |ra| {
        if (std.mem.eql(u8, ra.name, "*")) has_star = true;
    }
    if (!has_star) return;
    if (call.callee.* != .Member) return;
    const mname = call.callee.Member.name.name;
    // The committed candidate: the receiver's unique lambda-hosting
    // extension of the name and shape.
    var recv_owned = (try staticExprTypeRef(b, call.callee.Member.receiver)) orelse return;
    defer recv_owned.deinit(b.allocator);
    const recv_head = typeHead(std.mem.trimEnd(u8, recv_owned.name, "?"));
    var target: ?FuncId = null;
    for (b.module.funcsBySimpleName(mname)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.kind == .instance_method or f.kind == .member_extension) continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (f.params.len - 1 != call.args.len) continue;
        if (!b.module.classIsOrExtends(recv_head, typeHead(f.params[0].ty.name))) continue;
        const lpt = f.params[f.params.len - 1].ty;
        const lph = typeHead(std.mem.trimEnd(u8, lpt.name, "?"));
        if (!std.mem.startsWith(u8, lph, "Function") and
            !std.mem.eql(u8, lph, "<function>")) continue;
        if (target != null) return;
        target = fid;
    }
    const tfid = target orelse return;
    const tf = b.module.funcById(tfid) orelse return;
    const lpt = tf.params[tf.params.len - 1].ty;
    if (lpt.args.len < 1) return;
    var rname = std.mem.trimEnd(u8, lpt.args[lpt.args.len - 1].name, "?");
    if (std.mem.startsWith(u8, rname, "in#")) rname = rname[3..];
    if (std.mem.startsWith(u8, rname, "out#")) rname = rname[4..];
    if (!bareTypeParamHead(rname)) return;
    // The starred position in the record must be exactly where the
    // declared return spells that parameter.
    if (!tf.return_ty_declared or tf.return_ty.args.len != recorded.args.len) return;
    var scratch = std.heap.ArenaAllocator.init(b.allocator);
    defer scratch.deinit();
    const a2 = scratch.allocator();
    const solved = (b.module.solveCallBindings(a2, tfid, tf, recv_owned, null, &.{}, &.{}, false) catch null) orelse return;
    const n_in = lpt.args.len - 1;
    const in_tys = a2.alloc(ir.TypeRef, n_in) catch return;
    for (lpt.args[0..n_in], in_tys) |raw, *slot| {
        slot.* = ir.Module.substituteBoundType(a2, raw, solved.bindings) catch return;
    }
    var lr = (try lambdaReturnUnderParams(b, &call.args[call.args.len - 1], in_tys)) orelse return;
    defer lr.deinit(b.allocator);
    for (tf.return_ty.args, recorded.args) |decl_arg, *rec_arg| {
        if (!std.mem.eql(u8, rec_arg.name, "*")) continue;
        var dn = std.mem.trimEnd(u8, decl_arg.name, "?");
        if (std.mem.startsWith(u8, dn, "in#")) dn = dn[3..];
        if (std.mem.startsWith(u8, dn, "out#")) dn = dn[4..];
        if (!std.mem.eql(u8, dn, rname)) continue;
        const patched = lr.clone(b.allocator) catch return;
        rec_arg.deinit(b.allocator);
        rec_arg.* = patched;
    }
}

/// The UNIQUE in-scope type-param bound whose class declares property `nm`
/// — the implicit-receiver chase's answer when the splice window's head is
/// a bare param with no bound record of its own.
pub fn implBoundScan(b: *FuncBuilder, nm: []const u8) ?[]const u8 {
    const bounds = (b.typeParamBoundsSlice() catch null) orelse return null;
    defer b.allocator.free(bounds);
    var hit: ?[]const u8 = null;
    for (bounds) |tb| {
        const bh = typeHead(std.mem.trimEnd(u8, tb.bound, "?"));
        if (bh.len == 0 or bh.len <= 2) continue;
        if (propTypeRefOn(b, bh, nm) != null or
            b.module.registry.class_prop_type_heads.get(.{ .a = bh, .b = nm }) != null)
        {
            if (hit != null) return null;
            hit = bh;
        }
    }
    return hit;
}

/// The companion object's own class type for a bare class-name reference in
/// value position, or null when the name is shadowed by a value binding or
/// names no class with a companion.
fn companionObjectTypeRef(b: *FuncBuilder, seg: ast.Ident) Allocator.Error!?ir.TypeRef {
    const nm = seg.name;
    if (nm.len == 0 or !std.ascii.isUpper(nm[0])) return null;
    if (b.resolve(nm) != null or b.knowsOuter(nm) or b.isLocalFn(nm) or b.isParam(nm)) return null;
    const cid = b.module.classIdIndexed(nm, b.self_package, seg.span.file) orelse
        b.module.uniqueClassIdBySimpleName(nm) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[cid.int()];
    const comp = b.module.registry.companion_singletons.get(cls.fqn) orelse
        b.module.registry.companion_singletons.get(cls.name) orelse return null;
    const ccid = b.module.classIdByFqn(comp) orelse
        b.module.uniqueClassIdBySimpleName(comp) orelse return null;
    if (ccid.int() >= b.module.classes.items.len) return null;
    return .{
        .name = try b.allocator.dupe(u8, b.module.classes.items[ccid.int()].fqn),
        .nullable = false,
        .args = &.{},
    };
}

pub fn buildStaticReturnArgShapes(
    b: *FuncBuilder,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!StaticReturnArgShapes {
    const shapes = try buildStaticArgShapes(b, args, arg_names);
    errdefer b.allocator.free(shapes);
    const inferred = try b.allocator.alloc(?ir.TypeRef, args.len);
    @memset(inferred, null);
    errdefer {
        for (inferred) |*ty| {
            if (ty.*) |*owned| owned.deinit(b.allocator);
        }
        b.allocator.free(inferred);
    }
    for (args, shapes, inferred) |*arg, *shape, *owned| {
        if (shape.ty != null) {
            // A bare class-name Path pre-typed as the class ITSELF is really
            // the companion value (Kotlin: a class name in value position IS
            // its companion). The companion's class record — which carries
            // its supertypes — is what a key-parameter solve projects from
            // (`context[ContinuationInterceptor]` binds E through the
            // companion's `CoroutineContext.Key<ContinuationInterceptor>`).
            if (arg.* == .Path and arg.Path.segments.len == 1 and
                std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, shape.ty.?.name, "?")), arg.Path.segments[0].name))
            {
                if (try companionObjectTypeRef(b, arg.Path.segments[0])) |ct| {
                    owned.* = ct;
                    shape.ty = ct;
                    shape.ty_authoritative = true;
                }
            }
            continue;
        }
        // A callable reference's function type is declaration-read and can
        // disambiguate the outer overload set, so it is shaped BEFORE any
        // resolution commits (the expected-arity refinement in
        // enrichCallableRefArgShapes serves the cases the probe declines).
        if (arg.* == .MemberRef and !std.mem.eql(u8, runtime.envOnce("KLIO_REFSHAPE") orelse "1", "0")) {
            owned.* = try callableRefDeclTypeRef(b, &arg.MemberRef, null);
        } else if (arg.* == .Path and arg.Path.segments.len == 1) {
            // A bare class name in VALUE position is its companion object
            // (`context[ContinuationInterceptor]` passes the companion,
            // whose class extends `CoroutineContext.Key<ContinuationInterceptor>`
            // — the record the key-parameter solve projects E from).
            owned.* = try companionObjectTypeRef(b, arg.Path.segments[0]);
        } else {
            owned.* = try staticCallReturnTypeRef(b, arg);
        }
        if (arg.* == .As) {
            const cast_head = std.mem.trimEnd(u8, arg.As.ty.name.name, "?");
            if (std.mem.eql(u8, cast_head, "Any")) shape.cast_any = true;
        }
        if (owned.*) |ty| {
            shape.ty = ty;
            // A CALL-RETURN derivation whose head is a bare type parameter
            // names the CALLEE's parameter, not the caller's: judging it
            // against the caller's same-named bound conflates scopes (a
            // method-level `T : CharSequence` shadowing the class's
            // `T : Number` disproved the Number overload kotlinc picks).
            // Keep it advisory — it types, but never disproves.
            const th = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
            shape.ty_authoritative = !(bareTypeParamHead(th) or ir.parseClassTypeParamIdentity(th) != null);
        }
    }
    return .{ .shapes = shapes, .inferred = inferred };
}

/// Build the `[]ArgShape` for a call's argument list once, before the
/// `resolveCall` query, replacing the per-rung `findCand` / `arityMatch`
/// walks. Borrows from `b.allocator` (a lowering scratch arena).
pub fn buildArgShapes(b: *FuncBuilder, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error![]applicability.ArgShape {
    const shapes = try b.allocator.alloc(applicability.ArgShape, args.len);
    for (args, 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        shapes[i] = shapeOfAstArg(b, a, nm);
    }
    return shapes;
}

/// Argument shapes admitted by an exact/static dispatch proof. The permissive
/// eager type-head fill remains useful for additive runtime ranking, but only
/// declared, cast, literal, and constructor evidence may reject a candidate.
pub fn buildStaticArgShapes(
    b: *FuncBuilder,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error![]applicability.ArgShape {
    const shapes = try buildArgShapes(b, args, arg_names);
    for (args, shapes) |*arg, *shape| {
        shape.ty = argDeclTypeRefLazy(b, arg);
        if (runtime.envOnce("KLIO_VALTY_TRACE")) |w| {
            if (arg.* == .Path and arg.Path.segments.len == 1 and std.mem.eql(u8, arg.Path.segments[0].name, w)) {
                std.debug.print("[valty] SHAPE {s} ty={s} in={s}\n", .{ w, if (shape.ty) |t| t.name else "<null>", build.currentRealFn() orelse "-" });
            }
        }
        shape.ty_authoritative = shape.ty != null;
    }
    return shapes;
}

/// Builtin value kind a declared parameter type accepts, or null when unknown
/// (a user class, a type parameter, `Any`, …) — those never disprove.
pub fn paramLitKind(type_name: []const u8) ?LitKind {
    const n = std.mem.trimEnd(u8, type_name, "?");
    const eq = std.mem.eql;
    if (eq(u8, n, "Int") or eq(u8, n, "Long") or eq(u8, n, "Short") or eq(u8, n, "Byte") or
        eq(u8, n, "UInt") or eq(u8, n, "ULong") or eq(u8, n, "UShort") or eq(u8, n, "UByte") or
        eq(u8, n, "Double") or eq(u8, n, "Float") or eq(u8, n, "Number")) return .numeric;
    if (eq(u8, n, "String") or eq(u8, n, "CharSequence")) return .string;
    if (eq(u8, n, "Boolean")) return .boolean;
    if (eq(u8, n, "Char")) return .char;
    return null;
}

/// True when a same-name factory's declared parameter types DEFINITELY cannot
/// accept the argument kinds — so the bare `Name(args)` constructs the class
/// rather than calling the factory. The argument kind comes from the same
/// evidence the shared scorer sees: a literal (direct or through a recorded
/// local initializer), a declared local/param type head, or the typeck
/// type-head channel (`Box(s.length)` inside `fun Box(s: String)` proves Int
/// against the factory's String and constructs the class). Conservative: an
/// unknown argument or parameter kind never disproves, so only a
/// known-kind-vs-builtin mismatch flips the decision.
fn factorySigRejectsArgs(b: *FuncBuilder, sig: []const ir.TypeRef, args: []const Expr) bool {
    for (args, 0..) |*a, i| {
        if (i >= sig.len) break;
        var ak_opt = argEvidenceLitKind(b, a);
        if (ak_opt == null) {
            if (argDeclTypeRef(b, a)) |ty| ak_opt = paramLitKind(ty.name);
        }
        const ak = ak_opt orelse continue;
        const pk = paramLitKind(sig[i].name) orelse continue;
        if (ak != pk) return true;
    }
    return false;
}

pub fn shadowedByClass(b: *FuncBuilder, callee: *const Expr, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!bool {
    if (callee.* != .Path or callee.Path.segments.len != 1) return false;
    const name = callee.Path.segments[0].name;
    // A LOCAL fn of the name (declared in an enclosing body — a test's
    // `@Composable fun Composition(a, b, c)`) is the nearest scope: it
    // shadows any same-named classifier (the pack's `interface
    // Composition`) for a bare call.
    if (b.local_fn_overloads.getPtr(name) != null) return false;
    // Resolve the class the SAME way the construct path below does — through
    // the scope-aware index (file imports, then self package, then global) —
    // not the simple-name-global `classId`, which picks an arbitrary winner on
    // a cross-package simple-name collision. Otherwise a bare `Name(args)` here
    // can be judged against the wrong same-named class (e.g. an abstract
    // `kotlinx.coroutines.internal.Segment` shadowing the concrete
    // `kotlinx.io.Segment` at its own construction site), inverting the
    // ctor-vs-factory decision.
    const cid = b.module.classIdIndexed(name, b.self_package, callee.Path.segments[0].span.file) orelse {
        if (runtime.envOnce("KLIO_SBC_TRACE")) |w| if (std.mem.eql(u8, w, name)) {
            std.debug.print("[sbc] {s} no-cid file={d}\n", .{ name, callee.Path.segments[0].span.file.int() });
        };
        return false;
    };
    if (runtime.envOnce("KLIO_SBC_TRACE")) |w| if (std.mem.eql(u8, w, name)) {
        const abs = cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_abstract;
        std.debug.print("[sbc] {s} cid={d} abstract={} nargs={d} file={d}\n", .{ name, cid.int(), abs, args.len, callee.Path.segments[0].span.file.int() });
    };
    if (runtime.envOnce("KLIO_NU_TRACE") != null and std.mem.eql(u8, name, "Density")) {
        const abs = cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_abstract;
        std.debug.print("[sbc] Density cid={d} abstract={} owner={s}\n", .{ cid.int(), abs, b.ownerClass() orelse "-" });
    }
    // An abstract/interface/sealed class cannot be constructed, so a bare
    // `Name(args)` is never a constructor call — it is a same-named factory
    // function (`fun Random(seed): Random`). Resolve it as a function (the
    // runtime global lookup finds the factory) rather than emitting a
    // `NewInstance` that aborts on the abstract class at run time.
    if (cid.int() < b.module.classes.items.len and b.module.classes.items[cid.int()].is_abstract) return false;
    const nargs = args.len;
    // Scope rule (spec: overload resolution walks scopes inside-out): inside
    // the class's own body — including its companion — the class's
    // constructor is a nearer-scope candidate than any same-named
    // package-level factory, so an applicable constructor decides the call.
    // `Path(normalized)` inside `Path.of` binds the private constructor; the
    // `fun Path(String)` factory calling back into `of` would recurse.
    if (b.ownerClass()) |oc| {
        // A companion body's owner is the lifted companion class; its name is
        // the class name with one or more `$Companion` suffixes. Stripping
        // them recovers the class whose scope the call sits in.
        var oc_base: []const u8 = oc;
        while (std.mem.endsWith(u8, oc_base, "$Companion")) {
            oc_base = oc_base[0 .. oc_base.len - "$Companion".len];
        }
        const in_own_scope = std.mem.eql(u8, oc_base, name) or blk: {
            if (cid.int() < b.module.classes.items.len) {
                if (b.module.classes.items[cid.int()].companion) |comp| {
                    if (comp.int() < b.module.classes.items.len) {
                        break :blk std.mem.eql(u8, b.module.classes.items[comp.int()].name, oc);
                    }
                }
            }
            break :blk false;
        };
        if (in_own_scope and cid.int() < b.module.classes.items.len) {
            const ps = b.module.classes.items[cid.int()].primary_params;
            var required: usize = 0;
            var has_vararg = false;
            for (ps) |*p| {
                if (p.is_vararg) {
                    has_vararg = true;
                    continue;
                }
                if (!p.has_default) required += 1;
            }
            // Inside the class's own scope the constructor is the innermost
            // candidate, so it wins whenever the arguments fit it (kotlinc
            // resolves the closest scope level with an applicable
            // candidate: `Path(pathString)` inside `class Path` is the
            // private constructor even though `fun Path(path: String)`
            // would take the call). Only when the argument types cannot
            // fit the constructor (`Color(0xFFFF0000)` in `Color`'s
            // companion: a Long literal, a `ULong` parameter) does an
            // applicable same-named function take over, deferred to the
            // runtime choice exactly as from any other site.
            if (nargs >= required and (has_vararg or nargs <= ps.len)) {
                if (!ctorSigRejectsArgs(b, ps, args)) return true;
                if (!anyFactoryApplicable(b, name, args, arg_names, callee.Path.segments[0].span.file)) return true;
            }
        }
    }
    // Scope rule: a MEMBER of the enclosing class hierarchy is a nearer-scope
    // candidate than a same-named foreign classifier — a bare `Test(...)`
    // inside a class declaring `fun Test(...)` calls the member, never
    // constructs an imported `kotlin.test.Test`. A class NESTED in the
    // enclosing chain keeps constructor semantics: its bare name also sits in
    // the member set, but a capitalized call to it is a constructor. Deciding
    // `false` here routes the call through `CallMemberOrGlobal`, whose runtime
    // scoring still reaches the constructor when no member actually binds.
    if (runtime.envOnce("KLIO_SBC_TRACE") != null) {
        std.debug.print("[sbc] {s} owner={s} own={} encl={} nested={}\n", .{ name, b.ownerClass() orelse "-", b.hasOwnMember(name), b.hasEnclosingMember(name), classNestedInEnclosing(b, cid) });
    }
    if (enclosingHasMemberNamed(b, name) and !classNestedInEnclosing(b, cid)) return false;
    // Scope rule: a captured outer binding of the name (a local `fun Test`
    // declared in an enclosing body, reaching this closure as a capture) is
    // a nearer-scope candidate than an imported classifier — `Test(1, 2)`
    // inside `r.go { … }` calls the local function, never constructs
    // `kotlin.test.Test`. Deciding false routes through the deferred
    // class-carrying form, whose runtime shadow gate lets the captured
    // callable win and still reaches the constructor when nothing binds.
    if (b.resolve(name) == null and (b.knowsOuter(name) or isLowerAnonCapture(name))) return false;
    // Only IN-SCOPE factories compete with the constructor: kotlinc never
    // considers an unimported cross-package `fun String(bytes, …)` (io.ktor's)
    // against `String(chars)` written in kotlin.text — without the tier
    // filter, pack load ORDER decided whether the builtin ctor won.
    const call_file = callee.Path.segments[0].span.file;
    if (lastArgIsLambda(args)) {
        // A trailing lambda routes to a same-named factory with a
        // function-typed param to receive it; only when none fits is it a ctor.
        var factory_takes_lambda = false;
        for (b.module.func_index.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const f = b.module.funcById(entry.id) orelse continue;
            if (b.module.scopeTier(f.fqn, f.package, name, b.self_package, call_file) > 3) continue;
            const last_vararg = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
            const arity_ok = last_vararg or nargs <= f.params.len;
            if (arity_ok and anyFunctionParam(f.params)) {
                factory_takes_lambda = true;
                break;
            }
        }
        return !factory_takes_lambda;
    }
    // No lambda — ctor when the canonical factory can't take that many args,
    // or no same-named factory is applicable to the positional count.
    var canonical_cant_take = false;
    if (b.module.funcId(name)) |fid| {
        if (b.module.funcById(fid)) |f| {
            const last_vararg = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
            canonical_cant_take = !last_vararg and nargs > f.params.len;
        }
    }
    const any_factory_applicable = anyFactoryApplicable(b, name, args, arg_names, call_file);
    return canonical_cant_take or !any_factory_applicable;
}

/// Whether a same-named function in scope (tier <= 3) can take these
/// arguments: the arity fits, every named argument names one of its
/// parameters (`Color(value = …)` inside `fun Color(color: Long)` names
/// only the constructor's parameter, so the function is out), and its
/// declared parameter types do not definitely reject the literal argument
/// types (what tells `Box(5)`, ctor `Box(Int)`, from the same-arity
/// factory `fun Box(s: String)`).
fn anyFactoryApplicable(b: *FuncBuilder, name: []const u8, args: []const Expr, arg_names: []const ?[]const u8, call_file: ir.FileId) bool {
    const nargs = args.len;
    for (b.module.func_index.items) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (b.module.funcById(entry.id)) |ff| {
            if (b.module.scopeTier(ff.fqn, ff.package, name, b.self_package, call_file) > 3) continue;
            if (!namedArgsNameParams(ff.params, arg_names)) continue;
        }
        if (b.module.decl_user_arity.get(entry.id.int())) |arity| {
            const n: u32 = @intCast(nargs);
            if (n >= arity.required and (arity.has_vararg or n <= arity.total)) {
                if (b.module.decl_user_sig.get(entry.id.int())) |sig| {
                    if (factorySigRejectsArgs(b, sig, args)) continue;
                }
                return true;
            }
        }
    }
    return false;
}

/// Whether the enclosing class scope (own members, outer-class members, or
/// the supertype hierarchy) declares a member named `name`.
/// Whether the enclosing class declares primary-ctor property `rn` with a
/// declared type that is a BARE class type parameter (`val expected: T` on
/// `CompareContext<out T>`). Such a receiver's member surface is the
/// parameter's bound; an in-scope receiver-taking callable of the called
/// name is what kotlinc commits.
fn classPropertyIsBareTp(b: *FuncBuilder, class_name: []const u8, rn: []const u8) ?bool {
    const cid = (if (std.mem.indexOfScalar(u8, class_name, '.') != null)
        b.module.classIdByFqn(class_name)
    else
        b.module.classId(class_name)) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const class = &b.module.classes.items[cid.int()];
    for (class.primary_params) |*p| {
        if (!std.mem.eql(u8, p.name, rn)) continue;
        var h = std.mem.trimEnd(u8, p.ty.name, "?");
        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
        if (ir.parseClassTypeParamIdentity(h) != null) return true;
        for (class.type_params) |tp| {
            if (std.mem.eql(u8, h, tp)) return true;
        }
        return false;
    }
    return null;
}

/// The enclosing class — or any implicit receiver on the TOWER (a closure
/// body inside a member-inline splice reaches the owner only through it) —
/// declares primary-ctor property `rn` with a declared type that is a BARE
/// class type parameter (`val expected: T` on `CompareContext<out T>`).
pub fn enclosingPropertyBareTp(b: *FuncBuilder, rn: []const u8) bool {
    if (b.ownerClass()) |owner| {
        if (classPropertyIsBareTp(b, owner, rn)) |ans| return ans;
    }
    for (b.implicit_receiver_tower.items) |entry| {
        if (classPropertyIsBareTp(b, entry.head, rn)) |ans| return ans;
    }
    return false;
}

pub fn enclosingHasMemberNamed(b: *FuncBuilder, name: []const u8) bool {
    if (b.hasOwnMember(name) or b.hasEnclosingMember(name)) return true;
    const oc = b.ownerClass() orelse return false;
    const hs = b.module.registry.hierarchy_shadow_names.get(oc) orelse return false;
    return hs.names.contains(name);
}

/// Whether class `cid` is declared inside the enclosing class chain (a
/// nested/inner class of the class being lowered or of one of its outers).
pub fn classNestedInEnclosing(b: *FuncBuilder, cid: ir.ClassId) bool {
    if (cid.int() >= b.module.classes.items.len) return false;
    const cls_name = b.module.classes.items[cid.int()].name;
    const enc = b.module.registry.enclosing_class.get(cls_name) orelse return false;
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (std.mem.eql(u8, o, enc)) return true;
        owner = b.module.registry.enclosing_class.get(o);
    }
    return false;
}

fn anyFunctionParam(params: []const ir.Param) bool {
    for (params) |p| {
        if (std.mem.startsWith(u8, p.ty.name, "Function")) return true;
    }
    return false;
}

/// Path-callee bare-name → Call ladder. Returns null when no top-level fn /
/// the class path should handle it instead.
/// The read side of a `var x by D` local: dispatch `D.getValue(null, ::x)` when
/// the hidden delegate binding is reachable here — bound in this scope, or
/// captured from an enclosing one. Null when `x` is not a mutable delegated
/// local (a plain local, or a `val x by lazy`, whose eager-once value stands).
/// The hidden binding a local `lateinit var name` declares beside its home
/// register. Its presence is what marks a read of `name` for the
/// uninitialized check; a nested lambda sees it through the captured-name
/// set exactly like the `$klio_delegate` binding of a delegated local.
pub fn lateinitMarkerName(b: *FuncBuilder, name: []const u8) Allocator.Error![]const u8 {
    const marker = try std.fmt.allocPrint(b.allocator, "{s}$klio_lateinit", .{name});
    defer b.allocator.free(marker);
    const id = try b.module.internConst(b.allocator, .{ .String = marker });
    return b.module.consts.items[id.int()].String;
}

/// Whether a read of local `name` reads a `lateinit var`. `home` is the
/// register the name resolved to in this builder (null when the name is
/// only reachable as a capture): the marker must be bound to that same
/// register, so a later same-named plain local or a lambda parameter that
/// shadows the lateinit reads unchecked; a capture slot re-bound under the
/// name defers to the captured-name set.
fn lateinitLocalMarked(b: *FuncBuilder, name: []const u8, home: ?Reg) bool {
    var namebuf: [512]u8 = undefined;
    const marker = std.fmt.bufPrint(&namebuf, "{s}$klio_lateinit", .{name}) catch return false;
    const outer = b.knowsOuter(marker) or isLowerAnonCapture(marker) or build.anonCaptureBinds(marker);
    const h = home orelse return outer;
    if (b.resolve(marker)) |m| return m.int() == h.int();
    if (b.captureReg(name)) |c| {
        if (c.int() == h.int()) return outer;
    }
    return false;
}

/// Guard a local read with the `lateinit` uninitialized check when the
/// name is a lateinit local; otherwise the value passes through.
pub fn lateinitLocalRead(b: *FuncBuilder, name: []const u8, value: Reg, home: ?Reg) Allocator.Error!Reg {
    if (!lateinitLocalMarked(b, name, home)) return value;
    const dst = b.allocReg();
    const n = try b.module.internConst(b.allocator, .{ .String = name });
    try b.push(.{ .LateinitCheck = .{ .dst = dst, .src = value, .name = n } });
    return dst;
}

pub fn lowerDelegateRead(b: *FuncBuilder, name: []const u8) Allocator.Error!?Reg {
    var namebuf: [512]u8 = undefined;
    const dname_stack = std.fmt.bufPrint(&namebuf, "{s}$klio_delegate", .{name}) catch return null;
    const in_scope = b.resolve(dname_stack) != null;
    const outer = b.knowsOuter(dname_stack);
    // An anonymous object's or local class's method closes over the
    // delegate binding like any other enclosing local.
    const anon = !in_scope and !outer and (isLowerAnonCapture(dname_stack) or build.anonCaptureBinds(dname_stack));
    if (!in_scope and !outer and !anon) return null;
    // An inner plain binding (a lambda/splice parameter, a shadowing
    // local) named like the delegated var outranks the delegate read.
    if (b.plainShadowsDelegate(name, dname_stack)) return null;
    const dname = try b.allocator.dupe(u8, dname_stack);
    const delegate = if (in_scope)
        b.resolve(dname).?
    else if (anon) blk: {
        const cell = try b.loadCaptureHoisted(dname);
        const dst = b.allocReg();
        try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
        break :blk dst;
    } else try resolveCapture(b, dname);
    const null_arg = try b.emitConst(.Null);
    const prop_ref = b.allocReg();
    const pname = try b.module.internConst(b.allocator, .{ .String = name });
    try b.push(.{ .PropertyRef = .{ .dst = prop_ref, .name = pname } });
    const args_start = b.allocReg();
    try b.push(.{ .Move = .{ .dst = args_start, .src = null_arg } });
    _ = b.allocReg();
    try b.push(.{ .Move = .{ .dst = Reg.from(args_start.int() + 1), .src = prop_ref } });
    const dst = b.allocReg();
    const getter = try b.module.internConst(b.allocator, .{ .String = "getValue" });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = delegate,
        .name = getter,
        .args = args_start,
        .n_args = 2,
        .arg_names = &.{},
    } });
    return dst;
}

/// Among the same-named EXTENSION overloads of `name`, the one whose leading
/// `this` receiver type matches the enclosing extension's receiver type. Lets an
/// ambiguous bare call inside an extension body resolve its arity/receiver-lambda
/// shape. Null when no enclosing receiver type is known or no single overload
/// matches.
/// Whether any same-named EXTENSION whose declared receiver head matches the
/// enclosing receiver type accepts `n_args` value arguments. Kotlin checks
/// implicit-receiver candidates before no-receiver ones, so such an extension
/// shadows a same-named file-private top-level function.
pub fn extOnEnclosingReceiverApplies(b: *FuncBuilder, name: []const u8, n_args: usize) bool {
    const recv = b.enclosingRecvTy() orelse return false;
    const recv_simple = simpleTypeHead(recv);
    const ids = b.module.func_name_index.get(name) orelse return false;
    for (ids.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!std.mem.eql(u8, simpleTypeHead(f.params[0].ty.name), recv_simple)) continue;
        const user_params = f.params.len - 1;
        var required: usize = 0;
        for (f.params[1..]) |*pp| {
            if (!pp.has_default and !pp.is_vararg) required += 1;
        }
        if (n_args >= required and n_args <= user_params) return true;
    }
    return false;
}

pub fn disambiguateByReceiver(b: *FuncBuilder, name: []const u8) ?FuncId {
    const recv = b.enclosingRecvTy() orelse return null;
    const recv_simple = simpleTypeHead(recv);
    const ids = b.module.func_name_index.get(name) orelse return null;
    var match: ?FuncId = null;
    for (ids.items) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!std.mem.eql(u8, simpleTypeHead(f.params[0].ty.name), recv_simple)) continue;
        if (match != null) return null;
        match = fid;
    }
    return match;
}

pub fn simpleTypeHead(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.indexOfScalar(u8, n, '<')) |lt| n = n[0..lt];
    if (std.mem.lastIndexOfScalar(u8, n, '.')) |dot| n = n[dot + 1 ..];
    return n;
}
