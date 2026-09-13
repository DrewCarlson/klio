//! Resolved member and extension call lowering, and the member call
//! fallback.

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
const superQualifier = member_mod.superQualifier;

const lambda_mod = @import("lambda.zig");
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

/// Lower a member call once the shared resolver identifies its declaration.
/// Final/private declarations become `Call(FuncId)`; overridable class members
/// become `CallVirtual(MethodSlotId)`. Both forms leave no runtime name lookup.
const ResolvedMemberLowering = union(enum) {
    none,
    deferred,
    lowered: Reg,
};

/// How a caller has already constrained the receiver of a member call.
const ReceiverState = struct {
    /// The receiver, already lowered. A safe call evaluates it once to test it
    /// for null, so re-lowering it here would evaluate it twice.
    reg: ?Reg = null,
    /// The receiver cannot be null at this point regardless of its declared
    /// type, so a nullable declared type does not disqualify a member.
    non_null: bool = false,
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
    if (ast_type_args.len != 0 or receiver.* == .Super) return .none;
    last_member_refuted = false;
    // The checker's own pick needs NO receiver type: it resolved the call
    // from the declarations, which is the whole point of running it. Asked
    // before the receiver-type requirement, because that requirement is a
    // property of the LAZY engine and this answer did not come from it.
    // Restricted to an image-declared extension for the same reasons the
    // later consumer is: an extension's ABI is receiver-in-the-leading-slot
    // whatever the receiver turns out to be, so the emit is decided.
    if (declared_ty == null and !std.mem.eql(u8, runtime.envOnce("KLIO_EAGER_MEMBER") orelse "1", "0")) {
        if (b.module.eagerExternCallTarget(name.span)) |ep| ez: {
            audit_mod.lm_eager_norecv[0] += 1;
            const ef = b.module.funcById(ep) orelse {
                audit_mod.lm_eager_norecv[1] += 1;
                break :ez;
            };
            if (ef.params.len == 0 or !std.mem.eql(u8, ef.params[0].name, "this")) {
                audit_mod.lm_eager_norecv[2] += 1;
                break :ez;
            }
            if (ef.params.len != args.len + 1) {
                audit_mod.lm_eager_norecv[3] += 1;
                break :ez;
            }
            const recv_reg = try lowerExpr(b, receiver);
            const args_start = b.allocReg();
            const run = try lowerArgRun(b, args);
            try b.push(.{ .Move = .{ .dst = args_start, .src = recv_reg } });
            const dst = b.allocReg();
            lmNote(.bound_static);
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
            return .{ .lowered = dst };
        }
    }
    const ty = declared_ty orelse {
        if (runtime.envOnce("KLIO_EXT_TRACE")) |wanted| {
            if (std.mem.eql(u8, wanted, name.name)) {
                std.debug.print("[member-static] {s} recv=<unknown>\n", .{name.name});
            }
        }
        // A call every value answers, on a receiver nothing could name.
        // `toString()` and `hashCode()` are declared as `Any?` EXTENSIONS in
        // the stdlib, and those are what Kotlin binds when the receiver may
        // be null; for a non-null receiver they delegate to the member, so
        // the observable result is the same either way. Only a UNIQUE `Any?`
        // extension of that name and arity is taken, so a same-named
        // declaration on a real type can never be reached through here.
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
                    lmNote(.bound_static);
                    return .{ .lowered = dst };
                }
            }
        }
        // A call whose only declaration is a UNIVERSAL INLINE extension —
        // `fun <T, R> T.let(block: (T) -> R): R` and its family — is not a
        // dispatch at all: the body is spliced at this site whatever the
        // receiver turns out to be. Verified with `KLIO_MISS_TRACE=let`,
        // which reports no runtime miss for an untyped receiver. Counting
        // it against the receiver-typing residue measured work that does
        // not exist.
        if (uniqueUniversalInlineExtension(b, name.name, args.len) != null) {
            lmNote(.bound_static);
            return .none;
        }
        // `expected.getter()` — the callee is a RECEIVER-TAKING callable
        // VALUE in scope (`getter: T.() -> P`) and the receiver's declared
        // type is a bare type parameter: kotlinc resolves against the
        // parameter's bound, finds no member, and commits the value
        // (invoke) protocol. There is no class slot to bind BY DESIGN —
        // the same census category as a function-typed receiver; the
        // member-emission arm below commits `CallValueWithThis`.
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
        if (b.census_quiet) return .none;
        lmNote(.no_receiver_type);
        if (!norecvCensusOn()) return .none;
        audit_mod.lm_norecv[@intFromEnum(std.meta.activeTag(receiver.*))] += 1;
        if (receiver.* == .This and runtime.envOnce("KLIO_NORECV_NAMES") != null) {
            std.debug.print("[no-recv-this] call={s} fn={s} owner={s} recv={s} splice={s}\n", .{
                name.name,
                build.currentRealFn() orelse "-",
                b.ownerClass() orelse "-",
                b.recvTy() orelse "-",
                b.spliceRecvTy() orelse "-",
            });
        }
        audit_mod.lm_norecv_eager[if (b.module.eagerTypeOf(receiver.span()) != null) 0 else 1] += 1;
        if (receiver.* == .Call) {
            audit_mod.lm_norecv_call[@intFromEnum(classifyCallReturn(b, receiver))] += 1;
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
        if (receiver.* == .Path and receiver.Path.segments.len == 1) {
            const rn = receiver.Path.segments[0].name;
            const which: NoRecvPath = if (b.resolve(rn) != null)
                .local_no_decl_type
            else if (b.knowsOuter(rn))
                .captured
            else if (enclosingHasMemberNamed(b, rn))
                .enclosing_member
            else
                .unknown;
            audit_mod.lm_norecv_path[@intFromEnum(which)] += 1;
            if (runtime.envOnce("KLIO_NORECV_NAMES")) |want| {
                if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, @tagName(which))) {
                    var nloc_buf: [256]u8 = undefined;
                    const nloc: []const u8 = nblk: {
                        if (span.active_map) |m| {
                            if (m.getChecked(name.span.file)) |sf| {
                                const lc = sf.lineCol(name.span.start);
                                const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |si| sf.path[si + 1 ..] else sf.path;
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
            if (which == .local_no_decl_type) {
                if (b.localInitExpr(rn)) |ini| {
                    audit_mod.lm_norecv_init[1] += 1;
                    audit_mod.lm_norecv_call[@intFromEnum(classifyCallReturn(b, ini))] += 1;
                    // `KLIO_NORECV_WHY=<name>`: at a counted site whose init
                    // IS recorded, re-run the lazy deriver and print its
                    // terminal, so the failing channel is named instead of
                    // guessed (the self-shadow fix measured census-neutral;
                    // this finds where these sites actually die).
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
                                        const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |i| sf.path[i + 1 ..] else sf.path;
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
                } else audit_mod.lm_norecv_init[0] += 1;
            }
        }
        return .none;
    };
    // A nullable receiver keeps a member call off the static path, because an
    // extension declared on `T?` outranks a member there — `x.f()` on a
    // nullable `x` is only legal when such an extension exists. A SAFE call is
    // different: its member runs on the non-null branch, which is exactly the
    // receiver a member declaration expects.
    if (ty.nullable and !recv_state.non_null) {
        // ...unless no such extension EXISTS. The rule above is about an
        // extension on `T?` outranking the member; where the name declares
        // none, Kotlin has only one legal target for `x.f()` on a nullable
        // `x` — the member — and the call binds to it. Checked across the
        // whole module, so a later-loaded pack cannot introduce one behind
        // this decision.
        const nn_head = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
        var any_nullable_ext = false;
        for (b.module.funcsBySimpleName(name.name)) |fid| {
            const f = b.module.funcById(fid) orelse continue;
            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
            if (!f.params[0].ty.nullable) continue;
            const eh = typeHead(std.mem.trimEnd(u8, f.params[0].ty.name, "?"));
            if (eh.len == 0 or std.mem.eql(u8, eh, nn_head) or
                b.module.classIsOrExtends(nn_head, eh))
            {
                any_nullable_ext = true;
                break;
            }
        }
        if (any_nullable_ext) {
            // The extension that outranks the member is a DECLARATION like
            // any other, and Kotlin binds an extension statically — its
            // receiver rides the leading `this` slot. Resolve it here rather
            // than handing the whole call to the runtime. Only when the
            // receiver has not already been lowered, since this path lowers
            // it itself and a second evaluation would be visible.
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
    const recv_ty = if (ty.nullable)
        TypeRef{ .name = std.mem.trimEnd(u8, ty.name, "?"), .nullable = false, .args = ty.args }
    else
        ty;
    var identity = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.indexOfScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    const head = typeHead(identity);
    // A simple head shared by several classes (geometry's `Size` value
    // class and the `androidx.annotation.Size` annotation) is decided the
    // way the source decides it: by the call site's imports and package.
    var owner_id = if (std.mem.indexOfScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else
        b.module.uniqueClassIdBySimpleName(head) orelse
            (if (b.isTypeParam(head)) null else b.module.classIdIndexed(head, b.self_package, name.span.file));
    // A receiver typed by a TYPE PARAMETER names no class, and that was the
    // whole of the `no_class_id` bucket — `C`, `M`, `A`, `T`, `R` accounted for
    // 769 of 915 sites. Kotlin resolves a member call on such a value against
    // the parameter's declared upper bound, so resolve the head through it.
    // Only a `complete` bound is used: an incomplete record dropped
    // intersection or structural information and cannot stand in for the type.
    if (owner_id == null) {
        if (b.typeParamBound(head)) |tpb| {
            // The bound's ARGUMENTS do not matter here: this asks only which
            // class owns a member call on the parameter, and `C` bounded by
            // `MutableCollection<in T>` answers `MutableCollection`. Those two
            // parameters were 6,590 of the 8,702 sites in this bucket.
            if (tpb.complete or (tpb.head_only and
                !std.mem.eql(u8, runtime.envOnce("KLIO_TP_HEAD") orelse "1", "0")))
            {
                var bound_identity = std.mem.trimEnd(u8, tpb.bound, "?");
                if (std.mem.indexOfScalar(u8, bound_identity, '<')) |lt| bound_identity = bound_identity[0..lt];
                owner_id = if (std.mem.indexOfScalar(u8, bound_identity, '.') != null)
                    b.module.classIdByFqn(bound_identity)
                else
                    b.module.uniqueClassIdBySimpleName(typeHead(bound_identity));
            }
        }
    }
    // A declared type the module-wide lookups miss can still name a class
    // the DECLARATION SITE can see: `Outer.Inner` written without its
    // package resolves as a `.`-aligned FQN suffix (the type-position
    // convention), and a bare nested-class name resolves through the
    // enclosing classifier chain — inside `HexFormat`, `BytesHexFormat`
    // names its nested sibling even though nested classes are deliberately
    // invisible to the module-wide simple-name index.
    if (owner_id == null) {
        if (std.mem.indexOfScalar(u8, identity, '.') != null) {
            owner_id = b.module.classIdByQualifiedSuffix(identity);
        } else if (!b.isTypeParam(head)) {
            owner_id = nestedClassIdAtLexicalSite(b, head);
        }
    }
    // A head shaped like a type PARAMETER that names no class and carries no
    // bound record in this scope is still a type parameter — one declared by
    // an enclosing generic the body does not have in scope (`Map.Entry<K, V>`
    // read inside `AbstractMap.Companion.entryHashCode`). Kotlin's floor for
    // any type parameter is `Any?`, and a call on it can only target a member
    // of that floor, so resolve there rather than giving up on the receiver.
    // A class-param IDENTITY MANGLE (`$class$ N i:E`) is the same shape
    // under a stable spelling.
    if (owner_id == null and head.len != 0 and
        (((head.len <= 2) and std.ascii.isUpper(head[0]) and b.module.classId(head) == null) or
            ir.parseClassTypeParamIdentity(head) != null))
    {
        owner_id = b.module.uniqueClassIdBySimpleName("Any") orelse
            b.module.classIdByFqn("kotlin.Any");
    }
    // A FUNCTION-typed receiver dispatches by the invoke convention, not a
    // class slot: `startCoroutineUninterceptedOrReturn` on a
    // `DeepRecursiveFunctionBlock` (a typealias to a suspend fn type) has no
    // class row to bind BY DESIGN. The backends compile these to the value
    // (invoke) protocol; the census counts them as their own category so
    // the bindable share reads honestly.
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
    // An argument written `expr as Any` fits no member whose parameter has
    // a concrete class type: kotlinc binds the same-named extension instead
    // (`zs.contains(object {} as Any)` on a `Collection<Z>` implementation
    // is `Iterable<T>.contains`, never the member `contains(element: Z)`).
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
                const ext = try lowerResolvedExtensionCall(b, receiver, name, args, ast_arg_names, ast_type_args, ty);
                if (ext) |reg| {
                    lmNote(.bound_static);
                    return .{ .lowered = reg };
                }
            }
        }
    }
    // A LOCAL-CLASS typing record: no class row, but the mangled head
    // registered its methods as headers — probe the member table directly
    // and bind the virtual slot (the runtime slot's by-name fallback
    // executes the RegisterClass method).
    if (owner_id == null and ast_type_args.len == 0 and allNull(ast_arg_names) and
        // ONLY the local-class typing records (the `$lc` mangle):
        // class_super_names is the GENERAL super registry, and probing it
        // for any row-less head bound atomicfu's pack stubs over their
        // host bindings (every CAS deadlocked).
        std.mem.indexOf(u8, head, "$lc") != null and
        b.module.registry.class_super_names.get(head) != null)
    {
        var probe: usize = args.len;
        while (probe <= args.len + 3) : (probe += 1) {
            var kb: [192]u8 = undefined;
            const key = std.fmt.bufPrint(&kb, "{s}\x00{s}\x00{d}", .{ head, name.name, probe }) catch break;
            const fid = b.module.registry.member_method_fids.get(key) orelse continue;
            const recv_reg = try lowerExpr(b, receiver);
            const run = try lowerArgRun(b, args);
            const dst = b.allocReg();
            orEmitAudit(b, "local_class_member_slot", "CallVirtual", name.name);
            try b.push(.{ .CallVirtual = .{
                .dst = dst,
                .receiver = recv_reg,
                .slot = ir.MethodSlotId.fromFunc(fid),
                .args = run[0],
                .n_args = run[1],
            } });
            lmNote(.bound_virtual);
            return .{ .lowered = dst };
        }
    }
    var static_owner = owner_id orelse {
        lmNote(.no_class_id);
        noteNoClassHead(head);
        if (norecvCensusOn()) {
            const k: NoClassKind = if (std.mem.indexOfScalar(u8, identity, '.') != null)
                .fqn_unknown
            else if (b.module.classId(head) != null)
                .simple_ambiguous
            else
                .simple_unknown;
            audit_mod.lm_noclass[@intFromEnum(k)] += 1;
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
    };
    if (receiver.* == .Path and receiver.Path.segments.len != 0) {
        const receiver_name = receiver.Path.segments[receiver.Path.segments.len - 1].name;
        // A bare name resolving to nothing lexically is a CLASS-name access
        // (whose members live on the companion) only when no enclosing
        // receiver declares a property of the name: `iterator` inside
        // `object : Iterator<T> { val iterator = ... }` is a `this` property
        // read typed by the head channel, and redirecting it to a companion
        // silently dropped the whole resolution.
        if (b.resolve(receiver_name) == null and !b.knowsOuter(receiver_name) and
            !enclosingHasMemberNamed(b, receiver_name) and
            // A TOP-LEVEL PROPERTY read is a VALUE receiver, never a
            // classifier access: `asserter.assertEquals(...)` inside
            // kotlin.test resolved to Asserter's (absent) companion and
            // dropped the whole member resolution to the walk.
            b.module.registry.top_level_prop_pkgs.get(receiver_name) == null and
            static_owner.int() < b.module.classes.items.len)
        {
            const classifier = &b.module.classes.items[static_owner.int()];
            if (!classifier.is_object) {
                static_owner = classifier.companion orelse return .none;
            }
        }
    }

    var shape_set = try buildStaticReturnArgShapes(b, args, ast_arg_names);
    defer shape_set.deinit(b.allocator);
    const shapes = shape_set.shapes;
    const lexical_owner: ?ir.ClassId = if (b.ownerClass()) |owner_name|
        (if (std.mem.indexOfScalar(u8, owner_name, '.') != null)
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
    // A SELF-recursive member pick with a non-authoritative argument defers
    // to the runtime walk: kotlinc rejects the member when an invariant
    // generic argument mismatches (RangesTest's private
    // `assertEquals(List<IntRange>, List<LongRange>)` delegates to
    // kotlin.test's on `expected.map { it.toLong() }` — binding itself
    // statically recursed forever), and only the runtime holds the argument
    // values that decide it. A genuinely recursive call still binds through
    // the walk; this trades the static commit for a deferred dispatch on
    // exactly the shape that can self-capture.
    if (resolved.target) |rt| self_rec: {
        const cur = build.currentRealFn() orelse break :self_rec;
        if (!std.mem.eql(u8, cur, name.name)) break :self_rec;
        const rf = b.module.funcById(rt) orelse break :self_rec;
        if (!std.mem.eql(u8, rf.name, name.name)) break :self_rec;
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
                // A derived head whose generic CONTENT is unresolved
                // (`List<*>`, a bare type variable) cannot prove the
                // invariant argument the member declares.
                for (t.args) |ta| {
                    const an = std.mem.trimEnd(u8, ta.name, "?");
                    if (std.mem.eql(u8, an, "*")) break :blk true;
                    if (an.len > 0 and an.len <= 2 and std.ascii.isUpper(an[0])) break :blk true;
                }
                break :blk false;
            };
            if (undecided) return .none;
        }
    }
    // The checker's own pick, when it made one. Its candidate set for a
    // member call on a known receiver class is complete (the image publishes
    // every extension on the class and its supertype chain) and it ranks by
    // ARGUMENT TYPE, which is the one thing the lazy engine's shape-based
    // ranking cannot do. It is preferred exactly where the bare-call arm
    // prefers it — and where the resolver reached no target at all, it is the
    // only answer, so a deferral becomes a static bind.
    // Only where the resolver reached NO target: everything downstream of
    // this point reads `resolved` for dispatch kind, owner, and arity, so a
    // pick that disagrees with it would be spliced into a resolution
    // describing something else. Where the resolver has no target there is
    // nothing to disagree with, and the checker's answer is the only one.
    const eager_pick: ?FuncId = if (!std.mem.eql(u8, runtime.envOnce("KLIO_EAGER_MEMBER") orelse "1", "0")) blk: {
        const ep = b.module.eagerExternCallTarget(name.span) orelse break :blk null;
        const ef = b.module.funcById(ep) orelse break :blk null;
        if (ef.params.len == 0 or !std.mem.eql(u8, ef.params[0].name, "this")) break :blk null;
        // Where the resolver DID name a declaration, the pick may replace it
        // only if both are the same call form — an extension, receiver in the
        // leading slot. Everything downstream reads `resolved` for the shape
        // of the call, and swapping a declaration of one shape for another is
        // what broke `d += x` on Duration. Same shape, and the swap is just
        // which declaration the identical emit names.
        if (resolved.target) |rt| {
            if (rt.int() == ep.int()) break :blk null;
            const rf = b.module.funcById(rt) orelse break :blk null;
            if (rf.params.len == 0 or !std.mem.eql(u8, rf.params[0].name, "this")) break :blk null;
            if (resolved.dispatch != .direct) break :blk null;
        }
        break :blk ep;
    } else null;
    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name.name)) {
            std.debug.print("[lrm] {s} owner={s} dispatch={s} applicable={} target={?d} eager={?d} nargs={d} shapes:", .{ name.name, b.module.classes.items[static_owner.int()].fqn, @tagName(resolved.dispatch), resolved.applicable, if (resolved.target) |t| t.int() else null, if (eager_pick) |e| e.int() else null, args.len });
            for (shapes) |*sh| std.debug.print(" {s}{s}", .{ if (sh.ty) |t| t.name else "?", if (sh.is_lambda) "(lambda)" else "" });
            std.debug.print("\n", .{});
        }
    }
    const func_id = eager_pick orelse resolved.target orelse {
        last_member_refuted = !resolved.applicable;
        return if (resolved.applicable) .deferred else .none;
    };
    // A HOST-SHADOWED declaration (a pack stub whose installed binding is
    // authoritative — atomicfu's atomics) must never statically bind its
    // interpreted body; the runtime walk's binding preference arbitrates.
    if (b.module.funcById(func_id)) |cf| {
        if (cf.hasBody() and b.module.registry.host_shadowed_fqns.contains(cf.fqn)) {
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
    // The resolver identifies a single candidate but withholds dispatch when an
    // argument's type is unknown, so its applicability is unproven. Measured,
    // that is EVERY deferral reaching this point — sites with a fully proven
    // declaration identity that emitted no static binding at all.
    //
    // The identity is not in doubt there; only whether Kotlin would pick this
    // member. The one thing that beats an applicable member is an EXTENSION of
    // the same name, so ask exactly that. `extCouldApply` is chain-aware and
    // conservative — a generic-receiver extension, a supertype's extension, or a
    // stale index all answer yes — so a `false` means nothing else could bind
    // and the member's identity is sufficient.
    // Computed for stub/value receivers too: their direct-dispatch escape
    // below still requires the extension-shadow question answered — String
    // and the unsigned shells carry extension families everywhere.
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
            .index_stale => audit_mod.lm_promo[@intFromEnum(PromoBlock.ext_index_stale)] += 1,
            .generic_receiver => audit_mod.lm_promo[@intFromEnum(PromoBlock.ext_generic_receiver)] += 1,
            .own_head => audit_mod.lm_promo[@intFromEnum(PromoBlock.ext_own_head)] += 1,
            .builtin_super => audit_mod.lm_promo[@intFromEnum(PromoBlock.ext_builtin_super)] += 1,
            .declared_super => audit_mod.lm_promo[@intFromEnum(PromoBlock.ext_declared_super)] += 1,
        }
    }
    // Third-derivation promotion: the extension-shadow question answers by
    // PROOF when every argument is authoritative — the member compatible,
    // every reachable same-name extension refuted (`KLIO_MEMBER_PROMO=0`
    // disables for A/B).
    // The stub/value receiver no longer blocks the proof: the runtime
    // resolves a virtual slot against the receiver's runtime class and
    // prefers the FQN-keyed intrinsic for host values, which is the same
    // rule the no-extension branch below already relies on.
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
            // A member REFUTED by an authoritative argument is not the
            // binding at all: fall to the extension path with the
            // refutation recorded, so the ranker's strict-winner rule can
            // commit the extension kotlinc binds
            // (`set.removeAll(iterable)` -> MutableCollection.removeAll).
            if (std.mem.eql(u8, ir.Module.mpp_why, "member-arg-refuted")) {
                last_member_refuted = true;
                return .none;
            }
        }
    }
    if (promo_ext_why == .none and
        resolved.dispatch == .deferred and resolved.target != null)
    {
        // Ask the resolver's own direct-vs-virtual rule rather than assuming
        // virtual: a final or private method has no vtable slot, and a virtual
        // emission for one fails at runtime even when the receiver's class is
        // exactly the declaring class. A stub/value receiver (no vtable at
        // all) still takes a DIRECT answer — a final method on a closed
        // host-backed class binds by fid; only a virtual answer stays
        // deferred for it.
        // A VIRTUAL answer is accepted for stub/value receivers too: the
        // runtime resolves the slot against an interpreted receiver's class
        // and prefers the FQN-keyed intrinsic for host values (the VOWN
        // model) — holding the deferral for blocked classes predates that
        // and left every bodyless expect member (`Long.shl`,
        // `MutableList.add`) and unsigned-array member dynamic.
        if (b.module.dispatchForTarget(static_owner, resolved.target.?)) |d| {
            resolved.dispatch = d;
        }
    }
    if (eager_pick) |ep| {
        // The resolver reached no target, so its `deferred` says nothing
        // about THIS declaration — it says the resolver could not name one.
        // The checker named one by argument type, and how that declaration
        // dispatches follows from the declaration: an extension carries its
        // receiver as a leading `this` parameter and is statically bound in
        // Kotlin; anything else goes through the receiver's slot.
        // EXTENSIONS only. An extension carries its receiver as a leading
        // `this` parameter and Kotlin binds it statically, so the call form
        // follows from the declaration alone. A class MEMBER does not: it
        // needs a method slot on the receiver's runtime class, and asserting
        // one the resolver never proved broke `d += x` on Duration — the
        // slot was not there to call.
        if (b.module.funcById(ep)) |ef| {
            if (ef.params.len != 0 and std.mem.eql(u8, ef.params[0].name, "this")) {
                resolved.dispatch = .direct;
            }
        }
    }
    // A VALUE-CLASS owner has no runtime dispatch to defer to: its instances
    // travel unboxed, so a deferred member call would look for the member on
    // the underlying value's class and miss (`set(value) { … }` on
    // `Updater<T>`, whose receiver is the Composer at run time). The class is
    // final and the target is its only unrefuted member, so bind it directly.
    if (resolved.dispatch == .deferred and resolved.target != null and resolved.applicable) {
        const owner_cls = &b.module.classes.items[static_owner.int()];
        if (owner_cls.is_value) {
            resolved.dispatch = b.module.dispatchForTarget(static_owner, resolved.target.?) orelse .direct;
            if (resolved.dispatch == .deferred) resolved.dispatch = .direct;
        }
    }
    if (resolved.dispatch == .deferred) {
        lmNote(.resolver_declined);
        if (norecvCensusOn()) {
            const k: DeclineKind = if (resolved.target != null)
                .target_known_deferred
            else if (resolved.applicable)
                .ambiguous_applicable
            else
                .not_applicable;
            audit_mod.lm_decline[@intFromEnum(k)] += 1;
        }
        return .deferred;
    }
    var target = b.module.funcById(func_id) orelse {
        lmNote(.resolver_declined);
        if (norecvCensusOn()) audit_mod.lm_decline[@intFromEnum(DeclineKind.target_unresolvable)] += 1;
        return .deferred;
    };
    if (resolved.dispatch == .virtual) {
        const owner = &b.module.classes.items[static_owner.int()];
        // A stub/value owner whose target is FINAL on a closed class never
        // needs the slot — and its vtable-less representation cannot serve
        // one. Downgrade to the direct fid call (`Result.exceptionOrNull`
        // as a virtual slot misdispatched on the value representation and
        // `runCatching { }.fold` took the success arm holding the thrown
        // exception).
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
    if (resolved.dispatch == .virtual) {
        const owner = &b.module.classes.items[static_owner.int()];
        // Numeric virtual slots operate on `Value.Instance`. Classifier ABI
        // metadata keeps mixed host-backed receivers on the host member path
        // while source-backed stdlib classes use the same static ABI as user
        // classes. Named, defaulted, and vararg interface calls bind against
        // the numeric declaration ABI.
        // A `specialized` classifier's values are host-represented, so a slot
        // cannot index a vtable on them. It is still the right EMISSION:
        // `invokeVirtualMember` resolves the slot against an interpreted
        // receiver's own class (honouring a user subtype's override) and
        // falls back to the member's name only for a host-backed value, which
        // is what the site did unconditionally before.
        // Stub/value owners emit their virtual slot (`KLIO_VOWN=0`
        // disables): the runtime resolves the slot against an interpreted
        // receiver's class and name-falls-back for host values. The
        // prerequisite was the FINAL-member direct downgrade above — the
        // Uuid/Result family broke precisely because a final value-class
        // member (`Result.exceptionOrNull`) rode a slot its value
        // representation could not serve.
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
            return .deferred;
        }
    }

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
    // Lowering the receiver expression can append functions (a lambda in the
    // receiver lowers into the module's func table) and reallocate it,
    // invalidating `target`; re-fetch the pointer before reading it again.
    target = b.module.funcById(func_id) orelse {
        declineNote(.target_unresolvable);
        return .deferred;
    };
    if (resolved.dispatch == .virtual) {
        // A virtual target without even a receiver param cannot be bound
        // here on any path (the named/vararg mapping below already deferred
        // it); defer before the receiver-skipping scans slice params[1..].
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
            try b.push(.{ .CallSpread = .{
                .dst = dst,
                .callee = recv_reg,
                .parts = try lowerSpreadParts(b, args),
                .virtual_slot = ir.MethodSlotId.fromFunc(func_id),
                .arg_params = arg_params,
                .trailing_lambda = b.callTrailingLambda(),
            } });
            return .{ .lowered = dst };
        }
        const run = try lowerArgRunWithArity(b, args, arg_arity);
        lmNote(.bound_virtual);
        try b.push(.{ .CallVirtual = .{
            .dst = dst,
            .receiver = recv_reg,
            .slot = ir.MethodSlotId.fromFunc(func_id),
            .args = run[0],
            .n_args = run[1],
            .arg_params = arg_params,
            .arg_names = if (arg_params == null) arg_names else &.{},
            .trailing_lambda = b.callTrailingLambda(),
        } });
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
    return .{ .lowered = dst };
}

/// Bind an explicit-receiver top-level extension to its declaration identity.
/// Extensions are statically dispatched in Kotlin; the module resolver only
/// returns a target when receiver compatibility, visibility, and overload
/// ranking are all provable without a runtime value.
fn lowerMemberExtensionDispatchReceiver(
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

    const base = (try resolveThisRegKind(b, true, false)) orelse return null;
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

/// The DECLARED type head of each argument, interned, for a construction
/// site. Kotlin picks a constructor overload from the STATIC types; an
/// interpreted instance carries no class name the runtime ranking can read,
/// so without this a subtype argument could not outrank a supertype slot.
/// Null where lowering has no declared type — the runtime keeps its own
/// value-shaped ranking for those slots.
pub fn ctorArgStaticHeads(b: *FuncBuilder, args: []const Expr) Allocator.Error![]?ir.ConstId {
    const out = try b.allocator.alloc(?ir.ConstId, args.len);
    errdefer b.allocator.free(out);
    var any = false;
    for (args, 0..) |*a, i| {
        out[i] = null;
        const ty = argDeclTypeRef(b, a) orelse continue;
        var h = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
        if (std.mem.lastIndexOfScalar(u8, h, '.')) |d| h = h[d + 1 ..];
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

/// The one extension of this name and arity whose declared receiver is
/// `Any?` — the universal surface every value has (`toString`, `hashCode`).
/// Null unless exactly one such declaration exists and no other declaration
/// of the name could compete, so an untyped receiver can never be handed to
/// a namesake meant for a real type.
/// The one extension of this name and arity that is INLINE and declares an
/// unbounded type PARAMETER as its receiver — the scope-function family,
/// which applies to every value and is spliced rather than dispatched.
/// Null unless exactly one such declaration exists and no other extension
/// of the name could compete.
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
        // A MEMBER of the same name is not competition: `Any?.toString()`
        // delegates to it, so the two agree wherever both apply.
        const is_ext = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        if (!is_ext) continue;
        if (f.params.len != nargs + 1) continue;
        // An INLINE extension must reach its splice: a non-local `return`
        // inside its lambda argument depends on the body being expanded
        // here, and a real call would strand it.
        if (f.is_inline) return null;
        const rt = f.params[0].ty;
        const rt_head = typeHead(std.mem.trimEnd(u8, rt.name, "?"));
        // `Any?` receivers, and UNBOUNDED bare-type-param receivers
        // (`fun <A, B> A.to(that: B)`) — the same universal shape: the
        // declaration applies to every receiver, so no receiver typing is
        // needed to commit it. A same-named class MEMBER anywhere refuses
        // (the member would win on its receiver at run time).
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

pub var ext_route_tag: []const u8 = "?";

pub fn lowerResolvedExtensionCall(
    b: *FuncBuilder,
    receiver: *const Expr,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
    ast_type_args: []const ast.TypeRef,
    declared_ty: ?TypeRef,
) Allocator.Error!?Reg {
    // Explicit call-site type arguments constrain the eligible generic
    // declarations before ordinary overload ranking. The exact extension
    // path defers until it carries and proves that substitution.
    if (ast_type_args.len != 0) return null;
    const recv_ty = declared_ty orelse return null;
    const resolution = try resolveExtensionCallForArgs(
        b,
        recv_ty,
        name,
        args,
        ast_arg_names,
    );
    const func_id = resolution.target orelse blk: {
        // A return-variant tie on the MEMBER form discriminates by the
        // trailing lambda's derived return exactly as the bare form does
        // (`a.sumOf { it.size.toLong() }` on a typed receiver ran the
        // Double variant through the runtime re-pick).
        if (allNull(ast_arg_names)) {
            const cands = try b.module.bareCallCandidates(b.allocator, name.name, name.span.file);
            defer b.allocator.free(cands);
            const rh = typeHead(std.mem.trimEnd(u8, recv_ty.name, "?"));
            if (try overloadPickByLambdaReturnFull(b, cands, args, args.len, rh, receiver)) |picked| {
                break :blk picked;
            }
        }
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
    // An image header stub of an inline extension carries no `is_inline`
    // flag on its Func row but does have its declaration in the inline
    // table: it must splice (a direct call reaches a bodiless stub whose
    // reified parameters nothing binds).
    if (target.is_inline or inline_state.inlineAstById(func_id.int()) != null) {
        const inline_decl = inline_state.inlineAstById(func_id.int()) orelse return null;
        inline_state.ensureInlineBody(inline_decl);
        // The splice lowers its lambda arguments in its OWN arg loop, which
        // bypasses `lowerArgRun`'s typing transfer — yet each lambda still
        // lowers a closure body eagerly at emit. Compute the instantiated
        // expected param types here so those bodies type their params; the
        // spliced copy gets the same facts through the window channels.
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
        // The splice binds its lambda arguments by expanding their bodies,
        // not through `lowerArgRun`, so the `-> Unit` mask that typing set
        // on `pending_arg_lambda_unit` has no consumer on this path. Clear
        // it now: left set, it dangles into any call lowered inside the
        // spliced body (a nested `accept { }` predicate) and is mistaken
        // there for that call's own mask, coercing the lambda to Unit.
        if (b.pending_arg_lambda_unit) |m| b.allocator.free(m);
        b.pending_arg_lambda_unit = null;
        b.pending_arg_lambda_param_types = inline_lambda_param_types;
        defer b.pending_arg_lambda_param_types = null;
        // Engine step four: solve the callee's bindings ONCE (receiver +
        // typed args) and hand them to the WINDOW as full bound refs —
        // every in-window consumer (the bare return arm, substitutionRecv,
        // element typing) then sees the call-site instantiation for every
        // fn type parameter, argument-bound ones included. Registry-stable
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

    // `lowerMemberExtensionDispatchReceiver` and `lowerReceiver` can lower
    // lambda bodies, which appends to the module's function table and moves
    // it — `target` points into that table and must not be read after them.
    const target_is_member_extension = target.kind == .member_extension;
    const dispatch_reg: ?Reg = if (target_is_member_extension)
        (try lowerMemberExtensionDispatchReceiver(
            b,
            resolution.dispatch_owner orelse return null,
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
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv_reg,
            .name = method_name,
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
            .trailing_lambda = b.callTrailingLambda(),
            .declared_recv = declared_recv,
            .resolved = func_id,
            .dispatch_receiver = dispatch_reg,
        } });
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
    return dst;
}

/// Whether the immediately preceding member resolution statically refuted
/// every candidate (consumed by the extension leg that runs next, so a
/// sole receiver-proven extension can commit).
threadlocal var last_member_refuted: bool = false;

fn resolveExtensionCallForArgs(
    b: *FuncBuilder,
    recv_ty: TypeRef,
    name: ast.Ident,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
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

fn staticReceiverHasNoCompetingCallable(
    b: *FuncBuilder,
    receiver_ty: ?TypeRef,
    name: []const u8,
    argc: usize,
) bool {
    const ty = receiver_ty orelse return false;
    const head = typeHead(ty.name);
    const hierarchy = b.module.registry.hierarchy_shadow_names.get(head) orelse return false;
    if (!hierarchy.complete or hierarchy.names.contains(name)) return false;
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
    // An ALIAS head (`Ints = MutableList<Int>`) names no class, so without
    // resolution it fell into the unresolvable-type-parameter escape below
    // and the overload applied to a receiver its real type refutes. Resolve
    // the alias the same way global extension resolution does.
    var alias_arena = std.heap.ArenaAllocator.init(b.allocator);
    defer alias_arena.deinit();
    const actual_scoped = b.module.resolveTypeAliasAt(
        alias_arena.allocator(),
        raw_actual,
        null,
        b.self_package,
    ) catch raw_actual;
    const actual = actual_scoped;
    // An actual head that names NO known classifier and carries no bound
    // here is a type parameter of a spliced/generic context (`it: T` inside
    // `compareBy`'s SAM lambda, where T instantiates to the caller's
    // element type) — statically unresolvable, so it must not DISPROVE the
    // overload; the runtime receiver decides.
    {
        const head = typeHead(actual.name);
        // A derived `Any` head is the deriver's own erasure product (a
        // generic return the channel could not instantiate), not a proof
        // the receiver is unrelated: dropping the local extension on it
        // emitted a member walk that misses at runtime. The runtime
        // receiver arbitrates instead.
        if (std.mem.eql(u8, head, "Any")) return true;
        var bound_known = false;
        for (actual_bounds) |tb| {
            if (std.mem.eql(u8, tb.param, head)) bound_known = true;
        }
        // Builtin heads (`Nothing?`, primitives, `Any`, `String`, ...) are
        // known classifiers even without a module class entry — they keep
        // the full subtype judgment (a `Nothing?` actual must still refute
        // a `String` receiver).
        const builtin_head = isPrimitiveTypeName(head) or
            std.mem.eql(u8, head, "Nothing") or std.mem.eql(u8, head, "Any") or
            std.mem.eql(u8, head, "Unit") or std.mem.eql(u8, head, "String") or
            std.mem.eql(u8, head, "CharSequence");
        if (!builtin_head and !bound_known and b.module.classId(head) == null and
            b.module.registry.class_super_names.get(head) == null)
        {
            return true;
        }
        // The same reasoning one level down: a type ARGUMENT that names no
        // classifier and no in-scope parameter is an uninstantiated class
        // parameter (`this.followedBy` inside `ParserStructure<in Output>`
        // types as `ParserStructure<Output>`), which the invariance check
        // then reads as a nominal mismatch against `ParserStructure<T>`.
        // A REAL caller parameter is bound-known here and keeps refuting.
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

pub fn lowerMemberCallFallback(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const receiver = callee.Member.receiver;
    const name = callee.Member.name;
    // `BytesHexFormat.Builder()` — a class-named receiver whose member names
    // a NESTED CONSTRUCTIBLE CLASS is a constructor call. Emit the
    // statically bound NewInstance the bare form gets (the same resolution
    // the derivation arm and the runtime walk's nested-construction tail
    // perform), instead of a member walk on the companion value.
    if (receiver.* == .Path and receiver.Path.segments.len >= 1 and receiver.Path.segments.len <= 3) {
        const outer_name = receiver.Path.segments[0].name;
        // Every path segment must look like a classifier reference
        // (`TimeSource.Monotonic.ValueTimeMark(reading)` — three segments).
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
    const declared_from_expr = argDeclTypeRef(b, receiver);
    // The FULL static deriver, not just the call-return channel: a BINARY
    // receiver (`(a * bitsPerSymbol) / bitsPerByte).toInt()`) types by the
    // numeric-promotion arm, a bare companion-const read by the Path arm —
    // channels the emission never consulted while the derivation side did,
    // which is the two-channel trap recorded twice already.
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
    // A unique static declaration commits here as either an exact function or
    // a virtual slot; only ambiguous/incomplete receiver shapes continue below.
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
    const member_shadows_extensions = static_member == .deferred;

    // A bound local/param/captured-outer of this name shadows the member.
    // A plain bound local (`for (module in modules) { application.module() }`,
    // a `T.() -> R` value invoked with receiver syntax) is included too: the
    // member is still tried first at runtime, with the local as the fallback.
    const anon_cap = isLowerAnonCapture(name.name) and b.resolve(name.name) == null and
        !b.isLocalFn(name.name) and !b.isParam(name.name) and !b.knowsOuter(name.name);
    // A parameter whose declared type is a function type with NO receiver can
    // never serve an EXPLICIT-receiver call. Kotlin resolves `recv.name(args)` to
    // a member or extension of `recv`; a local competes only when its type is an
    // EXTENSION-function type (`Modifier.() -> Unit`, which is why `up.update()`
    // binds a `Up.() -> Unit` param). A plain `(FocusState) -> Unit` is not that —
    // and treating it as a candidate made `.onFocusChanged(onFocusChanged)` inside
    // `textFieldFocusModifier` INVOKE the callback with itself as its argument
    // instead of dispatching `Modifier.onFocusChanged`, recursing until the native
    // stack blew (every `BasicTextField`).
    const plain_fn_local = b.isPlainFnParam(name.name);
    const local_receiver_applicable = !b.isLocalExtFn(name.name) or
        try localExtensionReceiverCouldApply(b, name.name, declared_ty);
    const local_callable = !plain_fn_local and local_receiver_applicable and
        (b.isLocalFn(name.name) or b.isParam(name.name) or
            b.knowsOuter(name.name) or anon_cap or b.resolve(name.name) != null);
    if (local_callable) {
        // Same-named local siblings share the plain-name slot, which for a
        // multi-declaration name may hold a non-extension sibling or the
        // boxed self-cell's placeholder. A receiver-full call binds only an
        // EXTENSION sibling, so select it by signature and call through its
        // mangled cell — the plain slot misbound `this.Test(showThree)` to
        // an uninitialized cell whenever composable and extension `Test`
        // overloads coexisted.
        // The DIRECT local-ext commitment needs a derived receiver: with the
        // receiver untyped, a same-named global extension may be the Kotlin
        // target (the test-local `String?.contentEquals` recursed into
        // itself over the stdlib `CharSequence?.contentEquals`), so the
        // arbitrated emission below decides at run time instead.
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
            // A directly-bound local (a loop variable / `val`) uses its own
            // register; `resolveCapture` would mint a bogus capture slot
            // (resolving to `Nothing`) for a name that is not actually
            // closed over.
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
        // A receiver whose static type is an unbounded type parameter declares
        // no members, so the runtime class must not be consulted at all: the
        // in-scope callable is the only candidate Kotlin ever had.
        const recv_erased = receiver.* == .Path and
            receiver.Path.segments.len == 1 and
            (b.isErasedRecvParam(receiver.Path.segments[0].name) or
                enclosingPropertyBareTp(b, receiver.Path.segments[0].name));
        const callable_takes_receiver = b.isReceiverLambdaParam(name.name) or
            b.isLocalExtFn(name.name) or b.localDeclRecvFn(name.name);
        const callable_shape_known = callable_takes_receiver or
            (b.isLocalFn(name.name) and !b.isLocalExtFn(name.name));
        if (callable_takes_receiver and
            (recv_erased or staticReceiverHasNoCompetingCallable(b, declared_ty, name.name, args.len)))
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

    // `super.method(...)`.
    if (receiver.* == .Super) {
        const sup = receiver.Super;
        if (try superBase(b, sup)) |base| {
            const run = try lowerArgRun(b, args);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
            const oc = try b.module.internConst(b.allocator, .{ .String = base.owner });
            const qual_const = try superQualifier(b, sup.qualifier);
            try b.push(.{ .CallSuper = .{
                .dst = dst,
                .receiver = base.this_reg,
                .owner_class = oc,
                .qualifier = qual_const,
                .name = nm,
                .args = run[0],
                .n_args = run[1],
                .arg_names = arg_names,
            } });
            return dst;
        }
    }

    // The Compose syntax pass may conservatively thread a same-named call
    // before overload resolution. Re-resolve the explicit receiver against
    // its source argument list; a source-shaped member or extension proves
    // that the selected declaration is not composable, so the compiler ABI
    // pair does not belong to this call.
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
            );
            if (source_extension.target) |target_id| {
                if (b.module.funcById(target_id)) |target| {
                    if (!selectedCallHasComposerAbi(b.module, target_id, target)) {
                        var rewritten = expr.*;
                        rewritten.Call.args = source_args;
                        rewritten.Call.arg_names = source_names;
                        return lowerMemberCallFallback(b, &rewritten);
                    }
                }
            } else if (source_extension.applicable and
                !source_extension.compiler_abi_applicable)
            {
                var rewritten = expr.*;
                rewritten.Call.args = source_args;
                rewritten.Call.arg_names = source_names;
                return lowerMemberCallFallback(b, &rewritten);
            }
        }
    }

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
        )) |reg| return reg;
    }

    const recv = try lowerReceiver(b, receiver);
    // A class-named receiver (`Snapshot.withMutableSnapshot { … }`, or an
    // explicit `.Companion`) resolves its member's declared signature
    // statically through the lifted companion / class method registry, so
    // each lambda argument learns its expected value arity — a `() -> R`
    // block then drops its parser-injected `it` and an `it` inside
    // captures the enclosing lambda's, instead of binding a spurious null
    // parameter.
    const uarg_arity: ?[]const i16 = try memberCallArgArities(b, receiver, name.name, args, ast_arg_names);
    // The dispatch stays deferred (a runtime subtype might serve the name
    // as a MEMBER), but kotlinc types the argument lambdas against the
    // STATIC declared-type resolution — which, with no member on the
    // static type, is the extension candidate. Thread its instantiated
    // param types so the closure bodies type their params.
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
        const ext = try resolveExtensionCallForArgs(b, recv_ty, name, args, ast_arg_names);
        // Typing-only consumer: the withheld strict-key winner's param
        // types are as good as a committed target's for the closures, and
        // so are a TIED set's when every candidate declares the same
        // parameter list up to function-return positions (`flatMapIndexed`
        // overloads on the lambda's return alone).
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
    // Kotlin resolves the member-vs-extension question against the
    // receiver's DECLARED type; carry it for the extension-selection
    // filter (a channel separate from static_recv, whose meaning is the
    // extension-body receiver). A nullable declared receiver carries its
    // HEAD too: null-accepting extensions overload by the underlying
    // type (`String?.orEmpty()` vs `List?.orEmpty()`), and a Null
    // runtime receiver offers the filter nothing else to go on.
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
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .trailing_lambda = b.callTrailingLambda(),
        .args = run[0],
        .n_args = run[1],
        .arg_names = arg_names,
        .declared_recv = declared_recv,
    } });
    return dst;
}
