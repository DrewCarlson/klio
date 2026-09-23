//! Member and extension call lowering, plus the member-call fallback.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const inline_state = @import("../inline_state.zig");
const decl_mod = @import("../decl.zig");
const inline_call = @import("../inline_call.zig");
const lambda_body = @import("../lambda_body.zig");
const static_call_type = @import("../static_call_type.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunWithArity = helpers.lowerArgRunWithArity;
const lowerArgRunFull = helpers.lowerArgRunFull;
const internArgNames = helpers.internArgNames;
const isLowerAnonCapture = decl_mod.isLowerAnonCapture;
const tryInlineCallWithTypeArgs = inline_call.tryInlineCallWithTypeArgs;
const resolveCapture = lambda_body.resolveCapture;
const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const receiver_mod = @import("receiver.zig");
const lowerReceiver = receiver_mod.lowerReceiver;
const overloadPickByLambdaReturnFull = receiver_mod.overloadPickByLambdaReturnFull;
const resolveThisRegKind = receiver_mod.resolveThisRegKind;

const binary_mod = @import("binary.zig");
const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;

const member_mod = @import("member.zig");
const superBase = member_mod.superBase;

const lambda_mod = @import("lambda.zig");
const implicit_walk = @import("implicit_walk.zig");
const anyNamedArg = lambda_mod.anyNamedArg;
const argFnArities = lambda_mod.argFnArities;
const argFnGenericFlags = lambda_mod.argFnGenericFlags;
const argLambdaBroadMasks = lambda_mod.argLambdaBroadMasks;
const argLambdaParamTypesRecv = lambda_mod.argLambdaParamTypesRecv;
const deinitArgLambdaParamTypes = lambda_mod.deinitArgLambdaParamTypes;
const mapArgsToParams = lambda_mod.mapArgsToParams;
const recordLambdaArgReceivers = lambda_mod.recordLambdaArgReceivers;
const recordLambdaArgReceiversForCallReceiver = lambda_mod.recordLambdaArgReceiversForCallReceiver;
const substitutionRecv = lambda_mod.substitutionRecv;

const compose_mod = @import("compose.zig");
const argShapesHaveComposerPair = compose_mod.argShapesHaveComposerPair;
const ctorArgFnArities = compose_mod.ctorArgFnArities;
const ctorRealignedArgNames = compose_mod.ctorRealignedArgNames;
const hasComposerArgPair = compose_mod.hasComposerArgPair;
const selectedCallArgsForBuilder = compose_mod.selectedCallArgsForBuilder;
const selectedCallHasComposerAbi = compose_mod.selectedCallHasComposerAbi;

const call_mod = @import("call.zig");
const anyCastToAny = call_mod.anyCastToAny;
const anySpread = call_mod.anySpread;
const eagerAuditOn = call_mod.eagerAuditOn;
const lowerSpreadParts = call_mod.lowerSpreadParts;
const packContiguous = call_mod.packContiguous;

const emit_mod = @import("emit.zig");
const bareStaticRecvHead = emit_mod.bareStaticRecvHead;
const nestedClassIdAtLexicalSite = emit_mod.nestedClassIdAtLexicalSite;
const trailingLambdaArgNames = emit_mod.trailingLambdaArgNames;

const local_call_mod = @import("local_call.zig");
const lowerSelectedLocalExtCallWithReceiver = local_call_mod.lowerSelectedLocalExtCallWithReceiver;
const selectLocalExtOverload = local_call_mod.selectLocalExtOverload;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;
const noteUnknownArgShape = arg_shape_mod.noteUnknownArgShape;

const static_type_mod = @import("static_type.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const type_probe_mod = @import("type_probe.zig");
const buildStaticArgShapes = type_probe_mod.buildStaticArgShapes;
const buildStaticReturnArgShapes = type_probe_mod.buildStaticReturnArgShapes;
const enclosingHasMemberNamed = type_probe_mod.enclosingHasMemberNamed;
const enclosingPropertyBareTp = type_probe_mod.enclosingPropertyBareTp;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const eagerLambdaRecvHead = probe_mod.eagerLambdaRecvHead;
const memberCallArgArities = probe_mod.memberCallArgArities;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const DeclineKind = audit_mod.DeclineKind;
const NoClassKind = audit_mod.NoClassKind;
const NoRecvPath = audit_mod.NoRecvPath;
const PromoBlock = audit_mod.PromoBlock;
const classifyCallReturn = audit_mod.classifyCallReturn;
const declineNote = audit_mod.declineNote;
const lmNote = audit_mod.lmNote;
const norecvCensusOn = audit_mod.norecvCensusOn;
const noteNoClassHead = audit_mod.noteNoClassHead;
const orEmitAudit = audit_mod.orEmitAudit;

const tests_shapes_mod = @import("tests_shapes.zig");
const span = tests_shapes_mod.span;

/// Lower a member call once the shared resolver names its declaration. Final
/// and private declarations become `Call(FuncId)`, overridable class members
/// `CallVirtual(MethodSlotId)`.
const ResolvedMemberLowering = union(enum) {
    none,
    deferred,
    lowered: Reg,
};

const ReceiverState = struct {
    /// Already lowered, by a safe call that must not evaluate it twice.
    reg: ?Reg = null,
    /// Non-null here regardless of declared type, so a nullable declared type
    /// does not disqualify a member.
    non_null: bool = false,
};
/// The state one resolved-member-call ladder threads through its rungs.
///
/// The driver settles the receiver's type and owning class, then hands every
/// rung below a pointer to it. `owner_id` and `static_owner` are filled in
/// partway down and read by the rungs after; the order is Kotlin's resolution
/// order and is load-bearing.
const MemberCall = struct {
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    declared_ty: ?TypeRef,
    recv_state: ReceiverState,
    /// The receiver's declared or derived type, settled once `declared_ty` is
    /// known to be present.
    ty: TypeRef = undefined,
    /// `ty` with the `?` stripped: the type overload resolution ranks against.
    recv_ty: TypeRef = undefined,
    /// `ty`'s name with `?` and type arguments stripped.
    identity: []const u8 = &.{},
    /// `identity`'s last `.`-separated segment.
    head: []const u8 = &.{},
    /// The class declaring the member, once one is found.
    owner_id: ?ir.ClassId = null,
    /// `owner_id`, redirected to the companion for a classifier receiver.
    static_owner: ir.ClassId = undefined,
};

pub fn lowerResolvedMemberCall(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    declared_ty: ?TypeRef,
    recv_state: ReceiverState,
) Allocator.Error!ResolvedMemberLowering {
    if (ast_type_args.len != 0 or receiver.* == .Super) {
        if (receiver.* == .Super) lmNote(.super_receiver) else lmNote(.explicit_type_args);
        return .none;
    }
    last_member_refuted = false;
    var m = MemberCall{
        .b = b,
        .receiver = receiver,
        .name = name,
        .args = args,
        .ast_arg_names = ast_arg_names,
        .ast_type_args = ast_type_args,
        .declared_ty = declared_ty,
        .recv_state = recv_state,
    };
    if (try tryEagerExternPick(&m)) |r| return r;
    m.ty = declared_ty orelse return noReceiverTypeResult(&m);
    if (try tryNullableReceiverExtension(&m)) |r| return r;
    settleReceiverIdentity(&m);
    if (try resolveOwnerClass(&m)) |r| return r;
    if (try tryCastToAnyExtension(&m)) |r| return r;
    if (try tryLocalClassMemberSlot(&m)) |r| return r;
    m.static_owner = m.owner_id orelse return noClassIdResult(&m);
    if (try redirectClassifierToCompanion(&m)) |r| return r;
    return resolveAndEmitMemberCall(&m);
}

/// The checker's pick needs no receiver type, so it is asked ahead of the lazy
/// engine's receiver-type requirement. Image-declared extensions only.
fn tryEagerExternPick(m: *MemberCall) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    const name = m.name;
    const args = m.args;
    const declared_ty = m.declared_ty;

    if (declared_ty == null and !std.mem.eql(u8, runtime.envOnce("KLIO_EAGER_MEMBER") orelse "1", "0")) {
        if (b.module.eagerExternCallTarget(name.span)) |ep| ez: {
            audit_mod.lm_eager_norecv.bump(0);
            const ef = b.module.funcById(ep) orelse {
                audit_mod.lm_eager_norecv.bump(1);
                break :ez;
            };
            if (ef.params.len == 0 or !std.mem.eql(u8, ef.params[0].name, "this")) {
                audit_mod.lm_eager_norecv.bump(2);
                break :ez;
            }
            if (ef.params.len != args.len + 1) {
                audit_mod.lm_eager_norecv.bump(3);
                break :ez;
            }
            const recv_reg = try lowerExpr(b, receiver);
            const args_start = b.allocReg();
            const run = try lowerArgRun(b, args);
            try b.push(.{ .Move = .{ .dst = args_start, .src = recv_reg } });
            const dst = b.allocReg();
            lmNote(.bound_static);
            const ctx_handed = try probe_mod.contextHandoverBegin(b, ep, &.{});
            try b.push(.{ .Call = .{
                .dst = dst,
                .func = ep,
                .trailing_lambda = b.callTrailingLambda(),
                .args = args_start,
                .n_args = run[1] + 1,
                .arg_names = &.{},
                .type_args = &.{},
                .exact = true,
            } });
            try probe_mod.contextHandoverEnd(b, ctx_handed);
            return .{ .lowered = dst };
        }
    }
    return null;
}

/// No receiver type is known. A couple of forms still bind, and the rest feeds
/// the no-receiver census before declining.
fn noReceiverTypeResult(m: *MemberCall) Allocator.Error!ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    const name = m.name;
    const args = m.args;
    const ast_arg_names = m.ast_arg_names;
    const ast_type_args = m.ast_type_args;
    const recv_state = m.recv_state;

    if (runtime.envOnce("KLIO_EXT_TRACE")) |wanted| {
        if (std.mem.eql(u8, wanted, name.name)) {
            std.debug.print("[member-static] {s} recv=<unknown>\n", .{name.name});
        }
    }
// Kotlin binds the stdlib's `Any?` extensions `toString`/`hashCode` for a
// possibly-null receiver. Taken only when that extension is unique here.
    if (recv_state.reg == null and ast_type_args.len == 0) {
        if (allNull(ast_arg_names)) {
            if (uniqueAnyNullableExtension(b, name.name, args.len)) |fid| {
                const vals = try b.allocator.alloc(Reg, args.len + 1);
                defer b.allocator.free(vals);
                const rv = try lowerExpr(b, receiver);
                const recv_slot = b.allocReg();
                try b.push(.{ .Move = .{ .dst = recv_slot, .src = rv } });
                vals[0] = recv_slot;
                for (args, 0..) |*arg, i| vals[i + 1] = try lowerExpr(b, arg);
                const args_start = try packContiguous(b, vals);
                const dst = b.allocReg();
                const ctx_handed = try probe_mod.contextHandoverBegin(b, fid, ast_type_args);
                try b.push(.{ .Call = .{
                    .dst = dst,
                    .func = fid,
                    .trailing_lambda = false,
                    .args = args_start,
                    .n_args = @intCast(vals.len),
                    .arg_names = &.{},
                    .type_args = &.{},
                    .exact = true,
                } });
                try probe_mod.contextHandoverEnd(b, ctx_handed);
                lmNote(.bound_static);
                return .{ .lowered = dst };
            }
        }
    }
// A name whose only declaration is a universal inline extension (`T.let`
// and family) splices rather than dispatches.
    if (uniqueUniversalInlineExtension(b, name.name, args.len) != null) {
        lmNote(.bound_static);
        return .none;
    }
// Receiver typed by a bare type parameter with a receiver-taking callable
// value in scope: Kotlin resolves against the bound, finds no member, and
// commits the invoke protocol.
    if ((b.resolve(name.name) != null or b.knowsOuter(name.name)) and
        (b.isReceiverLambdaParam(name.name) or b.isLocalExtFn(name.name) or
            b.localDeclRecvFn(name.name)) and
        receiver.* == .Path and receiver.Path.segments.len == 1 and
        (b.isErasedRecvParam(receiver.Path.segments[0].name) or
            enclosingPropertyBareTp(b, receiver.Path.segments[0].name)))
    {
        lmNote(.dynamic_by_design);
        return .none;
    }
    recordNoReceiverCensus(b, receiver, name);
    return .none;
}

/// The no-receiver-type census: which receiver shape declined, and under
/// `KLIO_NORECV_NAMES` the name and site behind each one.
fn recordNoReceiverCensus(b: *FuncBuilder, receiver: *const Expr, name: ast.Ident) void {
    // The reason is counted for a type probe's consultation too, as every
    // other reason is; only the breakdown below, which walks declarations to
    // classify the shape, is skipped for one.
    lmNote(.no_receiver_type);
    if (b.census_quiet) return;
    if (!norecvCensusOn()) return;
    audit_mod.lm_norecv.bump(@intFromEnum(std.meta.activeTag(receiver.*)));
    if (receiver.* == .This and runtime.envOnce("KLIO_NORECV_NAMES") != null) {
        std.debug.print("[no-recv-this] call={s} fn={s} owner={s} recv={s} splice={s}\n", .{
            name.name,
            build.currentRealFn() orelse "-",
            b.ownerClass() orelse "-",
            b.recvTy() orelse "-",
            b.spliceRecvTy() orelse "-",
        });
    }
    audit_mod.lm_norecv_eager.bump(if (b.module.eagerTypeOf(receiver.span()) != null) 0 else 1);
    if (receiver.* == .Call) {
        audit_mod.lm_norecv_call.bump(@intFromEnum(classifyCallReturn(b, receiver)));
        if (runtime.envOnce("KLIO_NORECV_NAMES") != null) {
            const callee = receiver.Call.callee;
            const cn = switch (callee.*) {
                .Path => |cp| if (cp.segments.len != 0) cp.segments[cp.segments.len - 1].name else "?",
                .Member => |cm2| cm2.name.name,
                else => @tagName(std.meta.activeTag(callee.*)),
            };
            std.debug.print("[no-recv-callrecv] callee={s} kind={s} why={s} call={s} fn={s}\n", .{
                cn,
                @tagName(std.meta.activeTag(callee.*)),
                @tagName(classifyCallReturn(b, receiver)),
                name.name,
                build.currentRealFn() orelse "-",
            });
        }
    }
    if (receiver.* == .Binary) {
        if (runtime.envOnce("KLIO_NORECV_NAMES") != null) {
            std.debug.print("[no-recv-binary] op={s} call={s} fn={s}\n", .{
                @tagName(receiver.Binary.op),
                name.name,
                build.currentRealFn() orelse "-",
            });
        }
    }
    if (receiver.* == .Member) {
        if (runtime.envOnce("KLIO_NORECV_NAMES") != null) {
            std.debug.print("[no-recv-member] .{s} call={s} fn={s}\n", .{
                receiver.Member.name.name,
                name.name,
                build.currentRealFn() orelse "-",
            });
        }
    }
    if (receiver.* == .Call or receiver.* == .Index or receiver.* == .Postfix) {
        if (runtime.envOnce("KLIO_NORECV_NAMES") != null) {
            const inner_nm: []const u8 = switch (receiver.*) {
                .Call => |c2| if (c2.callee.* == .Member) c2.callee.Member.name.name else if (c2.callee.* == .Path and c2.callee.Path.segments.len != 0) c2.callee.Path.segments[c2.callee.Path.segments.len - 1].name else "?",
                .Index => "[]",
                .Postfix => @tagName(receiver.Postfix.op),
                else => "?",
            };
            std.debug.print("[no-recv-{s}] {s}() call={s} fn={s} recvty={s} splice={s} owner={s}\n", .{
                @tagName(std.meta.activeTag(receiver.*)),
                inner_nm,
                name.name,
                build.currentRealFn() orelse "-",
                b.recvTy() orelse "-",
                b.spliceRecvTy() orelse "-",
                b.ownerClass() orelse "-",
            });
        }
    }
    if (receiver.* == .Path and receiver.Path.segments.len > 1) {
        if (runtime.envOnce("KLIO_NORECV_NAMES") != null) {
            std.debug.print("[no-recv-multipath] {s}.{s} call={s} fn={s}\n", .{
                receiver.Path.segments[0].name,
                receiver.Path.segments[receiver.Path.segments.len - 1].name,
                name.name,
                build.currentRealFn() orelse "-",
            });
        }
    }
    recordNoReceiverPathCensus(b, receiver, name);
}

/// The census for a single-segment path receiver, which carries the most
/// actionable evidence: whether the name was a local with no declared type, a
/// capture, an enclosing member, or unknown.
fn recordNoReceiverPathCensus(b: *FuncBuilder, receiver: *const Expr, name: ast.Ident) void {
    if (!(receiver.* == .Path and receiver.Path.segments.len == 1)) return;

    const rn = receiver.Path.segments[0].name;
    const which: NoRecvPath = if (b.resolve(rn) != null)
        .local_no_decl_type
    else if (b.knowsOuter(rn))
        .captured
    else if (enclosingHasMemberNamed(b, rn))
        .enclosing_member
    else
        .unknown;
    audit_mod.lm_norecv_path.bump(@intFromEnum(which));
    if (runtime.envOnce("KLIO_NORECV_NAMES")) |want| {
        if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, @tagName(which))) {
            var nloc_buf: [256]u8 = undefined;
            const nloc: []const u8 = nblk: {
                if (span.active_map) |m| {
                    if (m.getChecked(name.span.file)) |sf| {
                        const lc = sf.lineCol(name.span.start);
                        const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |si| sf.path[si + 1 ..] else sf.path;
                        break :nblk std.fmt.bufPrint(&nloc_buf, "{s}:{d}", .{ base, lc.line }) catch "?";
                    }
                }
                break :nblk "?";
            };
            std.debug.print("[no-recv-name] {s} {s} at={s} owner={s} recv={s} call={s} fn={s} param={} splice={s} lam_recv={s}\n", .{
                @tagName(which),
                rn,
                nloc,
                b.ownerClass() orelse "<none>",
                bareStaticRecvHead(b) orelse "<none>",
                name.name,
                build.currentRealFn() orelse "-",
                b.isParam(rn),
                b.spliceRecvTy() orelse "-",
                b.recvTy() orelse "-",
            });
        }
    }
    traceNoReceiverLocalInit(b, receiver, which, rn);
}

/// `KLIO_NORECV_WHY=<name>`: print the lazy deriver's terminal for a local
/// whose initializer failed to type it.
fn traceNoReceiverLocalInit(b: *FuncBuilder, receiver: *const Expr, which: NoRecvPath, rn: []const u8) void {

    if (which == .local_no_decl_type) {
        if (b.localInitExpr(rn)) |ini| {
            audit_mod.lm_norecv_init.bump(1);
            audit_mod.lm_norecv_call.bump(@intFromEnum(classifyCallReturn(b, ini)));
            // `KLIO_NORECV_WHY=<name>`: print the lazy deriver's terminal.
            if (runtime.envOnce("KLIO_NORECV_WHY")) |want| {
                if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, rn)) {
                    const redo = argDeclTypeRefLazy(b, receiver);
                    const prev_self = expr_mod.init_self_name;
                    if (b.localInitNameFree(rn)) expr_mod.init_self_name = rn;
                    const full = staticCallReturnTypeRef(b, ini) catch null;
                    expr_mod.init_self_name = prev_self;
                    const why_head = b.recvTy() orelse b.spliceRecvTy() orelse b.enclosingRecvTy() orelse "-";
                    var wloc_buf: [256]u8 = undefined;
                    const wcs = ini.span();
                    const wloc: []const u8 = wblk: {
                        if (span.active_map) |m| {
                            if (m.getChecked(wcs.file)) |sf| {
                                const lc = sf.lineCol(wcs.start);
                                const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |i| sf.path[i + 1 ..] else sf.path;
                                break :wblk std.fmt.bufPrint(&wloc_buf, "{s}:{d}", .{ base, lc.line }) catch "?";
                            }
                        }
                        break :wblk "?";
                    };
                    std.debug.print("[norecv-why] at={s} {s} init_tag={s} free={} redo={s} full={s} in_fn={s} head={s} head_cid={} it_cid={} anon={} nfuncs={d}\n", .{
                        wloc,
                        rn,
                        @tagName(std.meta.activeTag(ini.*)),
                        b.localInitNameFree(rn),
                        if (redo) |r| r.name else "<null>",
                        if (full) |r| r.name else "<null>",
                        build.currentRealFn() orelse "-",
                        why_head,
                        b.module.uniqueClassIdBySimpleName(typeHead(std.mem.trimEnd(u8, why_head, "?"))) != null,
                        b.module.uniqueClassIdBySimpleName("Iterator") != null,
                        b.module.anon_side,
                        b.module.funcs.items.len,
                    });
                    if (redo) |r| {
                        var owned = r;
                        owned.deinit(b.allocator);
                    }
                    if (full) |r| {
                        var owned = r;
                        owned.deinit(b.allocator);
                    }
                }
            }
        } else audit_mod.lm_norecv_init.bump(0);
    }
}

/// An extension on `T?` outranks a member, so `x.f()` on a nullable `x` is only
/// legal when one exists. A safe call's member runs on the non-null branch.
fn tryNullableReceiverExtension(m: *MemberCall) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    const name = m.name;
    const args = m.args;
    const ast_arg_names = m.ast_arg_names;
    const ast_type_args = m.ast_type_args;
    const recv_state = m.recv_state;
    const ty = m.ty;

    if (ty.nullable and !recv_state.non_null) {
        // Unless the name declares no such extension, leaving the member as
        // Kotlin's only legal target. Checked module-wide.
        const nn_head = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
        var any_nullable_ext = false;
        for (b.module.funcsBySimpleName(name.name)) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
            if (!f.params[0].ty.nullable) continue;
            const eh = typeHead(std.mem.trimEnd(u8, f.params[0].ty.name, "?"));
            // Every type is an `Any`, including the unsigned value classes the class
            // table does not record a supertype for, so `Any?.toString()` covers a
            // nullable receiver of any head.
            const on_any = std.mem.eql(u8, eh, "Any") or std.mem.eql(u8, eh, "kotlin.Any");
            if (eh.len == 0 or on_any or std.mem.eql(u8, eh, nn_head) or
                b.module.classIsOrExtends(nn_head, eh))
            {
                any_nullable_ext = true;
                break;
            }
        }
        if (any_nullable_ext) {
            // Kotlin binds an extension statically, receiver in the leading
            // `this` slot. Only if unlowered, since this path lowers it.
            if (recv_state.reg == null and ast_type_args.len == 0) {
                ext_route_tag = "lowerResolvedMemberCall:19392";
                if (try lowerResolvedExtensionCall(
                    b,
                    receiver,
                    name,
                    args,
                    ast_arg_names,
                    ast_type_args,
                    ty,
                    false,
                )) |reg| {
                    lmNote(.bound_static);
                    return .{ .lowered = reg };
                }
            }
            if (runtime.envOnce("KLIO_NULLEXT_NAMES") != null) {
                std.debug.print("[nullext] {s}.{s} nargs={d} fn={s}\n", .{ nn_head, name.name, args.len, build.currentRealFn() orelse "-" });
            }
            lmNote(.nullable_or_generic);
            return .none;
        }
    }
    return null;
}

/// The non-null receiver type overload resolution ranks against, and the type's
/// head with `?` and type arguments stripped.
fn settleReceiverIdentity(m: *MemberCall) void {
    const ty = m.ty;

    m.recv_ty = if (ty.nullable)
        TypeRef{ .name = std.mem.trimEnd(u8, ty.name, "?"), .nullable = false, .args = ty.args }
    else
        ty;
    var identity = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    m.identity = identity;
    m.head = typeHead(identity);
}

/// The class whose hierarchy declares the member: the receiver's own class, a
/// type parameter's upper bound, a nested classifier resolved at this site, or
/// `Any` for a type-parameter-shaped head with no bound in scope. A
/// function-typed receiver dispatches by the invoke convention instead, and
/// declines here.
/// The class a receiver head names at `file`: an FQN as written, a simple
/// name the module holds once or the file's imports settle, a type
/// parameter's bound, a nested class by its qualified suffix or the lexical
/// classifier chain, and `Any` for a type-parameter-shaped head no bound in
/// scope names.
pub fn classIdForReceiverHead(b: *FuncBuilder, identity: []const u8, head: []const u8, file: ir.FileId, floor_unbounded: bool) ?ir.ClassId {
    // A type parameter in scope shadows any class of its name.
    var owner_id = if (std.mem.findScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else if (b.isTypeParam(head))
        null
    else
        b.module.uniqueClassIdBySimpleName(head) orelse b.module.classIdIndexed(head, b.self_package, file);

    // A receiver typed by a type parameter names no class; Kotlin resolves the
    // member against its upper bound. Only a `complete` bound: an incomplete
    // record dropped intersection or structural information.
    if (owner_id == null) {
        if (b.typeParamBound(head)) |tpb| {
            if (tpb.complete or (tpb.head_only and
                !std.mem.eql(u8, runtime.envOnce("KLIO_TP_HEAD") orelse "1", "0")))
            {
                var bound_identity = std.mem.trimEnd(u8, tpb.bound, "?");
                if (std.mem.findScalar(u8, bound_identity, '<')) |lt| bound_identity = bound_identity[0..lt];
                owner_id = if (std.mem.findScalar(u8, bound_identity, '.') != null)
                    b.module.classIdByFqn(bound_identity)
                else
                    b.module.uniqueClassIdBySimpleName(typeHead(bound_identity));
            }
        }
    }
    // Nested classes are deliberately absent from the module-wide simple-name
    // index, so resolve `Outer.Inner` as a `.`-aligned FQN suffix and a bare
    // nested name through the enclosing classifier chain.
    if (owner_id == null) {
        if (std.mem.findScalar(u8, identity, '.') != null) {
            owner_id = b.module.classIdByQualifiedSuffix(identity);
        } else if (!b.isTypeParam(head)) {
            owner_id = nestedClassIdAtLexicalSite(b, head);
        }
    }
    // A type-parameter-shaped head with no class and no bound in scope belongs
    // to an enclosing generic, whose floor in Kotlin is `Any?`. Only for a
    // head written at the site: one recorded from another declaration's
    // signature is that declaration's parameter, uninstantiated, and names
    // nothing here.
    if (floor_unbounded and owner_id == null and head.len != 0 and
        (((head.len <= 2) and std.ascii.isUpper(head[0]) and b.module.classId(head) == null) or
            ir.parseClassTypeParamIdentity(head) != null))
    {
        owner_id = b.module.uniqueClassIdBySimpleName("Any") orelse
            b.module.classIdByFqn("kotlin.Any");
    }
    return owner_id;
}

fn resolveOwnerClass(m: *MemberCall) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const name = m.name;
    const identity = m.identity;
    const head = m.head;
    const owner_id = classIdForReceiverHead(b, identity, head, name.span.file, true);
    // A function-typed receiver dispatches by the invoke convention, not a
    // class slot, so it has no class row to bind.
    if (owner_id == null) {
        const fhead = blk_f: {
            if (std.mem.startsWith(u8, head, "Function") or
                std.mem.startsWith(u8, head, "SuspendFunction") or
                std.mem.startsWith(u8, head, "KFunction")) break :blk_f true;
            var alias_scratch = std.heap.ArenaAllocator.init(b.allocator);
            defer alias_scratch.deinit();
            const expanded = b.module.resolveTypeAliasAt(
                alias_scratch.allocator(),
                .{ .name = identity, .nullable = false, .args = &.{} },
                name.span.file,
                b.module.packageOfFile(name.span.file) orelse b.self_package,
            ) catch break :blk_f false;
            const eh = typeHead(std.mem.trimEnd(u8, expanded.name, "?"));
            break :blk_f std.mem.startsWith(u8, eh, "Function") or
                std.mem.startsWith(u8, eh, "SuspendFunction") or
                std.mem.startsWith(u8, eh, "KFunction") or
                std.mem.eql(u8, eh, "<function>");
        };
        if (fhead) {
            lmNote(.dynamic_by_design);
            return .none;
        }
    }
    m.owner_id = owner_id;
    return null;
}

/// An argument written `expr as Any` fits no member whose parameter has a
/// concrete class type; kotlinc binds the same-named extension instead.
fn tryCastToAnyExtension(m: *MemberCall) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    const name = m.name;
    const args = m.args;
    const ast_arg_names = m.ast_arg_names;
    const ast_type_args = m.ast_type_args;
    const recv_state = m.recv_state;
    const ty = m.ty;
    const owner_id = m.owner_id;

    if (owner_id) |oid| {
        if (recv_state.reg == null and ast_type_args.len == 0 and anyCastToAny(args) and
            b.module.classHierarchyDeclaresMember(oid, name.name))
        {
            const cast_shapes = try buildStaticArgShapes(b, args, ast_arg_names);
            defer b.allocator.free(cast_shapes);
            const res = b.module.resolveMemberCall(oid, name.name, cast_shapes, .{
                .caller_file = name.span.file,
                .lexical_owner = if (b.ownerClass()) |owner_name| b.module.classId(owner_name) else null,
                .receiver_type = ty,
            });
            if (!res.applicable and res.target == null) {
                const ext = try lowerResolvedExtensionCall(b, receiver, name, args, ast_arg_names, ast_type_args, ty, false);
                if (ext) |reg| {
                    lmNote(.bound_static);
                    return .{ .lowered = reg };
                }
            }
        }
    }
    return null;
}

/// A local-class typing record has no class row, but its mangled head
/// registered methods as headers, so bind the virtual slot directly.
fn tryLocalClassMemberSlot(m: *MemberCall) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    const name = m.name;
    const args = m.args;
    const ast_arg_names = m.ast_arg_names;
    const ast_type_args = m.ast_type_args;
    const owner_id = m.owner_id;
    const head = m.head;

    if (owner_id == null and ast_type_args.len == 0 and allNull(ast_arg_names) and
        // Only the `$lc` mangle: `class_super_names` is the general super
        // registry, and probing it for any row-less head binds pack stubs over
        // their host bindings.
        std.mem.find(u8, head, "$lc") != null and
        b.module.registry.class_super_names.get(head) != null)
    {
        var kb: [192]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}\x00{s}\x00{d}", .{ head, name.name, args.len }) catch return null;
        if (b.module.registry.member_method_fids.get(key)) |fid| {
            const recv_reg = m.recv_state.reg orelse try lowerExpr(b, receiver);
            const run = try lowerArgRun(b, args);
            const dst = b.allocReg();
            orEmitAudit(b, "local_class_member_slot", "CallVirtual", name.name);
            const ctx_handed = try probe_mod.contextHandoverBegin(b, fid, ast_type_args);
            try b.push(.{ .CallVirtual = .{
                .dst = dst,
                .receiver = recv_reg,
                .slot = ir.MethodSlotId.fromFunc(fid),
                .args = run[0],
                .n_args = run[1],
            } });
            try probe_mod.contextHandoverEnd(b, ctx_handed);
            lmNote(.bound_virtual);
            return .{ .lowered = dst };
        }
    }
    return null;
}

/// No class row for the receiver's head: record why and decline.
fn noClassIdResult(m: *MemberCall) ResolvedMemberLowering {
    const b = m.b;
    const name = m.name;
    const identity = m.identity;
    const head = m.head;

    lmNote(.no_class_id);
    noteNoClassHead(head);
    if (norecvCensusOn()) {
        const k: NoClassKind = if (std.mem.findScalar(u8, identity, '.') != null)
            .fqn_unknown
        else if (b.module.classId(head) != null)
            .simple_ambiguous
        else
            .simple_unknown;
        audit_mod.lm_noclass.bump(@intFromEnum(k));
        if (runtime.envOnce("KLIO_NOCLASS_HEADS") != null) {
            if (b.typeParamBound(head)) |tpb| {
                std.debug.print("[no-class-head] {s} bound={s} complete={} head_only={}\n", .{ head, tpb.bound, tpb.complete, tpb.head_only });
            } else {
                std.debug.print("[no-class-head] {s} id={s} no-bound-record tp={} call={s} fn={s} owner={s}\n", .{
                    head,
                    identity,
                    b.isTypeParam(head),
                    name.name,
                    build.currentRealFn() orelse "-",
                    b.ownerClass() orelse "-",
                });
            }
        }
    }
    return .none;
}

/// A bare name resolving to nothing lexically is a class-name access (members
/// on the companion) only when no enclosing receiver declares a property of
/// that name.
fn redirectClassifierToCompanion(m: *MemberCall) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    var static_owner = m.static_owner;

    if (receiver.* == .Path and receiver.Path.segments.len != 0) {
        const receiver_name = receiver.Path.segments[receiver.Path.segments.len - 1].name;
        // A bare name resolving to nothing lexically is a class-name access
        // (members on the companion) only when no enclosing receiver declares a
        // property of that name.
        if (b.resolve(receiver_name) == null and !b.knowsOuter(receiver_name) and
            !enclosingHasMemberNamed(b, receiver_name) and
            // A top-level property read is a value receiver, not a classifier.
            b.module.registry.top_level_prop_pkgs.get(receiver_name) == null and
            static_owner.int() < b.module.classes.items.len)
        {
            const classifier = &b.module.classes.items[static_owner.int()];
            if (!classifier.is_object) {
                static_owner = classifier.companion orelse return ResolvedMemberLowering.none;
            }
        }
    }
    m.static_owner = static_owner;
    return null;
}


/// Rank the overload set against the argument shapes, settle the dispatch kind,
/// then emit the call the pick names.
fn resolveAndEmitMemberCall(m: *MemberCall) Allocator.Error!ResolvedMemberLowering {
    const b = m.b;
    const name = m.name;
    const args = m.args;
    const ast_arg_names = m.ast_arg_names;
    const ty = m.ty;
    const recv_ty = m.recv_ty;
    const static_owner = m.static_owner;

    var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const shapes = shape_set.shapes;
    const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
        (if (std.mem.findScalar(u8, owner_name, '.') != null)
            b.module.classIdByFqn(owner_name)
        else
            (b.module.classIdIndexed(owner_name, b.self_package, name.span.file) orelse b.module.classId(owner_name)))
    else
        null;
    const owned_type_param_bounds = try b.typeParamBoundsSlice();
    defer if (owned_type_param_bounds) |bounds| b.allocator.free(bounds);
    var resolved = b.module.resolveMemberCall(static_owner, name.name, shapes, .{
        .caller_file = name.span.file,
        .lexical_owner = lexical_owner,
        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
        .receiver_type = recv_ty,
    });
    traceMemberStatic(name, ty, resolved, owned_type_param_bounds, shapes);

    if (selfRecursiveUndecided(b, name, resolved, shapes)) {
        lmNote(.self_recursive_undecided);
        return .none;
    }
    const eager_pick = eagerMemberPick(b, name, resolved);

    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name.name)) {
            std.debug.print("[lrm] {s} owner={s} dispatch={s} applicable={} target={?d} eager={?d} nargs={d} shapes:", .{ name.name, b.module.classes.items[static_owner.int()].fqn, @tagName(resolved.dispatch), resolved.applicable, if (resolved.target) |t| t.int() else null, if (eager_pick) |e| e.int() else null, args.len });
            for (shapes) |*sh| std.debug.print(" {s}{s}", .{ if (sh.ty) |t| t.name else "?", if (sh.is_lambda) "(lambda)" else "" });
            std.debug.print("\n", .{});
        }
    }
    const func_id = eager_pick orelse resolved.target orelse {
        last_member_refuted = !resolved.applicable;
        // `resolver_declined` is a member that applies whose dispatch the gate
        // withheld; naming no declaration at all is a different gap and was
        // counted as nothing, which is why the by-name emissions outnumbered
        // the recorded declines by thousands.
        if (resolved.applicable)
            lmNote(.ambiguous_member)
        else if (resolved.saw_candidates)
            lmNote(.member_shape_refused)
        else if (hostBackedOwner(b, static_owner))
            lmNote(.no_member_stub_owner)
        else
            lmNote(.no_member_by_name);
        return if (resolved.applicable) .deferred else .none;
    };
    // A host-shadowed declaration (a pack stub whose installed binding is
    // authoritative) must never statically bind its interpreted body.
    if (b.module.funcById(func_id)) |cf| {
        if (cf.hasBody() and b.module.registry.host_shadowed_fqns.contains(cf.fqn)) {
            lmNote(.host_shadowed);
            return .deferred;
        }
    }
    if (eagerAuditOn()) {
        if (eager_pick) |ep| {
            const lazy_str: i64 = if (resolved.target) |l| @intCast(l.int()) else -1;
            const efqn: []const u8 = if (b.module.funcById(ep)) |f| f.fqn else "?";
            std.debug.print("[EAGER-MEMBER-HIT] '{s}': eager={d}({s}) lazy={d}\n", .{ name.name, ep.int(), efqn, lazy_str });
        }
    }
    const promo_ext_why = promotionExtWhy(m, resolved, shapes);
    if (try settleDispatchKind(m, &resolved, shapes, promo_ext_why, eager_pick)) |r| return r;
    var target = b.module.funcById(func_id) orelse {
        lmNote(.resolver_declined);
        if (norecvCensusOn()) audit_mod.lm_decline.bump(@intFromEnum(DeclineKind.target_unresolvable));
        return .deferred;
    };

    if (resolved.dispatch == .virtual) {
        const owner = &b.module.classes.items[static_owner.int()];
        // A final target on a closed stub/value class never needs the slot, and
        // its vtable-less representation cannot serve one.
        if (owner.is_value or owner.is_stub) {
            if (b.module.dispatchForTarget(static_owner, func_id)) |d2| {
                if (d2 == .direct) resolved.dispatch = .direct;
            }
        }
    }
    const has_spread = anySpread(args);
    if (resolved.dispatch == .direct and has_spread) {
        declineNote(.direct_spread);
        return .deferred;
    }
    if (virtualAbiDeclines(m, resolved, func_id)) |r| return r;
    return emitResolvedMemberCall(m, func_id, &target, resolved, has_spread);
}

/// kotlinc rejects a member whose invariant generic argument mismatches and
/// only the runtime holds the deciding values, so a self-recursive pick with a
/// non-authoritative argument defers to the runtime walk.
fn selfRecursiveUndecided(
    b: *FuncBuilder,
    name: ast.Ident,
    resolved: ir.Module.MemberResolution,
    shapes: []const applicability.ArgShape,
) bool {

    if (resolved.target) |rt| {
        const cur = build.currentRealFn() orelse return false;
        if (!std.mem.eql(u8, cur, name.name)) return false;
        const rf = b.module.funcById(rt) orelse return false;
        if (!std.mem.eql(u8, rf.name, name.name)) return false;
        if (targetIsAnotherDeclaration(b, rt)) return false;
        if (runtime.envOnce("KLIO_EXT_TRACE")) |w| {
            if (std.mem.eql(u8, w, name.name)) {
                for (shapes, 0..) |sh, i| {
                    std.debug.print("[self-rec-shape] {s} #{d} ty={s} targs={d} targ0={s} lit={} lambda={}\n", .{
                        name.name,
                        i,
                        if (sh.ty) |t| t.name else "<null>",
                        if (sh.ty) |t| t.args.len else 0,
                        if (sh.ty != null and sh.ty.?.args.len > 0) sh.ty.?.args[0].name else "-",
                        sh.literal_kind != null,
                        sh.is_lambda,
                    });
                }
            }
        }
        for (shapes) |sh| {
            const undecided = blk: {
                const t = sh.ty orelse break :blk sh.literal_kind == null and !sh.is_lambda;
                // An unresolved generic head cannot prove the invariant argument.
                for (t.args) |ta| {
                    const an = std.mem.trimEnd(u8, ta.name, "?");
                    if (std.mem.eql(u8, an, "*")) break :blk true;
                    if (an.len > 0 and an.len <= 2 and std.ascii.isUpper(an[0])) break :blk true;
                }
                break :blk false;
            };
            if (undecided) return true;
        }
    }
    return false;
}

/// Whether the resolved target is provably not the declaration being lowered,
/// however much the names agree. A member of the receiver's class is not the
/// top-level function containing the call: `Sequence<T>.flatten(iterator)`
/// calls `TransformingSequence.flatten` on a narrowed receiver, and reading
/// that as recursion leaves the member unbound for an extension to take —
/// the extension being the enclosing function itself.
fn targetIsAnotherDeclaration(b: *FuncBuilder, rt: FuncId) bool {
    const sig = b.module.decl_sigs.get(rt.int()) orelse return false;
    if (sig.kind != .instance_method) return false;
    const recv = sig.receiver_ty orelse return false;
    const target_owner = applicability.simpleName(typeHead(std.mem.trimEnd(u8, recv.name, "?")));
    if (target_owner.len == 0) return false;
    // A top-level declaration owns no class, so any instance method is another.
    const own = b.ownerClass() orelse return true;
    return !std.mem.eql(u8, applicability.simpleName(own), target_owner);
}

/// Promote a deferred pick to a real dispatch kind where the evidence proves
/// it, and hand back a deferral where it does not.
fn settleDispatchKind(
    m: *MemberCall,
    resolved: *ir.Module.MemberResolution,
    shapes: []const applicability.ArgShape,
    promo_ext_why: ir.Module.ExtCouldApplyWhy,
    eager_pick: ?FuncId,
) Allocator.Error!?ResolvedMemberLowering {
    const b = m.b;
    const name = m.name;
    const args = m.args;
    const recv_ty = m.recv_ty;
    const head = m.head;
    const static_owner = m.static_owner;

    // Proof by refutation: the member compatible and every reachable same-name
    // extension refuted (`KLIO_MEMBER_PROMO=0` disables). A stub/value receiver
    // does not block it, since the runtime resolves the slot against the
    // receiver's class and prefers the FQN-keyed intrinsic for host values.
    if (promo_ext_why != .none and
        resolved.dispatch == .deferred and resolved.target != null and
        !std.mem.eql(u8, runtime.envOnce("KLIO_MEMBER_PROMO") orelse "1", "0"))
    {
        const owned_bounds_promo = try b.typeParamBoundsSlice();
        defer if (owned_bounds_promo) |bnd| b.allocator.free(bnd);
        if (b.module.memberPromotionProven(
            resolved.target.?,
            head,
            name.name,
            recv_ty,
            shapes,
            owned_bounds_promo orelse &.{},
        )) {
            if (runtime.envOnce("KLIO_PROMO_NAMES") != null) {
                std.debug.print("[promo-proof] {s}.{s} nargs={d} PROMOTED\n", .{ head, name.name, args.len });
            }
            if (b.module.dispatchForTarget(static_owner, resolved.target.?)) |d| {
                resolved.dispatch = d;
            }
        } else {
            if (runtime.envOnce("KLIO_PROMO_NAMES") != null) {
                std.debug.print("[promo-proof] {s}.{s} nargs={d} HELD why={s}\n", .{ head, name.name, args.len, ir.Module.mpp_why });
                if (std.mem.eql(u8, ir.Module.mpp_why, "arg-unauthoritative")) {
                    for (shapes, 0..) |sh, i| {
                        if (sh.ty != null or sh.literal_kind != null or sh.is_lambda) continue;
                        if (i < args.len) noteUnknownArgShape("promo-unauth", &args[i]);
                    }
                }
            }
            // A refuted member is not the binding: fall to the extension path
            // with the refutation recorded, so the strict-winner rule commits.
            if (std.mem.eql(u8, ir.Module.mpp_why, "member-arg-refuted")) {
                last_member_refuted = true;
                lmNote(.member_arg_refuted);
                return ResolvedMemberLowering.none;
            }
        }
    }
    if (promo_ext_why == .none and
        resolved.dispatch == .deferred and resolved.target != null)
    {
        // A final or private method has no vtable slot and a virtual emission
        // for one fails at runtime, so ask the resolver rather than assume.
        if (b.module.dispatchForTarget(static_owner, resolved.target.?)) |d| {
            resolved.dispatch = d;
        }
    }
    if (eager_pick) |ep| {
        // The resolver named no target, so its `deferred` means only that. An
        // extension's call form follows from the declaration; a class member
        // needs a slot the resolver never proved.
        if (b.module.funcById(ep)) |ef| {
            if (ef.params.len != 0 and std.mem.eql(u8, ef.params[0].name, "this")) {
                resolved.dispatch = .direct;
            }
        }
    }
    // A value class has no runtime dispatch to defer to: its instances travel
    // unboxed, so a deferred call would miss on the underlying value's class.
    if (resolved.dispatch == .deferred and resolved.target != null and resolved.applicable) {
        const owner_cls = &b.module.classes.items[static_owner.int()];
        if (owner_cls.is_value) {
            resolved.dispatch = b.module.dispatchForTarget(static_owner, resolved.target.?) orelse .direct;
            if (resolved.dispatch == .deferred) resolved.dispatch = .direct;
        }
    }
    if (resolved.dispatch == .deferred) {
        lmNote(.resolver_declined);
        // The gate named the declaration and withheld the dispatch, which is
        // the same shape the extension resolver's withheld pick had: exactly
        // one candidate whose argument compatibility is unknown. Carry it so
        // the per-site audit can say whether committing would name what the
        // runtime serves.
        withheld_member_pick = resolved.target;
        if (norecvCensusOn()) {
            const k: DeclineKind = if (resolved.target != null)
                .target_known_deferred
            else if (resolved.applicable)
                .ambiguous_applicable
            else
                .not_applicable;
            audit_mod.lm_decline.bump(@intFromEnum(k));
        }
        return ResolvedMemberLowering.deferred;
    }
    return null;
}

/// Numeric virtual slots operate on `Value.Instance`; classifier ABI metadata
/// keeps mixed host-backed receivers on the host member path.
fn virtualAbiDeclines(
    m: *MemberCall,
    resolved: ir.Module.MemberResolution,
    func_id: FuncId,
) ?ResolvedMemberLowering {
    const b = m.b;
    const name = m.name;
    const ast_type_args = m.ast_type_args;
    const static_owner = m.static_owner;

    if (resolved.dispatch == .virtual) {
        const owner = &b.module.classes.items[static_owner.int()];
        // Numeric virtual slots operate on `Value.Instance`; classifier ABI
        // metadata keeps mixed host-backed receivers on the host member path.
        // Stub/value owners emit their slot too (`KLIO_VOWN=0` disables):
        // `invokeVirtualMember` resolves it against an interpreted receiver's
        // own class and name-falls-back for a host-backed value.
        const vown_hold = (owner.is_value or owner.is_stub) and
            std.mem.eql(u8, runtime.envOnce("KLIO_VOWN") orelse "1", "0");
        if (vown_hold or ast_type_args.len != 0) {
            declineNote(if (owner.is_value)
                .virtual_owner_value
            else if (owner.is_stub)
                .virtual_owner_stub
            else
                .virtual_type_args);
            if (runtime.envOnce("KLIO_VABI_NAMES") != null) {
                const t = b.module.funcById(func_id);
                const sig = b.module.decl_sigs.get(func_id.int());
                std.debug.print("[vabi] {s}.{s} abi={s} has_body={} nblocks={d}\n", .{
                    owner.fqn,
                    name.name,
                    @tagName(owner.receiver_abi),
                    if (sig) |sg| sg.has_body else false,
                    if (t) |tf| tf.blocks.len else 0,
                });
            }
            return ResolvedMemberLowering.deferred;
        }
    }
    return null;
}

/// `KLIO_EXT_TRACE=<name>`: the pick, its dispatch kind, and the bounds and
/// argument shapes it was ranked against.
fn traceMemberStatic(
    name: ast.Ident,
    ty: TypeRef,
    resolved: ir.Module.MemberResolution,
    owned_type_param_bounds: ?[]const ir.ModuleRegistry.TypeParamBound,
    shapes: []const applicability.ArgShape,
) void {

    if (runtime.envOnce("KLIO_EXT_TRACE")) |wanted| {
        if (std.mem.eql(u8, wanted, name.name)) {
            std.debug.print(
                "[member-static] {s} recv={s} target={?d} dispatch={s} applicable={}\n",
                .{
                    name.name,
                    ty.name,
                    if (resolved.target) |target| target.int() else null,
                    @tagName(resolved.dispatch),
                    resolved.applicable,
                },
            );
            for (owned_type_param_bounds orelse &.{}) |bound| {
                std.debug.print(
                    "[member-static-bound] {s} <: {s} complete={}\n",
                    .{ bound.param, bound.bound, bound.complete },
                );
            }
            for (shapes, 0..) |sh, i| {
                std.debug.print("[member-static-shape] #{d} ty={s} auth={}\n", .{ i, if (sh.ty) |t| t.name else "<null>", sh.ty_authoritative });
            }
        }
    }
}

/// The checker's pick ranks by argument type, which the shape-based lazy
/// ranking cannot. Taken only where the resolver reached no target, since
/// downstream reads `resolved` for dispatch kind, owner, and arity.
fn eagerMemberPick(b: *FuncBuilder, name: ast.Ident, resolved: ir.Module.MemberResolution) ?FuncId {

    if (std.mem.eql(u8, runtime.envOnce("KLIO_EAGER_MEMBER") orelse "1", "0")) return null;
    return blk: {
        const ep = b.module.eagerExternCallTarget(name.span) orelse break :blk null;
        const ef = b.module.funcById(ep) orelse break :blk null;
        if (ef.params.len == 0 or !std.mem.eql(u8, ef.params[0].name, "this")) break :blk null;
        // Where the resolver did name one, the pick replaces it only for the
        // same call form: downstream reads `resolved` for the call shape.
        if (resolved.target) |rt| {
            if (rt.int() == ep.int()) break :blk null;
            const rf = b.module.funcById(rt) orelse break :blk null;
            if (rf.params.len == 0 or !std.mem.eql(u8, rf.params[0].name, "this")) break :blk null;
            if (resolved.dispatch != .direct) break :blk null;
        }
        break :blk ep;
    };
}

/// The resolver withholds dispatch on an unknown argument type though the
/// identity is certain. Only a same-name extension beats an applicable member,
/// and `extCouldApply` is conservative, so `false` settles it.
fn promotionExtWhy(
    m: *MemberCall,
    resolved: ir.Module.MemberResolution,
    shapes: []const applicability.ArgShape,
) ir.Module.ExtCouldApplyWhy {
    const b = m.b;
    const name = m.name;
    const args = m.args;
    const head = m.head;

    const promo_ext_why: ir.Module.ExtCouldApplyWhy =
        if (resolved.dispatch == .deferred and resolved.target != null)
            b.module.extCouldApplyWhy(b.allocator, head, name.name, args.len)
        else
            .none;
    if (norecvCensusOn() and resolved.dispatch == .deferred and resolved.target != null) {
        if (runtime.envOnce("KLIO_PROMO_NAMES") != null and promo_ext_why != .none) {
            var typed_args: usize = 0;
            for (shapes) |sh| {
                if (sh.ty != null or sh.literal_kind != null or sh.is_lambda) typed_args += 1;
            }
            std.debug.print("[promo-ext] {s}.{s} nargs={d} typed={d} why={s}\n", .{
                head, name.name, args.len, typed_args, @tagName(promo_ext_why),
            });
        }
        switch (promo_ext_why) {
            .none => {},
            .index_stale => audit_mod.lm_promo.bump(@intFromEnum(PromoBlock.ext_index_stale)),
            .generic_receiver => audit_mod.lm_promo.bump(@intFromEnum(PromoBlock.ext_generic_receiver)),
            .own_head => audit_mod.lm_promo.bump(@intFromEnum(PromoBlock.ext_own_head)),
            .builtin_super => audit_mod.lm_promo.bump(@intFromEnum(PromoBlock.ext_builtin_super)),
            .declared_super => audit_mod.lm_promo.bump(@intFromEnum(PromoBlock.ext_declared_super)),
        }
    }
    return promo_ext_why;
}

/// Whether the receiver's class is host-backed: a declaration-only shell whose
/// members live in the intrinsic registry rather than the class table. No
/// member lookup can ever succeed on one, so a miss there is a different fact
/// from a miss on a class that really declares nothing of that name.
fn hostBackedOwner(b: *const FuncBuilder, owner: ir.ClassId) bool {
    if (owner.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[owner.int()];
    if (c.is_stub) return true;
    return b.module.registry.host_shadowed_fqns.contains(c.fqn);
}

/// Record the argument shapes for the call and emit it: a virtual slot, a
/// spread, or the exact static call the pick names.
fn emitResolvedMemberCall(
    m: *MemberCall,
    func_id: FuncId,
    target_ptr: *(*const ir.Func),
    resolved: ir.Module.MemberResolution,
    has_spread: bool,
) Allocator.Error!ResolvedMemberLowering {
    const b = m.b;
    const receiver = m.receiver;
    const args = m.args;
    const ast_arg_names = m.ast_arg_names;
    const ast_type_args = m.ast_type_args;
    const recv_state = m.recv_state;
    const recv_ty = m.recv_ty;
    var target = target_ptr.*;

    try recordLambdaArgReceivers(b, target, args, ast_arg_names, ast_type_args, 1);
    const broad_masks = try argLambdaBroadMasks(b, target, args, ast_arg_names, 1);
    defer if (broad_masks) |masks| b.allocator.free(masks);
    b.pending_arg_broad_masks = broad_masks;
    const arg_arity = try argFnArities(b, target, args, ast_arg_names, 1);
    defer if (arg_arity) |arities| b.allocator.free(arities);
    const arg_generic = try argFnGenericFlags(b, target, args, ast_arg_names, 1);
    defer if (arg_generic) |flags| b.allocator.free(flags);
    b.pending_arg_fn_generic = arg_generic;
    if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] extMember fn={s}\n", .{target.name});
    const lambda_param_types = try argLambdaParamTypesRecv(
        b,
        target,
        args,
        ast_arg_names,
        ast_type_args,
        1,
        substitutionRecv(b, &recv_ty),
    );
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;

    const recv_reg = recv_state.reg orelse try lowerReceiver(b, receiver);
    // Lowering the receiver can append functions to the module's table and
    // reallocate it, invalidating `target`; re-fetch before reading it again.
    target = b.module.funcById(func_id) orelse {
        declineNote(.target_unresolvable);
        return .deferred;
    };
    if (resolved.dispatch == .virtual) {
        // Defer before the receiver-skipping scans slice `params[1..]`.
        if (target.params.len == 0) {
            declineNote(.virtual_no_receiver_param);
            return .deferred;
        }
        const arg_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
        var has_vararg = false;
        for (target.params[1..]) |param| if (param.is_vararg) {
            has_vararg = true;
            break;
        };
        const arg_params: ?[]u32 = if (anyNamedArg(ast_arg_names) or has_vararg) blk: {
            const mapped = (try mapArgsToParams(b, target.params[1..], args, ast_arg_names)) orelse {
                declineNote(.arg_mapping_failed);
                return .deferred;
            };
            defer b.allocator.free(mapped);
            for (mapped) |param| if (param == null) {
                declineNote(.arg_mapping_failed);
                return .deferred;
            };
            const indices = try b.allocator.alloc(u32, mapped.len);
            for (mapped, indices) |param, *out| out.* = @intCast(param.?);
            break :blk indices;
        } else null;
        const dst = b.allocReg();
        if (has_spread) {
            try b.push(.{ .CallSpread = try b.boxInst(ir.CallSpreadInst{
                .dst = dst,
                .callee = recv_reg,
                .parts = try lowerSpreadParts(b, args),
                .virtual_slot = ir.MethodSlotId.fromFunc(func_id),
                .arg_params = arg_params,
                .trailing_lambda = b.callTrailingLambda(),
            }) });
            return .{ .lowered = dst };
        }
        const run = try lowerArgRunWithArity(b, args, arg_arity);
        lmNote(.bound_virtual);
        const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
        try b.push(.{ .CallVirtual = .{
            .dst = dst,
            .receiver = recv_reg,
            .slot = ir.MethodSlotId.fromFunc(func_id),
            .args = run[0],
            .n_args = run[1],
            .extra = try b.virtualExtra(.{ .arg_params = arg_params, .arg_names = if (arg_params == null) arg_names else &.{}, .trailing_lambda = b.callTrailingLambda() }),
        } });
        try probe_mod.contextHandoverEnd(b, ctx_handed);
        return .{ .lowered = dst };
    }

    const args_start = b.allocReg();
    const run = try lowerArgRunWithArity(b, args, arg_arity);
    try b.push(.{ .Move = .{ .dst = args_start, .src = recv_reg } });

    const user_names = try trailingLambdaArgNames(b, func_id, args, ast_arg_names);
    const arg_names: []?ConstId = if (user_names.len == 0)
        &.{}
    else blk: {
        const names = try b.allocator.alloc(?ConstId, user_names.len + 1);
        names[0] = null;
        @memcpy(names[1..], user_names);
        break :blk names;
    };
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    const dst = b.allocReg();
    lmNote(.bound_static);
    const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = args_start,
        .n_args = run[1] + 1,
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = true,
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    return .{ .lowered = dst };
}


/// Bind an explicit-receiver top-level extension to its declaration identity.
/// The resolver returns a target only when receiver compatibility, visibility,
/// and overload ranking are provable without a runtime value.
pub fn lowerMemberExtensionDispatchReceiver(
    b: *FuncBuilder,
    owner: ir.ClassId,
) Allocator.Error!?Reg {
    if (owner.int() >= b.module.classes.items.len) return null;
    const class = &b.module.classes.items[owner.int()];
    var is_object = class.is_object;
    if (!is_object) {
        for (b.module.registry.object_names.items) |name| {
            if (std.mem.eql(u8, name, class.name) or
                std.mem.eql(u8, name, class.fqn))
            {
                is_object = true;
                break;
            }
        }
    }
    if (is_object) {
        const dst = b.allocReg();
        const owner_name = try b.module.internConst(
            b.allocator,
            .{ .String = class.fqn },
        );
        try b.push(.{ .LoadGlobal = .{
            .dst = dst,
            .name = owner_name,
            .class = owner,
        } });
        return dst;
    }

    // Inside the owner's own member extension the frame holds the dispatch
    // receiver, and a closure inside it captured the `this@<Owner>` slot; in
    // a plain method that slot is `this` itself.
    if (b.ownerClass()) |oc| {
        if (std.mem.eql(u8, oc, class.name) or std.mem.eql(u8, oc, class.fqn)) {
            if (try implicit_walk.dispatchRegister(b, oc)) |dr| return dr;
        }
    }
    const base = (try resolveThisRegKind(b, true, false)) orelse return null;
    // In the owner's own method or accessor body the innermost `this` is the
    // owner's instance already; a qualified read would only re-derive that by
    // name at runtime.
    if (thisIsOwnerInstance(b, class)) return base;
    if (try implicit_walk.instanceOfClassReg(b, class.name)) |r| return r;
    expr_mod.orEmitAudit(b, "inner_ctor_outer", "QualifiedThis", class.name);
    const dst = b.allocReg();
    const qualifier = try b.module.internConst(
        b.allocator,
        .{ .String = class.fqn },
    );
    try b.push(.{ .QualifiedThis = .{
        .dst = dst,
        .receiver = base,
        .qualifier = qualifier,
    } });
    return dst;
}

/// Whether the innermost `this` is an instance of `class`: the lexical owner is
/// that class and nothing rebinds `this` beneath it, so no extension receiver,
/// no inline splice receiver of another class, and no receiver-lambda subject
/// on the tower.
pub fn thisIsOwnerInstance(b: *const FuncBuilder, class: anytype) bool {
    const oc = b.ownerClass() orelse return false;
    if (!std.mem.eql(u8, oc, class.name) and !std.mem.eql(u8, oc, class.fqn)) return false;
    if (b.encl_tower_depth != 0) return false;
    if (b.recvTy()) |rt| {
        const h = typeHead(std.mem.trimEnd(u8, rt, "?"));
        if (!std.mem.eql(u8, h, class.name) and !b.module.classIsOrExtends(h, class.name)) return false;
    }
    if (b.spliceRecvTy()) |st| {
        const h = typeHead(std.mem.trimEnd(u8, st, "?"));
        if (!std.mem.eql(u8, h, class.name) and !b.module.classIsOrExtends(h, class.name)) return false;
    }
    return true;
}

/// Declared type head of each argument, interned. Kotlin picks a constructor
/// overload from the static types, which an interpreted instance cannot supply
/// at run time. Null where no declared type exists.
pub fn ctorArgStaticHeads(b: *FuncBuilder, args: []const Expr) Allocator.Error![]?ir.ConstId {
    const out = try b.allocator.alloc(?ir.ConstId, args.len);
    errdefer b.allocator.free(out);
    var any = false;
    for (args, 0..) |*a, i| {
        out[i] = null;
        const ty = argDeclTypeRef(b, a) orelse continue;
        var h = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
        if (std.mem.findScalarLast(u8, h, '.')) |d| h = h[d + 1 ..];
        if (h.len == 0 or bareTypeParamHead(h)) continue;
        out[i] = try b.module.internConst(b.allocator, .{ .String = h });
        any = true;
    }
    if (!any) {
        b.allocator.free(out);
        return &.{};
    }
    return out;
}

/// The sole inline extension of this name and arity whose receiver is an
/// unbounded type parameter: the scope-function family, which applies to every
/// value and splices rather than dispatches.
fn uniqueUniversalInlineExtension(b: *FuncBuilder, name: []const u8, nargs: usize) ?FuncId {
    var found: ?FuncId = null;
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        const is_ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (!is_ext) continue;
        if (f.params.len != nargs + 1) continue;
        if (!f.is_inline) return null;
        const rt = f.params[0].ty;
        if (rt.nullable or rt.args.len != 0) return null;
        if (!bareTypeParamHead(rt.name)) return null;
        if (found != null) return null;
        found = fid;
    }
    return found;
}

fn uniqueAnyNullableExtension(b: *FuncBuilder, name: []const u8, nargs: usize) ?FuncId {
    var found: ?FuncId = null;
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        // A same-named member is not competition: `Any?.toString()` delegates
        // to it.
        const is_ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (!is_ext) continue;
        if (f.params.len != nargs + 1) continue;
        // A non-local `return` in the lambda argument needs the splice.
        if (f.is_inline) return null;
        const rt = f.params[0].ty;
        const rt_head = typeHead(std.mem.trimEnd(u8, rt.name, "?"));
    // `Any?` and unbounded bare-type-param receivers are the same universal
    // shape. A same-named class member refuses, since it would win at run time.
        const universal_tp = rt.args.len == 0 and bareTypeParamHead(rt_head) and blk: {
            const bound = b.module.staticFuncTypeParamBound(fid, rt_head) orelse break :blk true;
            break :blk std.mem.eql(u8, applicability.simpleName(typeHead(std.mem.trimEnd(u8, bound, "?"))), "Any");
        };
        if (!universal_tp) {
            if (!rt.nullable) return null;
            if (!std.mem.eql(u8, rt_head, "Any")) return null;
        } else {
            if (b.module.registry.class_member_names.contains(name)) return null;
        }
        if (found != null) return null;
        found = fid;
    }
    return found;
}

pub threadlocal var ext_route_tag: []const u8 = "?";
/// The state the resolved-extension call threads through its emission arms.
const ExtCall = struct {
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    ast_type_args: []const ast.TypeRef,
    /// The receiver's declared type, which instantiates the callee's own type
    /// parameters for the argument lambdas.
    recv_ty: TypeRef,
    /// The owner a member extension dispatches its receiver against.
    dispatch_owner: ?ir.ClassId,
    func_id: FuncId,
    target: *const ir.Func,
    /// The argument run the selection settled on, and its names.
    values: []const Expr,
    names: []const ?[]const u8,
};

/// Bind an explicit-receiver top-level extension to its declaration identity.
pub fn lowerResolvedExtensionCall(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    declared_ty: ?TypeRef,
    /// Whether `receiver` is an expression the call site wrote. A head taken
    /// from the implicit receiver tower is a conjecture, and a pick may not be
    /// committed on the strength of a receiver that may not be there.
    actual_receiver: bool,
) Allocator.Error!?Reg {

    // Explicit call-site type arguments constrain the eligible generic
    // declarations before overload ranking.
    if (ast_type_args.len != 0) return null;
    const recv_ty = declared_ty orelse return null;
    const resolution = try resolveExtensionCallForArgs(
        b,
        recv_ty,
        name,
        args,
        ast_arg_names,
        actual_receiver,
    );
    const func_id = resolution.target orelse blk: {
        // A return-variant tie discriminates by the trailing lambda's derived
        // return, as the bare form does.
        if (allNull(ast_arg_names)) {
            const cands = try b.module.bareCallCandidates(b.allocator, name.name, name.span.file);
            defer b.allocator.free(cands);
            const rh = typeHead(std.mem.trimEnd(u8, recv_ty.name, "?"));
            if (try overloadPickByLambdaReturnFull(b, cands, args, args.len, rh, receiver)) |picked| {
                break :blk picked;
            }
        }
        // The probe above lowers, so any nested resolution has overwritten the
        // slot; this call's own verdict is what the deferred emit must read.
        stashWithheldExtPick(&resolution);
        return null;
    };
    const target = b.module.funcById(func_id) orelse return null;
    var selected_args = try selectedCallArgsForBuilder(
        b,
        func_id,
        args,
        ast_arg_names,
        name.span,
        b.callTrailingLambda(),
    );
    defer selected_args.deinit(b.allocator);
    const selected_values = selected_args.args;
    const selected_names = selected_args.names;
    try recordLambdaArgReceiversForCallReceiver(
        b,
        target,
        selected_values,
        selected_names,
        ast_type_args,
        recv_ty,
        1,
    );
    const x = ExtCall{
        .b = b,
        .receiver = receiver,
        .name = name,
        .ast_type_args = ast_type_args,
        .recv_ty = recv_ty,
        .dispatch_owner = resolution.dispatch_owner,
        .func_id = func_id,
        .target = target,
        .values = selected_values,
        .names = selected_names,
    };
    // An image header stub of an inline extension has no `is_inline` flag but
    // does have its declaration in the inline table, and must splice: a direct
    // call reaches a bodiless stub whose reified parameters nothing binds.
    if (target.is_inline or inline_state.inlineAstById(func_id.int()) != null) {
        return try spliceInlineExtensionCall(x);
    }
    return try emitExtensionCall(x);
}

/// Splice the inline extension's body at the call site. The splice lowers
/// lambda arguments in its own loop, bypassing `lowerArgRun`'s typing transfer,
/// so expected param types are instantiated here for the eagerly lowered
/// closure bodies.
fn spliceInlineExtensionCall(x: ExtCall) Allocator.Error!?Reg {
    const b = x.b;
    const receiver = x.receiver;
    const name = x.name;
    const ast_type_args = x.ast_type_args;
    const recv_ty = x.recv_ty;
    const func_id = x.func_id;
    const target = x.target;
    const selected_values = x.values;
    const selected_names = x.names;

    const inline_decl = inline_state.inlineAstById(func_id.int()) orelse return null;
    inline_state.ensureInlineBody(inline_decl);
    // The splice lowers lambda arguments in its own loop, bypassing
    // `lowerArgRun`'s typing transfer, so instantiate expected param types
    // here for the eagerly lowered closure bodies.
    if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] inlineSplice fn={s}\n", .{target.name});
    const inline_lambda_param_types = try argLambdaParamTypesRecv(
        b,
        target,
        selected_values,
        selected_names,
        ast_type_args,
        1,
        substitutionRecv(b, &recv_ty),
    );
    defer if (inline_lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    // The splice expands lambda bodies rather than going through
    // `lowerArgRun`, so the `-> Unit` mask has no consumer and would dangle
    // into calls lowered inside the spliced body.
    if (b.pending_arg_lambda_unit) |m| b.allocator.free(m);
    b.pending_arg_lambda_unit = null;
    b.pending_arg_lambda_param_types = inline_lambda_param_types;
    defer b.pending_arg_lambda_param_types = null;
    // Solve the callee's bindings once (receiver plus typed args) so every
    // in-window consumer sees the call-site instantiation. Registry-stable
    // fn-tp names only; owner identities stay per-channel.
    {
        var sc2 = std.heap.ArenaAllocator.init(b.allocator);
        defer sc2.deinit();
        const a2 = sc2.allocator();
        var sh_set2 = try buildStaticReturnArgShapes(b, selected_values, selected_names);
        defer sh_set2.deinit(b.allocator);
        if (b.module.solveCallBindings(a2, func_id, target, recv_ty, null, sh_set2.shapes, &.{}, false) catch null) |solved2| blk_s4: {
            const fn_tps = b.module.registry.func_type_params.get(func_id) orelse break :blk_s4;
            var outl: std.ArrayList(ir.Module.TypeBinding) = .empty;
            errdefer {
                for (outl.items) |*e| {
                    var t = e.ty;
                    t.deinit(b.allocator);
                }
                outl.deinit(b.allocator);
            }
            for (solved2.bindings) |sb| {
                const h2 = typeHead(std.mem.trimEnd(u8, sb.ty.name, "?"));
                if (std.mem.eql(u8, h2, "*") or h2.len == 0) continue;
                var stable: ?[]const u8 = null;
                for (fn_tps.items) |tp| {
                    if (std.mem.eql(u8, tp, sb.name)) {
                        stable = tp;
                        break;
                    }
                }
                const sname = stable orelse continue;
                try outl.append(b.allocator, .{ .name = sname, .ty = try sb.ty.clone(b.allocator) });
            }
            if (outl.items.len != 0) {
                b.module.pending_splice_solved = try outl.toOwnedSlice(b.allocator);
            } else outl.deinit(b.allocator);
        }
    }
    const expected = b.peekExpected();
    const expected_ptr: ?*const ast.TypeRef = if (expected) |*ty| ty else null;
    inline_call.splice_route_tag = "lowerResolvedExtensionCall:20312";
    const spliced = try tryInlineCallWithTypeArgs(
        b,
        name.name,
        inline_decl,
        selected_values,
        selected_names,
        receiver,
        ast_type_args,
        expected_ptr,
    );
    if (runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name.name)) std.debug.print("[splice-{s}] {s} fid={d} span={}:{} route={s} nta={d}\n", .{ if (spliced != null) @as([]const u8, "ok") else "bail", name.name, func_id.int(), name.span.file, name.span.start, ext_route_tag, ast_type_args.len });
    }
    return spliced;
}

/// Emit the extension as an exact static call, its receiver in the leading
/// `this` slot; a member extension additionally carries the dispatch receiver
/// its owner class supplies.
fn emitExtensionCall(x: ExtCall) Allocator.Error!?Reg {
    const b = x.b;
    const receiver = x.receiver;
    const name = x.name;
    const ast_type_args = x.ast_type_args;
    const recv_ty = x.recv_ty;
    const func_id = x.func_id;
    const target = x.target;
    const selected_values = x.values;
    const selected_names = x.names;
    const dispatch_owner = x.dispatch_owner;

    const broad_masks = try argLambdaBroadMasks(b, target, selected_values, selected_names, 1);
    defer if (broad_masks) |masks| b.allocator.free(masks);
    b.pending_arg_broad_masks = broad_masks;
    const arg_arity = try argFnArities(b, target, selected_values, selected_names, 1);
    defer if (arg_arity) |arities| b.allocator.free(arities);
    const arg_generic = try argFnGenericFlags(b, target, selected_values, selected_names, 1);
    defer if (arg_generic) |flags| b.allocator.free(flags);
    b.pending_arg_fn_generic = arg_generic;
    if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] extNamed fn={s}\n", .{target.name});
    const lambda_param_types = try argLambdaParamTypesRecv(
        b,
        target,
        selected_values,
        selected_names,
        ast_type_args,
        1,
        substitutionRecv(b, &recv_ty),
    );
    defer if (lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    b.pending_arg_lambda_param_types = lambda_param_types;

    // The two calls below lower lambda bodies, which appends to the module's
    // function table and moves it; `target` points into it.
    const target_is_member_extension = target.kind == .member_extension;
    const dispatch_reg: ?Reg = if (target_is_member_extension)
        (try lowerMemberExtensionDispatchReceiver(
            b,
            dispatch_owner orelse return null,
        )) orelse return null
    else
        null;
    const recv_reg = try lowerReceiver(b, receiver);
    if (target_is_member_extension) {
        const run = try lowerArgRunWithArity(b, selected_values, arg_arity);
        const arg_names = try trailingLambdaArgNames(
            b,
            func_id,
            selected_values,
            selected_names,
        );
        const dst = b.allocReg();
        const method_name = try b.module.internConst(
            b.allocator,
            .{ .String = name.name },
        );
        const declared_recv = try b.module.internConst(
            b.allocator,
            .{ .String = recv_ty.name },
        );
        const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv_reg,
            .name = method_name,
            .args = run[0],
            .n_args = run[1],
            .extra = try b.memberExtra(.{ .arg_names = arg_names, .trailing_lambda = b.callTrailingLambda(), .declared_recv = declared_recv, .resolved = func_id, .dispatch_receiver = dispatch_reg }),
        } });
        try probe_mod.contextHandoverEnd(b, ctx_handed);
        return dst;
    }
    const args_start = b.allocReg();
    const run = try lowerArgRunWithArity(b, selected_values, arg_arity);
    try b.push(.{ .Move = .{ .dst = args_start, .src = recv_reg } });

    const user_names = try trailingLambdaArgNames(
        b,
        func_id,
        selected_values,
        selected_names,
    );
    const arg_names: []?ConstId = if (user_names.len == 0)
        &.{}
    else blk: {
        const names = try b.allocator.alloc(?ConstId, user_names.len + 1);
        names[0] = null;
        @memcpy(names[1..], user_names);
        break :blk names;
    };
    const type_args = try helpers.internTypeArgsScoped(b, ast_type_args);
    const dst = b.allocReg();
    const ctx_handed = try probe_mod.contextHandoverBegin(b, func_id, ast_type_args);
    try b.push(.{ .Call = .{
        .dst = dst,
        .func = func_id,
        .trailing_lambda = b.callTrailingLambda(),
        .args = args_start,
        .n_args = run[1] + 1,
        .arg_names = arg_names,
        .type_args = type_args,
        .exact = true,
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    return dst;
}


/// Whether the preceding member resolution statically refuted every candidate,
/// so the extension leg running next can commit a sole receiver-proven one.
threadlocal var last_member_refuted: bool = false;

pub fn resolveExtensionCallForArgs(
    b: *FuncBuilder,
    recv_ty: TypeRef,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    actual_receiver: bool,
) Allocator.Error!ir.Module.ExtensionResolution {
    var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const shapes = shape_set.shapes;
    const caller_file = name.span.file;
    const implicit_owners = try b.collectImplicitReceiverTower(b.allocator, eagerLambdaRecvHead(b));
    defer b.allocator.free(implicit_owners);
    const owned_type_param_bounds = try b.typeParamBoundsSlice();
    defer if (owned_type_param_bounds) |bounds| b.allocator.free(bounds);
    const member_refuted = last_member_refuted;
    last_member_refuted = false;
    const resolve_ctx = ir.Module.ExtensionResolveCtx{
        .caller_file = caller_file,
        .caller_package = b.module.packageOfFile(caller_file) orelse b.self_package,
        .implicit_dispatch_owners = implicit_owners,
        .lexical_owner = b.ownerClass(),
        .call_name = name.name,
        .actual_type_param_bounds = owned_type_param_bounds orelse &.{},
        .member_refuted = member_refuted,
        .actual_receiver = actual_receiver,
        .enclosing_fn_name = build.currentRealFn(),
    };
    // Diagnostic only; see `applicability.trace_call_span`.
    if (applicability.extKeyTraceEnabled()) {
        applicability.trace_call_span = name.span;
        applicability.trace_call_name = name.name;
    }
    var resolution = b.module.resolveExtensionCall(
        name.name,
        recv_ty,
        shapes,
        resolve_ctx,
    );
    if (!argShapesHaveComposerPair(shapes)) {
        const threaded = try b.allocator.alloc(
            applicability.ArgShape,
            shapes.len + 2,
        );
        defer b.allocator.free(threaded);
        @memcpy(threaded[0..shapes.len], shapes);
        threaded[shapes.len] = .{};
        threaded[shapes.len + 1] = .{
            .ty = build.typeInt(),
            .literal_kind = .numeric,
        };
        resolution.compiler_abi_applicable = b.module.resolveExtensionCall(
            name.name,
            recv_ty,
            threaded,
            resolve_ctx,
        ).applicable;
    }
    if (runtime.envOnce("KLIO_EXT_TRACE")) |wanted| {
        if (std.mem.eql(u8, wanted, name.name)) {
            std.debug.print(
                "[ext-static] {s} recv={s} owners=",
                .{ name.name, recv_ty.name },
            );
            for (implicit_owners) |owner| std.debug.print("{s},", .{owner});
            std.debug.print(
                " lexical={s} args={d} target={?d} applicable={} compiler_abi={}\n",
                .{
                    b.ownerClass() orelse "-",
                    shapes.len,
                    if (resolution.target) |target| target.int() else null,
                    resolution.applicable,
                    resolution.compiler_abi_applicable,
                },
            );
        }
    }
    return resolution;
}

/// Whether NO receiver could answer `name`, whatever it turns out to be.
///
/// The competing-callable question above needs the receiver's static type and
/// declines without one, which leaves every call on an untyped receiver
/// deferred. This asks the weaker question that needs no receiver: the module
/// records every name any class declares as a member, so a name absent from
/// that set is one no receiver has, and the in-scope callable is the only
/// candidate Kotlin has. An extension of the name is still a candidate, so
/// any extension at all withdraws the answer.
fn noReceiverCouldDeclare(b: *FuncBuilder, name: []const u8, argc: usize) bool {
    if (b.module.registry.class_member_names.contains(name)) return false;
    _ = argc;
    return !b.module.extensionCouldServe(null, name);
}

/// Whether the receiver's static class, its hierarchy complete, has no member
/// or extension that could take `name(args)`. A hierarchy that declares the
/// name still has none when the resolver refuted every declaration for this
/// call (`member_refuted`): `updater.update()` with `update: Updater.() -> Unit`
/// in scope and `Updater.update(value, block)` the only member.
fn staticReceiverHasNoCompetingCallable(
    b: *FuncBuilder,
    receiver_ty: ?TypeRef,
    name: []const u8,
    argc: usize,
    member_refuted: bool,
) bool {
    const ty = receiver_ty orelse return false;
    var head = typeHead(ty.name);
    // A type-parameter receiver has the members of its bound, and of `Any`
    // without one.
    if (b.isTypeParam(head)) {
        if (b.typeParamBound(head)) |tb| {
            if (!tb.head_only) return false;
            head = typeHead(tb.bound);
        } else head = "Any";
    }
    if (std.mem.eql(u8, head, "Any")) {
        const any_member = std.mem.eql(u8, name, "equals") or std.mem.eql(u8, name, "hashCode") or std.mem.eql(u8, name, "toString");
        return !any_member and !b.module.extCouldApply(b.allocator, "Any", name, argc);
    }
    // The record is keyed by the class row's name, which for a nested class
    // (`Operations.OpIterator`) is not the bare tail of the type.
    const cid_opt: ?ir.ClassId = if (!b.isTypeParam(head)) classOfDeclType(b, ty) else null;
    const row_name: []const u8 = if (cid_opt) |cid| b.module.classes.items[cid.int()].name else head;
    const declares: bool = blk: {
        if (b.module.registry.hierarchy_shadow_names.get(row_name)) |hierarchy| {
            if (hierarchy.complete) break :blk hierarchy.names.contains(name);
        }
        const cid = cid_opt orelse return false;
        break :blk chainDeclaresName(b, cid, name) orelse return false;
    };
    if (declares and !member_refuted) return false;
    return !b.module.extCouldApply(b.allocator, head, name, argc);
}

pub fn localOverloadReceiverCouldApply(
    b: *const FuncBuilder,
    overload: *const build.LocalFnOverload,
    raw_actual: TypeRef,
) Allocator.Error!bool {
    const declared = overload.receiver_ty orelse return true;
    const owned_bounds = try b.typeParamBoundsSlice();
    defer if (owned_bounds) |bounds| b.allocator.free(bounds);
    const actual_bounds: []const ir.ModuleRegistry.TypeParamBound =
        owned_bounds orelse &.{};
    // An alias head (`Ints = MutableList<Int>`) names no class, so unresolved it
    // falls to the type-parameter escape below and applies a refuted overload.
    var alias_arena = std.heap.ArenaAllocator.init(b.allocator);
    defer alias_arena.deinit();
    const actual_scoped = b.module.resolveTypeAliasAt(
        alias_arena.allocator(),
        raw_actual,
        null,
        b.self_package,
    ) catch raw_actual;
    const actual = actual_scoped;
    // An actual head naming no classifier and carrying no bound belongs to a
    // spliced or generic context: unresolvable, so it must not disprove.
    {
        const head = typeHead(actual.name);
        // A derived `Any` head is the deriver's erasure product, not proof the
        // receiver is unrelated.
        if (std.mem.eql(u8, head, "Any")) return true;
        var bound_known = false;
        for (actual_bounds) |tb| {
            if (std.mem.eql(u8, tb.param, head)) bound_known = true;
        }
        // Builtin heads are known classifiers without a module class entry and
        // keep the full subtype judgment: `Nothing?` must still refute `String`.
        const builtin_head = isPrimitiveTypeName(head) or
            std.mem.eql(u8, head, "Nothing") or std.mem.eql(u8, head, "Any") or
            std.mem.eql(u8, head, "Unit") or std.mem.eql(u8, head, "String") or
            std.mem.eql(u8, head, "CharSequence");
        if (!builtin_head and !bound_known and b.module.classId(head) == null and
            b.module.registry.class_super_names.get(head) == null)
        {
            return true;
        }
    // Likewise one level down: a type argument naming no classifier and no
    // in-scope parameter is an uninstantiated class parameter, which the
    // invariance check would read as a nominal mismatch.
        for (actual.args) |arg| {
            var ah = std.mem.trimEnd(u8, arg.name, "?");
            if (std.mem.startsWith(u8, ah, "in#")) ah = ah[3..];
            if (std.mem.startsWith(u8, ah, "out#")) ah = ah[4..];
            ah = typeHead(ah);
            if (ah.len == 0 or std.mem.eql(u8, ah, "*")) continue;
            if (isPrimitiveTypeName(ah)) continue;
            var arg_bound_known = false;
            for (actual_bounds) |tb| {
                if (std.mem.eql(u8, tb.param, ah)) arg_bound_known = true;
            }
            if (arg_bound_known) continue;
            if (b.module.classId(ah) != null or
                b.module.registry.class_super_names.get(ah) != null) continue;
            if (std.mem.eql(u8, ah, "Any") or std.mem.eql(u8, ah, "Unit") or
                std.mem.eql(u8, ah, "Nothing") or std.mem.eql(u8, ah, "String") or
                std.mem.eql(u8, ah, "CharSequence")) continue;
            return true;
        }
    }
    if (overload.receiver_has_type_params) {
        const r = try b.module.staticGenericReceiverCouldApply(
            b.allocator,
            actual,
            declared,
            overload.type_params,
            actual_bounds,
        );
        if (runtime.envOnce("KLIO_ADM_TRACE") != null)
            std.debug.print("[lorca-g] actual={s}({d}) declared={s}({d}) tps={d} -> {}\n", .{ actual.name, actual.args.len, declared.name, declared.args.len, overload.type_params.len, r });
        return r;
    }
    const r = try b.module.staticTypeIsSubtypeWithBounds(
        b.allocator,
        actual,
        declared,
        actual_bounds,
    );
    if (runtime.envOnce("KLIO_ADM_TRACE") != null)
        std.debug.print("[lorca-s] actual={s}({d}:{s}) n={} declared={s}({d}:{s}) n={} bounds={d} -> {}\n", .{ actual.name, actual.args.len, if (actual.args.len != 0) actual.args[0].name else "-", actual.nullable, declared.name, declared.args.len, if (declared.args.len != 0) declared.args[0].name else "-", declared.nullable, actual_bounds.len, r });
    return r;
}

pub fn localExtensionReceiverCouldApply(
    b: *const FuncBuilder,
    name: []const u8,
    receiver_ty: ?TypeRef,
) Allocator.Error!bool {
    const actual = receiver_ty orelse return true;
    const overloads = b.localFnDecls(name) orelse {
        if (runtime.envOnce("KLIO_ADM_TRACE") != null)
            std.debug.print("[lerca] {s} no-decls actual={s} -> true\n", .{ name, actual.name });
        return true;
    };
    var saw_extension = false;
    for (overloads) |overload| {
        if (!overload.is_ext) continue;
        saw_extension = true;
        if (try localOverloadReceiverCouldApply(b, &overload, actual)) {
            if (runtime.envOnce("KLIO_ADM_TRACE") != null)
                std.debug.print("[lerca] {s} ext-applies actual={s} -> true\n", .{ name, actual.name });
            return true;
        }
    }
    if (runtime.envOnce("KLIO_ADM_TRACE") != null)
        std.debug.print("[lerca] {s} actual={s} saw_ext={} -> {}\n", .{ name, actual.name, saw_extension, !saw_extension });
    return !saw_extension;
}

fn callableExtensionPropertyTarget(
    b: *const FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    value_arity: usize,
    declared_ty: ?TypeRef,
) ?ir.ModuleRegistry.CallableExtensionProp {
    var receiver_head: []const u8 = undefined;
    var receiver_is_class = false;
    if (receiver.* == .Path and receiver.Path.segments.len == 1) {
        const ident = receiver.Path.segments[0];
        if (b.resolve(ident.name) == null and !b.knowsOuter(ident.name)) {
            if (b.module.classIdIndexed(ident.name, b.self_package, ident.span.file)) |cid| {
                if (cid.int() < b.module.classes.items.len) {
                    receiver_head = b.module.classes.items[cid.int()].name;
                    receiver_is_class = true;
                }
            }
        }
    }
    if (!receiver_is_class) {
        const ty = declared_ty orelse return null;
        receiver_head = ty.name;
    }
    return b.module.resolveCallableExtensionProperty(
        name.name,
        receiver_head,
        receiver_is_class,
        value_arity,
        b.module.packageOfFile(name.span.file) orelse b.self_package,
        name.span.file,
    );
}

/// The state one member-call fallback ladder threads through its rungs.
/// The extension declaration `lowerResolvedExtensionCall` ranked first and then
/// withheld, kept across the few frames between that resolution and the deferred
/// emit so the instruction can carry it. Lowering a function runs on one thread
/// and the value is written and read within a single call chain, so a per-thread
/// slot is the whole lifetime.
threadlocal var withheld_ext_pick: ?FuncId = null;
threadlocal var withheld_ext_best_tier: bool = false;

/// The declaration the MEMBER gate named and then withheld. Same question as
/// the extension stash, different resolver; a site has one or the other, never
/// both, since the extension path only runs when the member gate declined.
threadlocal var withheld_member_pick: ?FuncId = null;

fn stashWithheldExtPick(r: *const ir.Module.ExtensionResolution) void {
    withheld_ext_pick = r.sole_unknown;
    withheld_ext_best_tier = r.sole_unknown_best_tier;
}

fn takeWithheldExtPick() struct { pick: ?FuncId, best_tier: bool } {
    defer {
        withheld_ext_pick = null;
        withheld_ext_best_tier = false;
    }
    return .{ .pick = withheld_ext_pick, .best_tier = withheld_ext_best_tier };
}

fn takeWithheldMemberPick() ?FuncId {
    defer withheld_member_pick = null;
    return withheld_member_pick;
}

const Fallback = struct {
    b: *FuncBuilder,
    expr: *const Expr,
    receiver: *const Expr,
    name: ast.Ident,
    args: []Expr,
    ast_arg_names: []?[]const u8,
    ast_type_args: []ast.TypeRef,
    /// The receiver's declared type, or the one the static deriver lends it.
    declared_ty: ?TypeRef,
    /// Static resolution found an applicable member but withheld dispatch, so
    /// no extension may take the call.
    member_shadows_extensions: bool,
    /// The declaration the member gate named and withheld, captured where it
    /// was produced: the arms between the gate and the emit lower expressions
    /// of their own, and a per-thread slot read later is a different site's.
    member_pick: ?FuncId = null,
    /// The resolver saw the receiver's static class and no member of the
    /// name accepts this call: an arity or argument-type refutation, or no
    /// member at all. Captured for the same reason as `member_pick`.
    member_refuted: bool = false,
};

/// The catch-all `recv.name(args)` path: everything static member resolution
/// left unbound.
pub fn lowerMemberCallFallback(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const receiver = callee.Member.receiver;
    const name = callee.Member.name;
    if (try tryNestedClassCtorOnReceiver(b, receiver, name, args, ast_arg_names)) |r| return r;

    const declared_from_expr = argDeclTypeRef(b, receiver);
    // The full static deriver, not just the call-return channel: a binary
    // receiver types by the numeric-promotion arm, a companion-const read by
    // the Path arm.
    var inferred_declared_ty: ?ir.TypeRef = if (declared_from_expr == null)
        try staticExprTypeRef(b, receiver)
    else
        null;
    if (runtime.envOnce("KLIO_DECLTY_TRACE")) |w| {
        if (std.mem.eql(u8, w, name.name)) {
            const src: []const u8 = if (declared_from_expr != null) "decl" else "inferred";
            const tyn: []const u8 = if (declared_from_expr) |t| t.name else if (inferred_declared_ty) |t| t.name else "-";
            std.debug.print("[declty] {s} recv_tag={s} src={s} ty={s} at={d}:{d}\n", .{ name.name, @tagName(std.meta.activeTag(receiver.*)), src, tyn, name.span.file.int(), name.span.start });
        }
    }
    defer if (inferred_declared_ty) |*ty| ty.deinit(b.allocator);
    const declared_ty = declared_from_expr orelse inferred_declared_ty;

    // Member declarations take precedence over local callables and extensions.
    // Only ambiguous or incomplete receiver shapes continue below.
    const static_member = try lowerResolvedMemberCall(
        b,
        receiver,
        name,
        args,
        ast_arg_names,
        ast_type_args,
        declared_ty,
        .{},
    );
    switch (static_member) {
        .lowered => |reg| return reg,
        .deferred, .none => {},
    }
    const member_pick = takeWithheldMemberPick();

    var f = Fallback{
        .b = b,
        .expr = expr,
        .receiver = receiver,
        .name = name,
        .args = args,
        .ast_arg_names = ast_arg_names,
        .ast_type_args = ast_type_args,
        .declared_ty = declared_ty,
        .member_shadows_extensions = static_member == .deferred,
        .member_pick = member_pick,
        .member_refuted = last_member_refuted,
    };
    if (try tryLocalCallableOnReceiver(&f)) |r| return r;
    if (try trySuperCall(&f)) |r| return r;
    if (try tryComposerPairRetry(&f)) |r| return r;
    if (try tryCallableExtensionProperty(&f)) |r| return r;
    if (try tryExtensionCall(&f)) |r| return r;
    if (try tryArityMemberSlot(&f)) |r| return r;
    return emitDeferredMemberCall(&f);
}

/// A member call whose receiver head and arity name exactly one declaration.
///
/// The registry keys every member declaration by (class simple name, name,
/// declared arity). Where that key is unambiguous the argument types cannot
/// change the pick, because there is nothing to pick between, so the call
/// binds without them. Overrides of one root share the slot and the slot is
/// what indexes them, so this stays a VIRTUAL call: the head proves only that
/// the receiver is somewhere on that chain.
///
/// The ambiguity set is the whole guarantee. The table's writers overwrite,
/// so a key two declarations claimed holds an arbitrary one of them; every
/// such key is recorded and refused here. Same-arity overloads and two
/// classes sharing a simple name both land in it.
///
/// Last in the chain, so it only ever takes a call every resolved arm
/// declined. `KLIO_ARITY_SLOT=0` withdraws it.
fn tryArityMemberSlot(f: *Fallback) Allocator.Error!?Reg {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_ARITY_SLOT") orelse "1", "0")) return null;
    const b = f.b;
    // A named or type-argumented call is not keyed by arity alone.
    if (f.ast_type_args.len != 0 or !allNull(f.ast_arg_names)) return null;
    const ty = f.declared_ty orelse return null;
    var head = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0) return null;
    // A member of matching arity does not win by arity. It wins when it is
    // APPLICABLE to the arguments, and with the argument types unknown an
    // extension of the same name may be the real target:
    // `Random.nextLong(LongRange)` is an extension and `nextLong(Long)` a
    // member, both arity one, and binding the member handed its body a range.
    // Extensions are not in the member table, so no collision records them.
    const fid = emit_mod.declaredSlotOn(b, head, f.name.name, f.args.len) orelse return null;
    const recv_reg = try lowerExpr(b, f.receiver);
    const run = try lowerArgRun(b, f.args);
    const dst = b.allocReg();
    orEmitAudit(b, "arity_member_slot", "CallVirtual", f.name.name);
    const ctx_handed = try probe_mod.contextHandoverBegin(b, fid, f.ast_type_args);
    try b.push(.{ .CallVirtual = .{
        .dst = dst,
        .receiver = recv_reg,
        .slot = ir.MethodSlotId.fromFunc(fid),
        .args = run[0],
        .n_args = run[1],
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    lmNote(.bound_virtual);
    return dst;
}

/// A class-named receiver whose member names a nested constructible class is a
/// constructor call, so emit NewInstance rather than a companion walk.
fn tryNestedClassCtorOnReceiver(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {

    if (receiver.* == .Path and receiver.Path.segments.len >= 1 and receiver.Path.segments.len <= 3) {
        const outer_name = receiver.Path.segments[0].name;
        var all_class_like = true;
        for (receiver.Path.segments) |seg| {
            if (seg.name.len == 0 or !std.ascii.isUpper(seg.name[0])) {
                all_class_like = false;
                break;
            }
        }
        if (all_class_like and
            name.name.len != 0 and std.ascii.isUpper(name.name[0]) and
            b.resolve(outer_name) == null and !b.knowsOuter(outer_name) and
            !enclosingHasMemberNamed(b, outer_name))
        {
            var qb: [192]u8 = undefined;
            const qualified_opt: ?[]const u8 = switch (receiver.Path.segments.len) {
                1 => std.fmt.bufPrint(&qb, "{s}.{s}", .{ outer_name, name.name }) catch null,
                2 => std.fmt.bufPrint(&qb, "{s}.{s}.{s}", .{ outer_name, receiver.Path.segments[1].name, name.name }) catch null,
                else => std.fmt.bufPrint(&qb, "{s}.{s}.{s}.{s}", .{ outer_name, receiver.Path.segments[1].name, receiver.Path.segments[2].name, name.name }) catch null,
            };
            if (qualified_opt) |qualified| {
                if (b.module.classIdByQualifiedSuffix(qualified)) |ncid| {
                    if (ncid.int() < b.module.classes.items.len) {
                        const ncls = &b.module.classes.items[ncid.int()];
                        if (!ncls.is_object and !ncls.is_stub and
                            !ncls.is_abstract and !ncls.is_interface)
                        {
                            const ctor_arity = try ctorArgFnArities(b, ncid, args, ast_arg_names);
                            defer if (ctor_arity) |ca| b.allocator.free(ca);
                            const run = try lowerArgRunFull(b, args, ctor_arity, null);
                            const realigned = try ctorRealignedArgNames(b, ncid, args, ast_arg_names);
                            defer if (realigned) |r| b.allocator.free(r);
                            const arg_names = try internArgNames(b.allocator, b.module, realigned orelse ast_arg_names);
                            const dst = b.allocReg();
                            try b.push(.{ .NewInstance = .{
                                .dst = dst,
                                .class = ncid,
                                .args = run[0],
                                .n_args = run[1],
                                .arg_names = arg_names,
                                .arg_static_heads = try ctorArgStaticHeads(b, args),
                            } });
                            return dst;
                        }
                    }
                }
            }
        }
    }
    return null;
}

/// Whether the value bound to `name` can be what `recv.name(args)` invokes.
///
/// Kotlin binds the call to a local only when its type is an extension
/// function type (`Modifier.() -> Unit`) or a class with an `invoke` member
/// that takes an extension receiver; a value of any other known type is never
/// a candidate, whatever the receiver holds. A type lowering cannot see keeps
/// the local in the running.
fn localCanTakeReceiverCall(b: *FuncBuilder, name: []const u8) bool {
    return localReceiverCallVerdict(b, name).takes;
}

/// Why a local may or may not take a receiver call, for the probe.
const LocalRecvVerdict = struct { takes: bool, why: []const u8 };

fn localReceiverCallVerdict(b: *FuncBuilder, name: []const u8) LocalRecvVerdict {
    if (b.isReceiverLambdaParam(name)) return .{ .takes = true, .why = "receiver-lambda-param" };
    if (b.isLocalExtFn(name)) return .{ .takes = true, .why = "local-ext-fn" };
    if (b.localDeclRecvFn(name)) return .{ .takes = true, .why = "decl-recv-fn" };
    if (b.isPlainFnParam(name)) return .{ .takes = false, .why = "plain-fn-param" };
    if (b.isLocalFn(name)) return .{ .takes = false, .why = "local-fn" };
    var cid_opt: ?ir.ClassId = null;
    var head: []const u8 = undefined;
    // An inline callee's parameter inside its splice keeps the declared type
    // the splice recorded; the value it holds is the caller's argument.
    if (b.spliceParamTy(name)) |t| {
        if (t.function) |ft| return .{ .takes = ft.receiver != null, .why = "splice-fn-type" };
        head = typeHead(t.name.name);
        cid_opt = classOfAstType(b, &t);
    } else if (b.localAstTy(name)) |t| {
        if (t.function) |ft| return .{ .takes = ft.receiver != null, .why = "ast-fn-type" };
        if (b.module.registry.recv_fn_aliases.get(t.name.name) != null) return .{ .takes = true, .why = "recv-fn-alias" };
        head = typeHead(t.name.name);
        cid_opt = classOfAstType(b, t);
    } else if (b.localDeclTypeRef(name)) |t| {
        head = typeHead(t.name);
        cid_opt = classOfDeclType(b, t);
    } else return .{ .takes = true, .why = "no-type" };
    if (head.len == 0 or !std.ascii.isAlphabetic(head[0])) return .{ .takes = true, .why = "odd-head" };
    if (b.isTypeParam(head)) return .{ .takes = true, .why = "type-param" };
    // The class's own row, so a nested class (`Alignment.Vertical`) is found
    // under its registered name and not the bare tail. Before the spelling
    // heuristics below: `Dp` is two upper-case-led letters and a class.
    if (cid_opt) |cid| {
        // A class extending a function type is invocable through that
        // supertype, which the class table does not hold as a class: its
        // `invoke` override lists a value parameter, and whether the function
        // type takes a receiver is not written on the row. `Greeter :
        // String.() -> String` answers `"bob".g()`.
        if (classChainHasFunctionSupertype(b, cid)) return .{ .takes = true, .why = "function-supertype" };
        const cname = b.module.classes.items[cid.int()].name;
        const declares_invoke: bool = blk: {
            if (b.module.registry.hierarchy_shadow_names.get(cname)) |hs| {
                if (hs.complete) break :blk hs.names.contains("invoke");
            }
            break :blk chainDeclaresName(b, cid, "invoke") orelse return .{ .takes = true, .why = "class-chain-open" };
        };
        if (!declares_invoke) return .{ .takes = false, .why = "class-no-invoke" };
        return .{ .takes = hierarchyHasExtensionInvoke(b, cid, 0), .why = "class-invoke" };
    }
    // A `Function<N>` head says nothing about a receiver: an aliased
    // `WScope.() -> Unit` and a plain `(Int) -> Unit` both spell it, so a
    // function-typed local stays a candidate unless its declaration marked it
    // plain above.
    if (decl_mod.isFunctionTypeName(head)) return .{ .takes = true, .why = "function-head" };
    const hs = b.module.registry.hierarchy_shadow_names.get(head) orelse return .{ .takes = true, .why = "head-record-absent" };
    if (!hs.complete) return .{ .takes = true, .why = "head-record-incomplete" };
    return .{ .takes = hs.names.contains("invoke"), .why = "head-record" };
}

/// The identity a lowered type names, its qualifier restored: a nested
/// class lowers to its simple name with the qualifier in a `#qual:` marker.
fn declTypeIdentity(buf: []u8, t: ir.TypeRef) []const u8 {
    _ = buf;
    // The marker carries the qualified spelling whole, `Alignment.Horizontal`.
    for (t.args) |a| {
        if (std.mem.startsWith(u8, a.name, "#qual:")) return a.name["#qual:".len..];
    }
    return t.name;
}

pub fn classOfDeclType(b: *FuncBuilder, t: ir.TypeRef) ?ir.ClassId {
    var buf: [512]u8 = undefined;
    return classOfTypeName(b, declTypeIdentity(&buf, t));
}

pub fn classOfAstType(b: *FuncBuilder, t: *const ast.TypeRef) ?ir.ClassId {
    if (t.x().qualified_path) |qp| return classOfTypeName(b, qp);
    return classOfTypeName(b, t.name.name);
}

/// Whether an inline callee's parameter, inside its splice, is declared with a
/// receiver function type: `block: T.() -> R` in `T.writable(...)`.
fn spliceParamTakesReceiver(b: *FuncBuilder, name: []const u8) bool {
    const t = b.spliceParamTy(name) orelse return false;
    const ft = t.function orelse return false;
    return ft.receiver != null;
}

/// The class a declared or derived type names, a nested class included:
/// `Alignment.Horizontal` through its qualified suffix, a bare nested name
/// through the lexical chain, a type parameter through its bound. The
/// simple tail alone is ambiguous for `Horizontal`, which `Alignment`,
/// `AbsoluteAlignment` and `Arrangement` all nest.
pub fn classOfTypeName(b: *FuncBuilder, ty_name: []const u8) ?ir.ClassId {
    var identity = std.mem.trimEnd(u8, ty_name, "?");
    if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    identity = std.mem.trim(u8, identity, " ");
    if (identity.len == 0) return null;
    const simple = typeHead(identity);
    const file = (b.self_decl_span orelse return emit_mod.classIdOfHead(b, identity)).file;
    return classIdForReceiverHead(b, identity, simple, file, false);
}

/// Whether the class or an ancestor lists a function type among its declared
/// supertypes. The supertype-name chain keeps the spelling the declaration
/// wrote, `<function>` for a function type, which the class row drops.
fn classChainHasFunctionSupertype(b: *FuncBuilder, cid: ir.ClassId) bool {
    if (cid.int() >= b.module.classes.items.len) return false;
    const c = &b.module.classes.items[cid.int()];
    const chain = b.module.registry.class_super_names.get(c.name) orelse
        b.module.registry.class_super_names.get(c.fqn) orelse return false;
    for (chain) |sn| {
        if (std.mem.eql(u8, sn, "<function>") or decl_mod.isFunctionTypeName(sn)) return true;
    }
    return false;
}

/// Whether some class on the chain from `cid` declares a member called
/// `name`, function or property, read from the class table rather than the
/// hierarchy shadow record: the record resolves supertypes by simple name and
/// goes incomplete where a collision-mangled interface is not found under
/// it, while the class row holds the supertype ids lowering resolved. Null
/// when a class on the chain is a stub, whose surface is not recorded.
fn chainDeclaresName(b: *FuncBuilder, cid: ir.ClassId, name: []const u8) ?bool {
    var level: [32]ir.ClassId = undefined;
    var next: [32]ir.ClassId = undefined;
    var n: usize = 1;
    level[0] = cid;
    var depth: usize = 0;
    while (depth < 16 and n != 0) : (depth += 1) {
        var n_next: usize = 0;
        for (level[0..n]) |c_id| {
            if (c_id.int() >= b.module.classes.items.len) return null;
            const c = &b.module.classes.items[c_id.int()];
            if (c.is_stub) return null;
            if (b.module.memberDecls(c.fqn, name).len != 0) return true;
            for (c.primary_params) |p| if (std.mem.eql(u8, p.name, name)) return true;
            for (c.declared_props) |dp| if (std.mem.eql(u8, dp.name, name)) return true;
            for (c.methods) |mid| {
                const mf = b.module.funcById(mid) orelse continue;
                if (std.mem.eql(u8, mf.name, name)) return true;
            }
            for (c.supertypes) |sup| {
                if (n_next == next.len) return null;
                next[n_next] = sup;
                n_next += 1;
            }
        }
        for (next[0..n_next], 0..) |v, i| level[i] = v;
        n = n_next;
    }
    return false;
}

/// Whether a class or an ancestor declares an `invoke` operator with an
/// extension receiver: the only `invoke` that lets `recv.local(args)` bind a
/// local of that class. A stub on the chain keeps the answer open.
fn hierarchyHasExtensionInvoke(b: *FuncBuilder, cid: ir.ClassId, depth: u8) bool {
    if (depth >= 64 or cid.int() >= b.module.classes.items.len) return true;
    const c = &b.module.classes.items[cid.int()];
    if (c.is_stub) return true;
    for (c.methods) |mid| {
        const mf = b.module.funcById(mid) orelse continue;
        if (std.mem.eql(u8, mf.name, "invoke") and mf.kind == .member_extension) return true;
    }
    for (b.module.memberDecls(c.fqn, "invoke")) |fid| {
        const ds = b.module.decl_sigs.get(fid.int()) orelse continue;
        if (ds.receiver_ty != null or ds.kind == .member_extension) return true;
    }
    for (c.supertypes) |p| {
        if (hierarchyHasExtensionInvoke(b, p, depth + 1)) return true;
    }
    return false;
}

/// Whether a bound local, param, or captured-outer competes with the member.
/// Kotlin resolves `recv.name(args)` to a member or extension of `recv`; a
/// local competes only when its type is an extension-function type
/// (`Modifier.() -> Unit`). Treating a plain `(FocusState) -> Unit` as a
/// candidate makes the call invoke the callback with itself.
fn localCallableCompetes(b: *FuncBuilder, name: ast.Ident, declared_ty: ?TypeRef) Allocator.Error!bool {
    const anon_cap = isLowerAnonCapture(name.name) and b.resolve(name.name) == null and
        !b.isLocalFn(name.name) and !b.isParam(name.name) and !b.knowsOuter(name.name);
    if (!localCanTakeReceiverCall(b, name.name)) return false;
    const local_receiver_applicable = !b.isLocalExtFn(name.name) or
        try localExtensionReceiverCouldApply(b, name.name, declared_ty);
    return local_receiver_applicable and
        (b.isLocalFn(name.name) or b.isParam(name.name) or
            b.knowsOuter(name.name) or anon_cap or b.resolve(name.name) != null);
}

/// The local callable takes the call, the member still being tried first at
/// runtime through the arbitrated forms.
fn tryLocalCallableOnReceiver(f: *Fallback) Allocator.Error!?Reg {
    const b = f.b;
    const receiver = f.receiver;
    const name = f.name;
    const args = f.args;
    const ast_arg_names = f.ast_arg_names;
    const declared_ty = f.declared_ty;
    const anon_cap = isLowerAnonCapture(name.name) and b.resolve(name.name) == null and
        !b.isLocalFn(name.name) and !b.isParam(name.name) and !b.knowsOuter(name.name);
    if (!try localCallableCompetes(b, name, declared_ty)) return null;

    // Same-named local siblings share the plain-name slot, which may hold a
    // non-extension sibling or the boxed self-cell's placeholder, so select
    // the extension by signature. Needs a derived receiver: untyped, a
    // same-named global extension may be the target.
    if (declared_ty != null) {
        if (b.localFnOverloads(name.name)) |ovs| {
            if (try selectLocalExtOverload(b, ovs, declared_ty, args, ast_arg_names)) |mangled| {
                if (try lowerSelectedLocalExtCallWithReceiver(b, mangled, receiver, args, ast_arg_names)) |r| return r;
            }
        }
    }
    const local_reg = blk: {
        if (anon_cap) {
            const idx = try b.recordCapture(name.name);
            const r = b.allocReg();
            try b.push(.{ .LoadCapture = .{ .dst = r, .idx = idx } });
            break :blk r;
        }
        // A directly-bound local uses its own register; `resolveCapture`
        // would mint a bogus slot for a name that is not closed over.
        if (b.resolve(name.name)) |reg| {
            if (b.isBoxed(name.name)) {
                const c = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = c, .cell = reg } });
                break :blk c;
            }
            break :blk reg;
        }
        break :blk try resolveCapture(b, name.name);
    };
    const recv = try lowerReceiver(b, receiver);
    const run = try lowerArgRun(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
    const dst = b.allocReg();
// A receiver statically typed by an unbounded type parameter declares no
// members, so the in-scope callable is Kotlin's only candidate.
    const recv_erased = receiver.* == .Path and
        receiver.Path.segments.len == 1 and
        (b.isErasedRecvParam(receiver.Path.segments[0].name) or
            enclosingPropertyBareTp(b, receiver.Path.segments[0].name));
    const callable_takes_receiver = b.isReceiverLambdaParam(name.name) or
        b.isLocalExtFn(name.name) or b.localDeclRecvFn(name.name) or
        spliceParamTakesReceiver(b, name.name);
    const callable_shape_known = callable_takes_receiver or
        (b.isLocalFn(name.name) and !b.isLocalExtFn(name.name));
    if (callable_takes_receiver and
        (recv_erased or
            staticReceiverHasNoCompetingCallable(b, declared_ty, name.name, args.len, f.member_refuted) or
            noReceiverCouldDeclare(b, name.name, args.len)))
    {
        orEmitAudit(b, "member_or_local_exact_value", "CallValueWithThis", name.name);
        try b.push(.{ .CallValueWithThis = .{
            .dst = dst,
            .callee = local_reg,
            .receiver = recv,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .receiver_shape_exact = true,
        } });
        return dst;
    }
    if (runtime.envOnce("KLIO_CMV_WHY") != null) {
        // What the site could not decide: the receiver's derived head, the
        // local's shape, and which of the three receiver tests declined.
        const head: []const u8 = if (declared_ty) |t| typeHead(t.name) else "?";
        var hier: []const u8 = "-";
        if (declared_ty) |t| {
            const h = typeHead(t.name);
            if (b.module.registry.hierarchy_shadow_names.get(h)) |hs| {
                hier = if (!hs.complete) "incomplete" else if (hs.names.contains(name.name)) "declares" else if (b.module.extCouldApply(b.allocator, h, name.name, args.len)) "ext" else "none";
            } else hier = "absent";
        }
        const local_ty: []const u8 = if (b.localAstTy(name.name)) |t| t.name.name else if (b.localDeclTypeRef(name.name)) |t| t.name else "?";
        // The local's own class, as `localCanTakeReceiverCall` resolves it.
        var lh: []const u8 = "-";
        var lcname: []const u8 = "-";
        if (!std.mem.eql(u8, local_ty, "?")) {
            var lhead = typeHead(local_ty);
            if (std.mem.findScalarLast(u8, lhead, '.')) |i| lhead = lhead[i + 1 ..];
            if (emit_mod.classIdOfHead(b, lhead)) |lcid| {
                lcname = b.module.classes.items[lcid.int()].name;
                if (b.module.registry.hierarchy_shadow_names.get(lcname)) |hs| {
                    lh = if (!hs.complete) "incomplete" else if (hs.names.contains("invoke")) "invoke" else "no-invoke";
                } else lh = "absent";
            } else lh = "no-class";
        }
        const verdict = localReceiverCallVerdict(b, name.name);
        var idb: [512]u8 = undefined;
        const identity: []const u8 = if (b.localAstTy(name.name)) |t|
            (t.x().qualified_path orelse t.name.name)
        else if (b.localDeclTypeRef(name.name)) |t|
            declTypeIdentity(&idb, t)
        else
            "-";
        std.debug.print("[cmv-why] {s} can_take={} why={s} identity={s} decl_types={d} outer_names={d} cotn_recv={?d}\n", .{
            name.name,
            verdict.takes,
            verdict.why,
            identity,
            b.localDeclTypeCount(),
            b.outer_names.count(),
            if (declared_ty) |t| (if (classOfDeclType(b, t)) |c| c.int() else null) else null,
        });
        // The class rows behind both answers, and how the shadow record is keyed.
        const rows = [_]?ir.ClassId{
            if (b.localAstTy(name.name)) |t| classOfAstType(b, t) else if (b.localDeclTypeRef(name.name)) |t| classOfDeclType(b, t) else null,
            if (declared_ty) |t| classOfDeclType(b, t) else null,
        };
        for (rows, 0..) |row, ri| {
            const cid = row orelse continue;
            const c = &b.module.classes.items[cid.int()];
            const rec: []const u8 = if (b.module.registry.hierarchy_shadow_names.get(c.name)) |hs| (if (hs.complete) "complete" else "incomplete") else "absent";
            std.debug.print("[cmv-why]   row{d} name={s} fqn={s} stub={} rec={s} keys:", .{ ri, c.name, c.fqn, c.is_stub, rec });
            const simple = typeHead(c.fqn);
            var kit = b.module.registry.hierarchy_shadow_names.keyIterator();
            var shown: usize = 0;
            while (kit.next()) |k| {
                if (std.mem.endsWith(u8, k.*, simple) and shown < 4) {
                    std.debug.print(" {s}", .{k.*});
                    shown += 1;
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("[cmv-why] {s} recv={s} hier={s} takes_recv={} shape_known={} erased={} refuted={} param={} localfn={} outer={} bound={} anon={} local_ty={s} local_cls={s}:{s} class_names={} in={s}\n", .{
            name.name,                          head,
            hier,                               callable_takes_receiver,
            callable_shape_known,               recv_erased,
            f.member_refuted,                   b.isParam(name.name),
            b.isLocalFn(name.name),             b.knowsOuter(name.name),
            b.resolve(name.name) != null,       anon_cap,
            local_ty,                           lcname,
            lh,                                 b.module.registry.class_member_names.contains(name.name),
            build.currentRealFn() orelse "-",
        });
    }
    orEmitAudit(b, "member_or_local_callable", "CallMemberOrValue", name.name);
    try b.push(.{ .CallMemberOrValue = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .fallback = local_reg,
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .recv_erased = recv_erased,
        .fallback_takes_receiver = callable_takes_receiver,
        .fallback_receiver_shape_known = callable_shape_known,
    } });
    return dst;
}

/// `super.name(args)`: the call binds the supertype's member.
///
/// A super call is not virtual: the language names the declaration, so every
/// shape it can take is bound here and none is left to a runtime walk. In
/// Kotlin's order: the nearest implementation on the supertype's chain, the
/// `Any` member a chain declaring nothing bottoms out in, a nested class of
/// the supertype constructed on this receiver, and a host-backed base the
/// instance holds as its delegate.
fn trySuperCall(f: *Fallback) Allocator.Error!?Reg {
    const b = f.b;
    const receiver = f.receiver;
    const name = f.name;
    const args = f.args;
    const ast_arg_names = f.ast_arg_names;

    if (receiver.* != .Super) return null;
    const sup = receiver.Super;
    const base = (try superBase(b, sup)) orelse return null;
    const qual: ?[]const u8 = if (sup.qualifier) |qt| qt.name.name else null;
    if (try emit_mod.superTargetSlot(b, base.owner, qual, name.name, args, ast_arg_names)) |fid| {
        if (try emitSuperTargetCall(b, base.this_reg, fid, args, ast_arg_names)) |r| {
            orEmitAudit(b, "super_call", "Call", name.name);
            return r;
        }
    }
    const any_op = emit_mod.superAnyMember(b, base.owner, qual, name.name, args.len);
    if (any_op != .none) {
        const recv_slot = b.allocReg();
        try b.push(.{ .Move = .{ .dst = recv_slot, .src = base.this_reg } });
        const run = try lowerArgRun(b, args);
        const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
        const dst = b.allocReg();
        orEmitAudit(b, "super_call", "CallMember/any", name.name);
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv_slot,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .builtin = any_op,
            .builtin_proven = true,
        } });
        return dst;
    }
    if (emit_mod.superNestedClass(b, base.owner, qual, name.name) != null) {
        // `super.Inner(args)` builds the supertype's inner class on this
        // receiver, which is what the bare `Inner(args)` in this body does.
        var segs = [_]ast.Ident{name};
        var callee = Expr{ .Path = .{ .segments = &segs, .span = name.span } };
        var call = f.expr.*;
        call.Call.callee = &callee;
        orEmitAudit(b, "super_call", "NewInstance/nested", name.name);
        return try lowerExpr(b, &call);
    }
    if (emit_mod.superHostBackedBase(b, base.owner, qual)) |host_cls| {
        // The instance holds the host-backed base as its delegate, and the
        // member runs on the delegate: the base has no body to enter.
        const key = try std.fmt.allocPrint(b.allocator, "__delegate__{s}", .{host_cls.name});
        defer b.allocator.free(key);
        const key_c = try b.module.internConst(b.allocator, .{ .String = key });
        const del = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = del, .receiver = base.this_reg, .field = key_c, .own_cls = emit_mod.classIdOfHead(b, base.owner) } });
        const this_expr = Expr{ .This = .{ .qualifier = null, .span = name.span } };
        const ty = TypeRef{ .name = host_cls.fqn, .nullable = false, .args = &.{} };
        switch (try lowerResolvedMemberCall(b, &this_expr, name, args, ast_arg_names, f.ast_type_args, ty, .{ .reg = del, .non_null = true })) {
            .lowered => |r| {
                orEmitAudit(b, "super_call", "Call/delegate", name.name);
                return r;
            },
            else => {},
        }
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
        const declared_recv = try b.module.internConst(b.allocator, .{ .String = host_cls.fqn });
        const dst = b.allocReg();
        orEmitAudit(b, "super_call", "CallMember/delegate", name.name);
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = del,
            .name = nm,
            .args = run[0],
            .n_args = run[1],
            .builtin = ir.BuiltinMember.of(name.name, run[1]),
            .extra = try b.memberExtra(.{ .arg_names = arg_names, .trailing_lambda = b.callTrailingLambda(), .declared_recv = declared_recv }),
        } });
        return dst;
    }
    if (runtime.envOnce("KLIO_SUPER_WHY") != null)
        std.debug.print("[super-why] call {s}.{s}/{d} qualified={} unbound in={s}\n", .{ base.owner, name.name, args.len, sup.qualifier != null, build.currentRealFn() orelse "-" });
    orEmitAudit(b, "super_call", "unbound", name.name);
    return try emitUnboundSuper(b, base.owner, name.name);
}

/// The direct call a bound super target takes: the receiver first, then the
/// arguments as written. A named argument binds at the callee's entry the way
/// it does for any exact call, once the names are proved to be its
/// parameters'.
fn emitSuperTargetCall(
    b: *FuncBuilder,
    this_reg: Reg,
    fid: FuncId,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!?Reg {
    var names: []?ConstId = &.{};
    if (!allNull(ast_arg_names)) {
        const target = b.module.funcById(fid) orelse return null;
        if (target.params.len == 0) return null;
        const mapped = (try mapArgsToParams(b, target.params[1..], args, ast_arg_names)) orelse return null;
        defer b.allocator.free(mapped);
        for (mapped) |m| if (m == null) return null;
        const user_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const all = try b.allocator.alloc(?ConstId, user_names.len + 1);
        all[0] = null;
        @memcpy(all[1..], user_names);
        names = all;
    }
    const vals = try b.allocator.alloc(ir.Reg, args.len + 1);
    defer b.allocator.free(vals);
    const recv_slot = b.allocReg();
    try b.push(.{ .Move = .{ .dst = recv_slot, .src = this_reg } });
    vals[0] = recv_slot;
    for (args, 0..) |*arg, i| vals[i + 1] = try lowerExpr(b, arg);
    const args_start = try packContiguous(b, vals);
    const sdst = b.allocReg();
    const ctx_handed = try probe_mod.contextHandoverBegin(b, fid, &.{});
    try b.push(.{ .Call = .{
        .dst = sdst,
        .func = fid,
        .trailing_lambda = false,
        .args = args_start,
        .n_args = @intCast(vals.len),
        .arg_names = names,
        .type_args = &.{},
        .exact = true,
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    return sdst;
}

/// A super member lowering could not see. Kotlin guarantees the target
/// exists, so this is a gap in what lowering knows, and it fails where it is
/// reached rather than dispatching by name: the by-name answer is the
/// override making the super access, and that recurses.
pub fn emitUnboundSuper(b: *FuncBuilder, owner: []const u8, name: []const u8) Allocator.Error!Reg {
    const msg = try std.fmt.allocPrint(b.allocator, "super member {s}.{s} is not bound", .{ owner, name });
    defer b.allocator.free(msg);
    const c = try b.module.internConst(b.allocator, .{ .String = msg });
    const r = b.allocReg();
    try b.push(.{ .Const = .{ .dst = r, .value = c } });
    b.terminate(.{ .Throw = r });
    b.switchTo(try b.allocBlock());
    return b.allocReg();
}

/// The Compose syntax pass may thread a same-named call before overload
/// resolution; a source-shaped member or extension proves the declaration is
/// not composable, so the ABI pair does not belong here.
fn tryComposerPairRetry(f: *Fallback) Allocator.Error!?Reg {
    const b = f.b;
    const expr = f.expr;
    const receiver = f.receiver;
    const name = f.name;
    const args = f.args;
    const ast_arg_names = f.ast_arg_names;
    const ast_type_args = f.ast_type_args;
    const declared_ty = f.declared_ty;

    if (hasComposerArgPair(ast_arg_names) and args.len >= 2) {
        const source_args = args[0 .. args.len - 2];
        const source_names = ast_arg_names[0 .. ast_arg_names.len - 2];
        const source_member = try lowerResolvedMemberCall(
            b,
            receiver,
            name,
            source_args,
            source_names,
            ast_type_args,
            declared_ty,
            .{},
        );
        switch (source_member) {
            .lowered => |reg| return reg,
            .deferred, .none => {},
        }
        if (declared_ty) |recv_ty| {
            const source_extension = try resolveExtensionCallForArgs(
                b,
                recv_ty,
                name,
                source_args,
                source_names,
                false,
            );
            if (source_extension.target) |target_id| {
                if (b.module.funcById(target_id)) |target| {
                    if (!selectedCallHasComposerAbi(b.module, target_id, target)) {
                        var rewritten = expr.*;
                        rewritten.Call.args = source_args;
                        rewritten.Call.arg_names = source_names;
                        return try lowerMemberCallFallback(b, &rewritten);
                    }
                }
            } else if (source_extension.applicable and
                !source_extension.compiler_abi_applicable)
            {
                var rewritten = expr.*;
                rewritten.Call.args = source_args;
                rewritten.Call.arg_names = source_names;
                return try lowerMemberCallFallback(b, &rewritten);
            }
        }
    }
    return null;
}

/// A callable extension property: the marker field holds the callable the call
/// invokes.
fn tryCallableExtensionProperty(f: *Fallback) Allocator.Error!?Reg {
    const b = f.b;
    const receiver = f.receiver;
    const name = f.name;
    const args = f.args;
    const ast_arg_names = f.ast_arg_names;
    const declared_ty = f.declared_ty;
    const member_shadows_extensions = f.member_shadows_extensions;

    if (!member_shadows_extensions and
        callableExtensionPropertyTarget(b, receiver, name, args.len, declared_ty) != null)
    {
        const recv = try lowerReceiver(b, receiver);
        const callee_reg = b.allocReg();
        const marker_name = try std.fmt.allocPrint(b.allocator, "$extread${s}", .{name.name});
        const marker = try b.module.internConst(b.allocator, .{ .String = marker_name });
        try b.push(.{ .GetField = .{
            .dst = callee_reg,
            .receiver = recv,
            .field = marker,
        } });
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const dst = b.allocReg();
        orEmitAudit(b, "callable_extension_property", "CallValue", name.name);
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

/// An extension bound statically to its declaration identity.
fn tryExtensionCall(f: *Fallback) Allocator.Error!?Reg {
    const b = f.b;
    const receiver = f.receiver;
    const name = f.name;
    const args = f.args;
    const ast_arg_names = f.ast_arg_names;
    const ast_type_args = f.ast_type_args;
    const declared_ty = f.declared_ty;
    const member_shadows_extensions = f.member_shadows_extensions;

    withheld_ext_pick = null;
    withheld_ext_best_tier = false;
    if (!member_shadows_extensions) {
        ext_route_tag = "lowerMemberCallFallback:20993";
        if (try lowerResolvedExtensionCall(
            b,
            receiver,
            name,
            args,
            ast_arg_names,
            ast_type_args,
            declared_ty,
            // The one population the per-site audit measured: an explicit
            // receiver whose call is one step from the by-name emit.
            true,
        )) |reg| {
            audit_mod.fallbackNote(.extension_bound);
            return reg;
        }
    }
    return null;
}

/// Nothing bound statically, so dispatch stays deferred to the runtime member
/// walk, carrying the receiver's declared head so member-versus-extension is
/// still resolved against the declared type.
fn emitDeferredMemberCall(f: *Fallback) Allocator.Error!Reg {
    audit_mod.fallbackNote(.by_name);
    // Read before anything else lowers: `lowerReceiver` below recurses into
    // member calls of its own, each of which writes the slot.
    const withheld = takeWithheldExtPick();
    const b = f.b;
    const receiver = f.receiver;
    const name = f.name;
    const args = f.args;
    const ast_arg_names = f.ast_arg_names;
    const ast_type_args = f.ast_type_args;
    const declared_ty = f.declared_ty;

    const recv = try lowerReceiver(b, receiver);
    // A class-named receiver resolves its member's signature through the lifted
    // companion / class method registry, so each lambda argument learns its
    // expected value arity and a `() -> R` block drops its injected `it`.
    const uarg_arity: ?[]const i16 = try memberCallArgArities(b, receiver, name.name, args, ast_arg_names);
    // The block's receiver is settled where every namesake taking a receiver
    // agrees it has none, whichever of them the runtime picks.
    try lambda_mod.recordTrailingLambdaConsensus(b, name.name, args, ast_arg_names, ast_type_args, true);
    // Dispatch stays deferred (a runtime subtype might serve the name as a
    // member), but kotlinc types argument lambdas against the static
    // resolution, which with no member on that type is the extension candidate.
    var deferred_lambda_param_types: ?[]?[]ir.TypeRef = null;
    defer if (deferred_lambda_param_types) |types|
        deinitArgLambdaParamTypes(b.allocator, types);
    if (declared_ty) |recv_ty| blk: {
        var any_lambda = false;
        for (args) |*a| {
            if (a.* == .Lambda or a.* == .AnonFun) {
                any_lambda = true;
                break;
            }
        }
        if (!any_lambda) break :blk;
        const ext = try resolveExtensionCallForArgs(b, recv_ty, name, args, ast_arg_names, false);
        // Typing only: the withheld strict-key winner's param types serve the
        // closures, as does a tied set agreeing up to function-return positions.
        const target_id = ext.target orelse ext.sole_unknown orelse
            ext.param_rep orelse break :blk;
        const target = b.module.funcById(target_id) orelse break :blk;
        var rt = recv_ty;
        if (runtime.envOnce("KLIO_ALPT") != null) std.debug.print("[alpt-site] deferredExt fn={s}\n", .{target.name});
        deferred_lambda_param_types = try argLambdaParamTypesRecv(
            b,
            target,
            args,
            ast_arg_names,
            ast_type_args,
            1,
            substitutionRecv(b, &rt),
        );
        b.pending_arg_lambda_param_types = deferred_lambda_param_types;
    }
    const run = try lowerArgRunWithArity(b, args, uarg_arity);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
    // Kotlin resolves member-vs-extension against the receiver's declared type;
    // this channel is separate from `static_recv`, the extension-body receiver.
    // A nullable declared receiver carries its head too, since null-accepting
    // extensions overload by the underlying type.
    const declared_recv: ?ConstId = blk: {
        const t = declared_ty orelse break :blk null;
        var alias_scratch = std.heap.ArenaAllocator.init(b.allocator);
        defer alias_scratch.deinit();
        const canonical = try b.module.resolveTypeAliasAt(
            alias_scratch.allocator(),
            t,
            name.span.file,
            b.module.packageOfFile(name.span.file) orelse b.self_package,
        );
        const head = std.mem.trimEnd(u8, canonical.name, "?");
        if (head.len == 0) break :blk null;
        break :blk try b.module.internConst(b.allocator, .{ .String = head });
    };
    // `KLIO_EXT_AUDIT`: carry the withheld pick to the runtime so the walk can
    // say, one row per executed site, whether committing it would have named
    // the declaration actually served. The aggregated (name, receiver head)
    // join cannot: it merges sites with different candidate sets, so its
    // silence proves nothing.
    // The extension resolver's withheld pick, else the member gate's: a site
    // has one or the other, and both answer the same question.
    const audit_pick: ?FuncId = if (runtime.envOnce("KLIO_EXT_AUDIT") != null)
        (withheld.pick orelse f.member_pick)
    else
        null;
    const audit_kind: u8 = if (withheld.pick != null)
        (if (withheld.best_tier) 1 else 0)
    else
        2;
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .args = run[0],
        .n_args = run[1],
        .extra = try b.memberExtra(.{
            .trailing_lambda = b.callTrailingLambda(),
            .arg_names = arg_names,
            .declared_recv = declared_recv,
            .audit_pick = audit_pick,
            .audit_pick_kind = audit_kind,
        }),
    } });
    return dst;
}

