//! Call lowering: the entry ladder, spread and vararg packing, inline expansion.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const inline_state = @import("../inline_state.zig");
const decl_mod = @import("../decl.zig");
const inline_call = @import("../inline_call.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const SpreadPart = ir.SpreadPart;
const lowerArgRun = helpers.lowerArgRun;
const lowerArgRunWithArity = helpers.lowerArgRunWithArity;
const internArgNames = helpers.internArgNames;
const exprSpan = helpers.exprSpan;
const inlineFnAst = inline_state.inlineFnAst;
const CallShape = inline_state.CallShape;
const isLowerAnonCapture = decl_mod.isLowerAnonCapture;
const spliceInlineLambda = inline_call.spliceInlineLambda;
const tryInlineCallWithTypeArgs = inline_call.tryInlineCallWithTypeArgs;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const receiver_mod = @import("receiver.zig");
const lowerReceiver = receiver_mod.lowerReceiver;
const resolveThisRegKind = receiver_mod.resolveThisRegKind;

const binary_mod = @import("binary.zig");
const scalarBitBinOp = binary_mod.scalarBitBinOp;

const paths_mod = @import("paths.zig");
const importCompanionRewrite = paths_mod.importCompanionRewrite;
const ownMemberRejectsLambdas = paths_mod.ownMemberRejectsLambdas;
const scopeTypeRename = paths_mod.scopeTypeRename;

const lambda_mod = @import("lambda.zig");
const argFnArities = lambda_mod.argFnArities;
const callBoundLambdaReceiverType = lambda_mod.callBoundLambdaReceiverType;
const fnTypeReceiver = lambda_mod.fnTypeReceiver;
const recordLambdaArgReceivers = lambda_mod.recordLambdaArgReceivers;
const reifiedNeedsLambdaArity = lambda_mod.reifiedNeedsLambdaArity;

const compose_mod = @import("compose.zig");
const SelectedCallArgs = compose_mod.SelectedCallArgs;
const selectedCallArgsForBuilder = compose_mod.selectedCallArgsForBuilder;

const emit_mod = @import("emit.zig");
const cmgCandidates = emit_mod.cmgCandidates;
const emitTailJumpRun = emit_mod.emitTailJumpRun;

const call_general_mod = @import("call_general.zig");
const classIsOrExtendsHosted = call_general_mod.classIsOrExtendsHosted;
const inlineOwnerInEnclosingHierarchy = call_general_mod.inlineOwnerInEnclosingHierarchy;
const lowerCallGeneral = call_general_mod.lowerCallGeneral;
const memberOwnerOnReceiverChain = call_general_mod.memberOwnerOnReceiverChain;
const memberOwnerOnReceiverChainStrict = call_general_mod.memberOwnerOnReceiverChainStrict;
const storeExplicitReifiedGlobals = call_general_mod.storeExplicitReifiedGlobals;

const inline_target_mod = @import("inline_target.zig");
const anyCrossOrNoinlineParam = inline_target_mod.anyCrossOrNoinlineParam;
const bareInlineNeedsSplice = inline_target_mod.bareInlineNeedsSplice;
const bareInlineNeedsSpliceT = inline_target_mod.bareInlineNeedsSpliceT;
const inlineEvidenceRejects = inline_target_mod.inlineEvidenceRejects;
const inlineTargetForBareCall = inline_target_mod.inlineTargetForBareCall;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;

const static_type_mod = @import("static_type.zig");
const ownedClassSelfType = static_type_mod.ownedClassSelfType;
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const type_probe_mod = @import("type_probe.zig");
const buildStaticArgShapes = type_probe_mod.buildStaticArgShapes;
const disambiguateByReceiver = type_probe_mod.disambiguateByReceiver;
const extOnEnclosingReceiverApplies = type_probe_mod.extOnEnclosingReceiverApplies;
const lowerDelegateRead = type_probe_mod.lowerDelegateRead;
const shadowedByClass = type_probe_mod.shadowedByClass;

const probe_mod = @import("probe.zig");
const implicitReceiverOfType = probe_mod.implicitReceiverOfType;
const memberCallArgArities = probe_mod.memberCallArgArities;
const receiverMemberIsReifiedInline = probe_mod.receiverMemberIsReifiedInline;
const receiverStaticMemberApplies = probe_mod.receiverStaticMemberApplies;
const reifiedNamesFromExpected = probe_mod.reifiedNamesFromExpected;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const orEmitAudit = audit_mod.orEmitAudit;

const expected_mod = @import("expected.zig");
const solveSiblingExpected = expected_mod.solveSiblingExpected;

const member_call_mod = @import("member_call.zig");
const lowerResolvedMemberCall = member_call_mod.lowerResolvedMemberCall;

const block_mod = @import("block.zig");
const lowerBlock = block_mod.lowerBlock;


pub fn lastArgIsLambda(args: []const Expr) bool {
    if (args.len == 0) return false;
    return args[args.len - 1] == .Lambda;
}

/// Last `.`-separated segment of a (possibly qualified) type name.
fn lastTypeSegment(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Whether any inline candidate for `name` declares a reified type parameter.
/// Such a call can only splice, so no dispatch-deferring arm may claim it.
pub fn nameHasReifiedInlineCandidate(name: []const u8) bool {
    const cands = inline_state.candidatesForName(name) orelse return false;
    for (cands) |cf| {
        for (cf.type_params) |tp| {
            if (tp.is_reified) return true;
        }
    }
    return false;
}

pub fn nameHasReceiverCandidate(b: *FuncBuilder, name: []const u8, chain: ?[]const []const u8) bool {
    for (b.module.funcsBySimpleName(name)) |fid| {
        const idx = fid.int();
        const f = b.module.funcById(FuncId.from(idx)) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const recv_ty = lastTypeSegment(f.params[0].ty.name);
        const ch = chain orelse return true;
        for (ch) |c| {
            if (std.mem.eql(u8, lastTypeSegment(c), recv_ty)) return true;
        }
    }
    return false;
}

pub fn lastArgIsLambdaOrAnon(args: []const Expr) bool {
    if (args.len == 0) return false;
    const last = args[args.len - 1];
    return last == .Lambda or last == .AnonFun;
}

/// Declared parameter arity of a trailing lambda or anon-fun argument, null
/// when the last argument is neither. A zero-`->` `{ … }` reports 0.
fn trailingLambdaArity(args: []const Expr) ?usize {
    if (args.len == 0) return null;
    return switch (args[args.len - 1]) {
        .Lambda => |l| if (l.implicit_it) 0 else l.params.len,
        .AnonFun => |af| af.params.len,
        else => null,
    };
}

/// The local's declared type is never invokable: a primitive, String, Unit, or
/// a class whose complete hierarchy record declares no `invoke`.
pub fn localValueNotInvokable(b: *FuncBuilder, name: []const u8) bool {
    const t = b.localDeclTypeRef(name) orelse return false;
    if (std.mem.startsWith(u8, t.name, "Function") or std.mem.startsWith(u8, t.name, "kotlin.Function")) return false;
    var head = std.mem.trimEnd(u8, t.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (std.mem.startsWith(u8, head, "kotlin.")) head = head["kotlin.".len..];
    const plain = [_][]const u8{ "Int", "Long", "Short", "Byte", "Double", "Float", "Boolean", "Char", "String", "Unit", "UInt", "ULong", "UShort", "UByte" };
    for (plain) |p| {
        if (std.mem.eql(u8, head, p)) return true;
    }
    if (head.len <= 2 and head.len != 0 and std.ascii.isUpper(head[0])) return false;
    if (std.mem.eql(u8, head, "Any") or std.mem.eql(u8, head, "Nothing")) return false;
    const hs = b.module.registry.hierarchy_shadow_names.get(head) orelse return false;
    if (!hs.complete) return false;
    return !hs.names.contains("invoke");
}

/// The receiver's statically known class resolves a unique member named `name`
/// that binds these arguments.
fn receiverConcreteMemberTakes(b: *FuncBuilder, receiver: *const Expr, name: []const u8, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!bool {
    const head = (try inline_call.gateReceiverHead(b, receiver)) orelse {
        if (runtime.envOnce("KLIO_INLINE_PICK")) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[rcmt] {s} no receiver head (recv tag={s})\n", .{ name, @tagName(std.meta.activeTag(receiver.*)) });
        }
        return false;
    };
    var h = std.mem.trimEnd(u8, head, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    const file = exprSpan(receiver).file;
    const cid = b.module.classIdIndexed(h, b.self_package, file) orelse b.module.classId(h) orelse return false;
    if (cid.int() >= b.module.classes.items.len) return false;
    const shapes = try buildStaticArgShapes(b, args, arg_names);
    defer b.allocator.free(shapes);
    const owned_bounds = try b.typeParamBoundsSlice();
    defer if (owned_bounds) |bounds| b.allocator.free(bounds);
    var recv_type = try ownedClassSelfType(b.allocator, &b.module.classes.items[cid.int()]);
    defer recv_type.deinit(b.allocator);
    const res = b.module.resolveMemberCall(cid, name, shapes, .{
        .caller_file = file,
        .lexical_owner = cid,
        .actual_type_param_bounds = owned_bounds orelse &.{},
        .receiver_type = recv_type,
    });
    if (runtime.envOnce("KLIO_INLINE_PICK")) |w| {
        if (std.mem.eql(u8, w, name)) {
            std.debug.print("[rcmt] {s} head={s} target={?d} shapes:", .{ name, h, if (res.target) |t| t.int() else null });
            for (shapes) |sh| std.debug.print(" {s}", .{if (sh.ty) |t| t.name else "?"});
            std.debug.print("\n", .{});
        }
    }
    // An applicable member shadows every same-named extension even when the
    // overload set stays ambiguous for the known argument shapes.
    return res.target != null or res.applicable;
}

pub fn lowerCall(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const call_tail = b.call_tail;
    // `c.TA(args)` where `TA` aliases a nested or inner class of `c`'s class
    // constructs the aliased class, which the inner-constructor route serves.
    if (expr.Call.callee.* == .Member and !expr.Call.callee.Member.safe) {
        const mn = expr.Call.callee.Member.name.name;
        if (b.module.registry.type_alias_types.get(mn)) |shape| {
            const target = shape.target.name;
            const simple = if (std.mem.findScalarLast(u8, target, '.')) |dot| target[dot + 1 ..] else target;
            const fn_alias = if (b.module.registry.type_aliases.get(mn)) |tag| std.mem.startsWith(u8, tag, "Function") else false;
            // Only an alias onto a nested class, and never one whose target is
            // itself an alias: a rewrite chain would loop.
            const nested_target = blk: {
                if (b.module.registry.type_alias_types.contains(simple)) break :blk false;
                const cid = b.module.classIdIndexed(simple, b.self_package, expr.Call.callee.Member.name.span.file) orelse break :blk false;
                if (cid.int() >= b.module.classes.items.len) break :blk false;
                break :blk std.mem.findScalar(u8, b.module.classes.items[cid.int()].fqn, '.') != null;
            };
            if (!std.mem.eql(u8, simple, mn) and !fn_alias and nested_target) {
                const callee_copy = try b.allocator.create(Expr);
                callee_copy.* = expr.Call.callee.*;
                callee_copy.Member.name = .{ .name = simple, .span = expr.Call.callee.Member.name.span };
                var rewritten = expr.*;
                rewritten.Call.callee = callee_copy;
                return lowerCall(b, &rewritten);
            }
        }
    }
    // A bare call of a delegated local invokes the value the delegate's
    // `getValue` yields, never the delegate object bound under the plain name.
    if (expr.Call.callee.* == .Path and expr.Call.callee.Path.segments.len == 1 and expr.Call.type_args.len == 0) {
        const dn = expr.Call.callee.Path.segments[0].name;
        if (b.resolve(dn) != null or b.knowsOuter(dn) or isLowerAnonCapture(dn) or build.anonCaptureBinds(dn)) {
            if (try lowerDelegateRead(b, dn)) |delegate_value| {
                const run = try lowerArgRun(b, expr.Call.args);
                const arg_names = try internArgNames(b.allocator, b.module, expr.Call.arg_names);
                const dst = b.allocReg();
                try b.push(.{ .CallValue = .{
                    .dst = dst,
                    .callee = delegate_value,
                    .args = run[0],
                    .n_args = run[1],
                    .arg_names = arg_names,
                } });
                return dst;
            }
        }
    }
    // Saved and restored across nested calls.
    const prev_tail_ok = b.tail_call_ok;
    b.tail_call_ok = call_tail;
    defer b.tail_call_ok = prev_tail_ok;
    // A sibling argument bound to the same declared type variable can name an
    // enum statically, solving a nested reified call's expected type.
    const sib_prev_site = b.sib_expected_site;
    const sib_prev_ty = b.sib_expected_ty;
    if (solveSiblingExpected(b, expr.Call.callee, expr.Call.args)) |solved| {
        b.sib_expected_site = @ptrCast(solved.site);
        b.sib_expected_ty = solved.ty;
        if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null)
            std.debug.print("[sibexp] solved ty={s} site={x}\n", .{ solved.ty.name.name, @intFromPtr(solved.site) & 0xffff });
    } else if (runtime.envOnce("KLIO_SIBEXP_TRACE") != null and expr.Call.args.len >= 2) {
        const cn: []const u8 = switch (expr.Call.callee.*) {
            .Path => |p| p.segments[p.segments.len - 1].name,
            .Member => |m| m.name.name,
            else => "?",
        };
        std.debug.print("[sibexp] none for `{s}` with {d} args\n", .{ cn, expr.Call.args.len });
    }
    defer {
        b.sib_expected_site = sib_prev_site;
        b.sib_expected_ty = sib_prev_ty;
    }
    const call = expr.Call;
    const prev_trailing = b.setCallTrailingLambda(call.has_trailing_lambda);
    defer _ = b.setCallTrailingLambda(prev_trailing);
    // `dep!!()` calls the value the bare name holds, so unwrap the assertion at
    // the callee to keep the bare-name machinery. A null still fails at invoke.
    const callee = blk: {
        var c = call.callee;
        while (c.* == .Postfix and c.Postfix.op == .NotNull and
            (c.Postfix.expr.* == .Path or c.Postfix.expr.* == .Member))
        {
            c = c.Postfix.expr;
        }
        break :blk c;
    };
    const prev_call_label = b.current_call_label;
    b.current_call_label = helpers.calleeLabel(callee);
    defer b.current_call_label = prev_call_label;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    const is_infix = call.is_infix;
    // Scalar bitwise infix on Int/Long (Bool for the logical trio) are Int
    // members with intrinsic semantics, so emit the BinOp. Members outrank
    // extensions on these final receivers, so no user code is shadowed.
    if (is_infix and args.len == 2 and callee.* == .Path and
        callee.Path.segments.len == 1 and ast_type_args.len == 0)
    {
        // An infix self-call in tail position is a jump; the written receiver
        // is the leading `this` parameter.
        if (call_tail) if (b.tailrecSelf()) |ts| if (std.mem.eql(u8, ts, callee.Path.segments[0].name)) {
            if (try emitTailJumpRun(b, null, args, expr.Call.arg_names)) |run| {
                b.terminate(.{ .TailJump = .{ .args = run[0], .n_args = @intCast(run[1].int()) } });
                const dead = try b.allocBlock();
                b.switchTo(dead);
                return b.emitConst(.Unit);
            }
        };
        if (scalarBitBinOp(callee.Path.segments[0].name)) |op| blk: {
            var lt = (try staticExprTypeRef(b, &args[0])) orelse break :blk;
            defer lt.deinit(b.allocator);
            var rt = (try staticExprTypeRef(b, &args[1])) orelse break :blk;
            defer rt.deinit(b.allocator);
            if (lt.nullable or rt.nullable) break :blk;
            const shift = op == .Shl or op == .Shr or op == .UShr;
            const ok_types = if (shift)
                ((std.mem.eql(u8, lt.name, "Int") or std.mem.eql(u8, lt.name, "Long")) and
                    std.mem.eql(u8, rt.name, "Int"))
            else
                ((std.mem.eql(u8, lt.name, "Int") and std.mem.eql(u8, rt.name, "Int")) or
                    (std.mem.eql(u8, lt.name, "Long") and std.mem.eql(u8, rt.name, "Long")) or
                    (op != .Xor and std.mem.eql(u8, lt.name, "Bool") and std.mem.eql(u8, rt.name, "Bool")) or
                    (op == .Xor and std.mem.eql(u8, lt.name, "Bool") and std.mem.eql(u8, rt.name, "Bool")));
            if (!ok_types) break :blk;
            const lr = try lowerExpr(b, &args[0]);
            const rr = try lowerExpr(b, &args[1]);
            const dst = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = dst, .op = op, .lhs = lr, .rhs = rr } });
            return dst;
        }
    }
    // Record each lambda argument's expected value-parameter arity by span
    // before the args lower; `lowerLambda` reads it authoritatively, so a
    // receiver lambda drops its `it` on every emit branch.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const cnm = callee.Path.segments[0].name;
    // A bare call to an own member resolves to the member, which is absent from
    // `func_name_index`. The registered member AST, keyed by (owner, name,
    // arity), is the signature source; positional args only.
        if (b.ownerClass() != null and b.hasOwnMember(cnm)) {
            var any_named = false;
            for (ast_arg_names) |n| {
                if (n != null) any_named = true;
            }
            if (!any_named) {
                if (inline_state.exprBodyMemberAst(b.ownerClass().?, cnm, args.len)) |mf| {
                    for (args, 0..) |*a, i| {
                        if (a.* != .Lambda and a.* != .AnonFun) continue;
                        if (i >= mf.params.len) continue;
                        const pt = &mf.params[i].ty;
                        if (pt.function) |ft| {
                            b.recordLambdaArgArity(a.span(), @intCast(ft.params.len));
                        }
                    }
                }
            }
        }
        // Only for an unambiguous callee name. With overloads `funcId` is a
        // heuristic that may name the wrong one and drop a needed `it`.
        const unambiguous = if (b.module.func_name_index.get(cnm)) |ids| ids.items.len == 1 else false;
        // An applicable own member shadows the same-named top-level function in
        // Kotlin's scope order, so its lambda shapes come from the member.
        const own_shadows = b.ownerClass() != null and b.resolve("this") != null and
            b.hasOwnMember(cnm) and b.ownFunctionApplicable(cnm, args.len) and
            !ownMemberRejectsLambdas(b, cnm, args);
        const chosen: ?FuncId = if (own_shadows)
            null
        else if (unambiguous)
            b.module.funcId(cnm)
        else
            // Ambiguous name: disambiguate by the enclosing receiver type so a
            // receiver-lambda argument's arity (0) is still recorded.
            disambiguateByReceiver(b, cnm);
        if (chosen) |fid| {
            if (b.module.funcById(fid)) |f| {
                const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
                const arr = try argFnArities(b, f, args, ast_arg_names, recv_off);
                if (arr) |ar| {
                    defer b.allocator.free(ar);
                    for (args, 0..) |*a, i| {
                        if ((a.* == .Lambda or a.* == .AnonFun) and i < ar.len and ar[i] >= 0) {
                            b.recordLambdaArgArity(a.span(), ar[i]);
                        }
                    }
                }
                try recordLambdaArgReceivers(b, f, args, ast_arg_names, ast_type_args, recv_off);
            }
        } else if (args.len != 0 and (args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun)) {
            // Ambiguous with no receiver disambiguation: a receiver head common
            // to every overload's trailing fn-typed parameter is safe to record.
            if (b.module.func_name_index.get(cnm)) |ids| {
                var common: ?ir.TypeRef = null;
                defer if (common) |receiver| {
                    var cleanup = receiver;
                    cleanup.deinit(b.allocator);
                };
                var ok = ids.items.len >= 2;
                for (ids.items) |fid2| {
                    const f2 = b.module.funcById(fid2) orelse {
                        ok = false;
                        break;
                    };
                    if (f2.params.len == 0) {
                        ok = false;
                        break;
                    }
                    const declared_receiver = fnTypeReceiver(b, f2.params[f2.params.len - 1].ty) orelse {
                        ok = false;
                        break;
                    };
                    const recv_off: usize = if (std.mem.eql(u8, f2.params[0].name, "this")) 1 else 0;
                    var bound_receiver = try callBoundLambdaReceiverType(
                        b,
                        f2,
                        declared_receiver,
                        f2.params[recv_off..],
                        args,
                        ast_arg_names,
                        ast_type_args,
                        null,
                    );
                    if (common) |c0| {
                        if (!c0.eql(bound_receiver)) {
                            bound_receiver.deinit(b.allocator);
                            ok = false;
                            break;
                        }
                        bound_receiver.deinit(b.allocator);
                    } else common = bound_receiver;
                }
                if (ok) {
                    if (common) |receiver| {
                        common = null;
                        if (std.c.getenv("KLIO_LAR_TRACE") != null)
                            std.debug.print("[lar-site] site=common name={s} recv={s} s={d}..{d}\n", .{ cnm, receiver.name, args[args.len - 1].span().start, args[args.len - 1].span().end });
                        try b.recordLambdaArgRecvOwned(args[args.len - 1].span(), receiver);
                    }
                }
            }
        }
    }

    // `context(v..., block)` and `contextOf<T>()` lower to context-stack ops, so
    // implicit resolution is driven by the runtime stack. Only when unshadowed.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1) {
        const cname = callee.Path.segments[0].name;
        if (b.resolve(cname) == null and !b.knowsOuter(cname)) {
            if (std.mem.eql(u8, cname, "contextOf") and args.len == 0 and ast_type_args.len == 1) {
                b.module.has_context_decls = true;
                const dst = b.allocReg();
                const ty_const = try b.module.internConst(b.allocator, .{ .String = ast_type_args[0].name.name });
                try b.push(.{ .CtxLoad = .{ .dst = dst, .ty = ty_const, .erased = false } });
                return dst;
            }
            if (std.mem.eql(u8, cname, "context") and args.len >= 2 and lastArgIsLambda(args)) {
                b.module.has_context_decls = true;
                const run = try lowerArgRun(b, args);
                const n_ctx: u32 = @intCast(args.len - 1);
                const block_reg = Reg.from(run[0].int() + n_ctx);
                const dst = b.allocReg();
                try b.push(.{ .CtxScope = .{
                    .dst = dst,
                    .ctx_args = run[0],
                    .n_ctx = n_ctx,
                    .block = block_reg,
                } });
                return dst;
            }
        }
    }

    // Fully-positional call of a contextual function-type value: when the arg
    // count matches the flattened `n_ctx + n_regular`, split the leading context
    // args onto the context stack; the implicit form falls to the value path.
    if (!is_infix and callee.* == .Path and callee.Path.segments.len == 1 and ast_type_args.len == 0) {
        const cname = callee.Path.segments[0].name;
        if (b.contextFnParam(cname)) |shape| {
            const positional = args.len == shape.n_ctx + shape.n_regular and !lastArgIsLambda(args);
            const implicit = shape.n_ctx != 0 and args.len == shape.n_regular and !lastArgIsLambda(args);
            // The parameter itself, or its capture inside a lambda body.
            const callee_opt: ?Reg = if (!positional and !implicit) null else b.resolve(cname) orelse
                (if (b.knowsOuter(cname)) try b.loadCaptureHoisted(cname) else null);
            if (callee_opt) |callee_reg| {
                if (positional) {
                    b.module.has_context_decls = true;
                    const run = try lowerArgRun(b, args);
                    const dst = b.allocReg();
                    try b.push(.{ .CtxCall = .{
                        .dst = dst,
                        .callee = callee_reg,
                        .args = run[0],
                        .n_args = run[1],
                        .n_ctx = @intCast(shape.n_ctx),
                    } });
                    return dst;
                }
                // Implicit form: each context argument is the innermost implicit
                // receiver of that type in scope, else the runtime context stack.
                if (implicit) {
                    b.module.has_context_decls = true;
                    const total = shape.n_ctx + shape.n_regular;
                    const first = b.allocReg();
                    var k: usize = 1;
                    while (k < total) : (k += 1) _ = b.allocReg();
                    for (shape.ctx_types, 0..) |ty, ci| {
                        const slot = Reg.from(first.int() + @as(u32, @intCast(ci)));
                        if (try implicitReceiverOfType(b, ty)) |r| {
                            try b.push(.{ .Move = .{ .dst = slot, .src = r } });
                        } else {
                            const ty_const = try b.module.internConst(b.allocator, .{ .String = ty });
                            try b.push(.{ .CtxLoad = .{ .dst = slot, .ty = ty_const, .erased = false } });
                        }
                    }
                    for (args, 0..) |*arg, ai| {
                        const slot = Reg.from(first.int() + @as(u32, @intCast(shape.n_ctx + ai)));
                        const v = try lowerExpr(b, arg);
                        try b.push(.{ .Move = .{ .dst = slot, .src = v } });
                    }
                    const dst = b.allocReg();
                    try b.push(.{ .CtxCall = .{
                        .dst = dst,
                        .callee = callee_reg,
                        .args = first,
                        .n_args = @intCast(total),
                        .n_ctx = @intCast(shape.n_ctx),
                    } });
                    return dst;
                }
            }
        }
    }

    // A bare head naming a mangled nested class or a renamed file-private
    // class/typealias resolves to the lift name; locals and own members shadow it.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const head = callee.Path.segments[0];
        if (scopeTypeRename(b, head.name, head.span.file.int())) |renamed| {
            if (b.resolve(head.name) == null and !b.knowsOuter(head.name)) {
                var new_segs = [_]ast.Ident{.{ .name = renamed, .span = head.span }};
                var new_callee = Expr{ .Path = .{ .segments = &new_segs, .span = callee.Path.span } };
                var rewritten = expr.*;
                rewritten.Call.callee = &new_callee;
                return lowerCall(b, &rewritten);
            }
        }
    }

    // A bare call to a per-file mangled private top-level function resolves to
    // the calling file's name. Locals, outer captures, own members, and an
    // applicable extension on an in-scope implicit receiver all shadow it:
    // Kotlin ranks the implicit-receiver group before any no-receiver candidate.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const head = callee.Path.segments[0];
        if (build.filePrivateFuncRename(head.name, head.span.file.int())) |renamed| {
            if (b.resolve(head.name) == null and !b.knowsOuter(head.name) and !b.hasOwnMember(head.name) and
                !extOnEnclosingReceiverApplies(b, head.name, call.args.len))
            {
                var new_segs = [_]ast.Ident{.{ .name = renamed, .span = head.span }};
                var new_callee = Expr{ .Path = .{ .segments = &new_segs, .span = callee.Path.span } };
                var rewritten = expr.*;
                rewritten.Call.callee = &new_callee;
                return lowerCall(b, &rewritten);
            }
        }
    }

    // A bare call to a name-imported companion member dispatches on the owner's
    // companion, so rewrite the callee to `X.member`; local bindings shadow it.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const head = callee.Path.segments[0];
        if (b.resolve(head.name) == null and !b.knowsOuter(head.name) and !b.hasOwnMember(head.name)) {
            if (importCompanionRewrite(b, head.span.file, head.name)) |rw| {
                const sp = head.span;
                const recv_segs = try b.allocator.alloc(ast.Ident, rw.segs.len - 1);
                for (rw.segs[0 .. rw.segs.len - 1], 0..) |s, k| recv_segs[k] = .{ .name = s, .span = sp };
                var recv = Expr{ .Path = .{ .segments = recv_segs, .span = sp } };
                var new_callee = Expr{ .Member = .{
                    .receiver = &recv,
                    .name = .{ .name = rw.segs[rw.segs.len - 1], .span = sp },
                    .safe = false,
                    .span = callee.Path.span,
                } };
                var rewritten = expr.*;
                rewritten.Call.callee = &new_callee;
                return lowerCall(b, &rewritten);
            }
        }
    }

    // An empty stdlib container creator carries no element head at run time, so
    // pass the tail-position expected type's element or entry heads as type args
    // and let the creation-site path stamp `declared_elem`.
    if (!is_infix and ast_type_args.len == 0 and args.len == 0 and
        callee.* == .Path and callee.Path.segments.len == 1)
    {
        const cname = callee.Path.segments[0].name;
        if (b.resolve(cname) == null and !b.knowsOuter(cname)) {
            const want_heads = emptyContainerCreatorArity(cname);
            if (want_heads != 0) {
                if (b.peekExpected()) |exp| {
                    if (try synthesizeContainerTypeArgs(b, exp, want_heads)) |synth| {
                        var rewritten = expr.*;
                        rewritten.Call.type_args = synth;
                        b.call_tail = call_tail;
                        return lowerCallGeneral(b, &rewritten);
                    }
                }
            }
        }
    }

    // A member call onto an inline `reified` extension. Explicit type args or an
    // expected type let the splice bind the reified parameters.
    if (!is_infix and callee.* == .Member and !callee.Member.safe and gate: {
        if (ast_type_args.len != 0 or b.peekExpected() != null) break :gate true;
        // A trailing-lambda call with a monomorphic member-inline candidate
        // enters regardless of receiver form; the strict pick inside revalidates.
        if (args.len != 0 and switch (args[args.len - 1]) {
            .Lambda, .AnonFun => true,
            else => false,
        }) {
            if (inline_state.candidatesForName(callee.Member.name.name)) |mcands| {
                for (mcands) |mcf| {
                    if (mcf.receiver_type == null and mcf.type_params.len == 0 and
                        inline_state.inlineMemberOwner(mcf) != null) break :gate true;
                }
            }
        }
    // Statement position with no type args: splice when the value arguments alone
    // bind every reified parameter, unless the receiver's static type serves the
    // name, since kotlinc resolves members before extensions.
        if (inline_call.argsBindAllReified(b.allocator, callee.Member.name.name, args, b)) {
            // The receiver's applicable member wins over the inline extensions,
            // unless it is itself reified inline and so bodiless in the image.
            if (try receiverMemberIsReifiedInline(b, callee.Member.receiver, callee.Member.name.name, args.len)) break :gate true;
            break :gate !(try receiverStaticMemberApplies(b, callee.Member.receiver, callee.Member.name.name, args, ast_arg_names, callee.Member.name.span.file));
        }
        const recv = callee.Member.receiver;
        if (recv.* != .Path or recv.Path.segments.len != 1) break :gate false;
        const n = recv.Path.segments[0].name;
        if (b.resolve(n) != null or b.knowsOuter(n)) break :gate false;
        break :gate b.module.registry.companion_singletons.contains(n);
    }) {
        const mname = callee.Member.name.name;
        if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s} cands={d}\n", .{ mname, if (inline_state.candidatesForName(mname)) |c| c.len else 0 });
    // A monomorphic member `inline fun` taking a lambda splices like its reified
    // siblings. The pick is strict: no type parameters, no defaults or varargs,
    // arity matched, callback shape matched, owner on the receiver chain.
        const plain_member_inline: ?*const ast.Function = blk: {
            // `KLIO_MEMBER_INLINE`: "0" disables; a comma list allows only those
            // names; a list starting with '!' allows all but those.
            if (runtime.envOnce("KLIO_MEMBER_INLINE")) |sel| {
                if (std.mem.eql(u8, sel, "0")) break :blk null;
                if (!std.mem.eql(u8, sel, "1")) {
                    var wanted = std.mem.startsWith(u8, sel, "!");
                    var it = std.mem.splitScalar(u8, if (wanted) sel[1..] else sel, ',');
                    const inverted = wanted;
                    wanted = inverted;
                    while (it.next()) |tok| {
                        if (tok.len != 0 and std.mem.eql(u8, tok, mname)) {
                            wanted = !inverted;
                            break;
                        }
                    }
                    if (inverted) {
                        if (!wanted) break :blk null;
                    } else if (!wanted) break :blk null;
                }
            }
            if (ast_type_args.len != 0) break :blk null;
            if (args.len == 0) break :blk null;
            const site_lambda: ?struct { n: usize, implicit: bool } = switch (args[args.len - 1]) {
                .Lambda => |l| .{ .n = l.params.len, .implicit = l.implicit_it },
                .AnonFun => |af| .{ .n = af.params.len, .implicit = false },
                else => null,
            };
            const sl = site_lambda orelse break :blk null;
            const cands = inline_state.candidatesForName(mname) orelse break :blk null;
            var found: ?*const ast.Function = null;
            for (cands) |cf| {
                if (cf.receiver_type != null) continue;
                const owner = inline_state.inlineMemberOwner(cf) orelse continue;
                if (cf.type_params.len != 0) continue;
                // The owner must be monomorphic too: a generic class's member
                // body casts through the class parameter, which a splice leaves
                // reading a stale process-global slot.
                const owner_cid = b.module.uniqueClassIdBySimpleName(owner) orelse
                    b.module.classIdByFqn(owner) orelse continue;
                if (owner_cid.int() >= b.module.classes.items.len) continue;
                if (b.module.classes.items[owner_cid.int()].type_params.len != 0) continue;
                if (cf.params.len != args.len) continue;
                var irregular = false;
                for (cf.params) |*p| {
                    if (p.default != null or p.is_vararg) irregular = true;
                }
                if (irregular) continue;
                // Same-name same-arity member-inline overloads can differ only in
                // callback shape: a receiver lambda matches a parameterless site
                // block, an implicit-`it` block matches arity 0 or 1.
                const decl_fn = cf.params[cf.params.len - 1].ty.function orelse continue;
                const shape_ok = if (decl_fn.receiver != null)
                    (sl.implicit or sl.n == decl_fn.params.len)
                else if (sl.implicit)
                    decl_fn.params.len <= 1
                else
                    sl.n == decl_fn.params.len;
                if (!shape_ok) continue;
                if (cf.body == null) continue;
                if (!try memberOwnerOnReceiverChainStrict(b, callee.Member.receiver, cf)) continue;
                if (found != null) break :blk null;
                found = cf;
            }
            break :blk found;
        };
        const reified_ext = blk: {
            if (inlineFnAst(mname)) |f| {
                if (f.receiver_type != null and anyReified(f.type_params)) break :blk true;
            }
            // A reified member-inline fn is invisible to the top-level stub index
            // and a reified extension can be outranked there, yet both must
            // splice or the reified parameter dies. Type-argumented calls only.
            if (ast_type_args.len != 0) {
                if (inline_state.candidatesForName(mname)) |cands| {
                    for (cands) |cf| {
                        if (anyReified(cf.type_params) and cf.receiver_type != null) break :blk true;
                    }
                }
            }
            if (inline_state.candidatesForName(mname)) |cands| {
                for (cands) |cf| {
                    if (anyReified(cf.type_params) and cf.receiver_type == null and
                        inline_state.inlineMemberOwner(cf) != null)
                    {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };
        if (reified_ext or plain_member_inline != null) {
            const receiver = callee.Member.receiver;
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            // A member-inline overload set is invisible to the stub index, whose
            // receiver-blind shape pick cannot separate the reified overload. The
            // candidate whose type parameters the call can bind wins.
            var member_target: ?*const ast.Function = null;
            if (ast_type_args.len != 0) {
                if (inline_state.candidatesForName(mname)) |cands| {
                    if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm-xn] {s}: cands={d} ptr={x} enc={?s}\n", .{ mname, cands.len, @intFromPtr(cands.ptr), b.ownerClass() orelse build.currentOwnerClass() });
                    for (cands) |cf| {
                        if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm-x] {s}: cand owner={?s} reified={} recv={?s} params={d} args={d} enc={?s}/{?s}\n", .{ mname, inline_state.inlineMemberOwner(cf), anyReified(cf.type_params), if (cf.receiver_type) |rt| rt.name.name else null, cf.params.len, args.len, b.ownerClass(), build.currentOwnerClass() });
                        if (inline_state.inlineMemberOwner(cf) == null) continue;
                        if (!anyReified(cf.type_params)) continue;
                        if (inlineEvidenceRejects(b, cf, args, ast_arg_names)) continue;
                        if (cf.receiver_type) |crt| {
                            // For a reified member extension declared by an
                            // enclosing class, the receiver's static type must
                            // fit its extension receiver and the owner must be
                            // in the enclosing hierarchy.
                            const enclosing = b.ownerClass() orelse build.currentOwnerClass() orelse continue;
                            if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm-x] {s}: inHier={}\n", .{ mname, inlineOwnerInEnclosingHierarchy(b, enclosing, cf) });
                            if (!inlineOwnerInEnclosingHierarchy(b, enclosing, cf)) continue;
                            if (cf.params.len != args.len) continue;
                            // An unknown static head still reaches the splice:
                            // its own receiver gates decide, and a dynamic call
                            // cannot honor the explicit type arguments.
                            if (try inline_call.gateReceiverHead(b, receiver)) |head| {
                                var h = std.mem.trimEnd(u8, head, "?");
                                if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
                                const want = typeHead(std.mem.trimEnd(u8, crt.name.name, "?"));
                                if (!std.mem.eql(u8, typeHead(h), want) and !b.module.classIsOrExtends(typeHead(h), want)) continue;
                            }
                        } else {
                            if (!try memberOwnerOnReceiverChain(b, receiver, cf)) continue;
                            // A member overload that cannot take this many
                            // arguments must not preempt a sibling that can.
                            if (cf.params.len < args.len) continue;
                            var required: usize = 0;
                            for (cf.params) |*cp| {
                                if (cp.default == null and !cp.is_vararg) required += 1;
                            }
                            if (args.len < required) continue;
                        }
                        member_target = cf;
                        break;
                    }
                }
            }
            if (ast_type_args.len == 0) blk_mit: {
                const cands = inline_state.candidatesForName(mname) orelse break :blk_mit;
                if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm-n] {s}: cands={d} enc={?s}\n", .{ mname, cands.len, b.ownerClass() orelse build.currentOwnerClass() });
                // Inference-bound reified member-inline call: dispatch a
                // statically bound typed member call, which binds the reified
                // parameters from the inferred type-argument names.
                for (cands) |cf| {
                    if (!anyReified(cf.type_params)) continue;
                    // Argument evidence refuting the candidate leaves the
                    // receiver's own applicable member to the general path.
                    if (inlineEvidenceRejects(b, cf, args, ast_arg_names)) continue;
                    // The receiver's own applicable member outranks a member
                    // extension declared elsewhere.
                    if (cf.receiver_type != null and try receiverConcreteMemberTakes(b, receiver, mname, args, ast_arg_names)) continue;
                    if (cf.receiver_type) |crt| {
                        // For a reified member extension on the receiver's static
                        // type, the owner must be in the enclosing hierarchy.
                        if (inline_state.inlineMemberOwner(cf) == null) continue;
                        const enclosing = b.ownerClass() orelse build.currentOwnerClass() orelse continue;
                        if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: ext-cand owner={s} enclosing={s} inHier={}\n", .{ mname, inline_state.inlineMemberOwner(cf).?, enclosing, inlineOwnerInEnclosingHierarchy(b, enclosing, cf) });
                        if (!inlineOwnerInEnclosingHierarchy(b, enclosing, cf)) continue;
                        const head = (try inline_call.gateReceiverHead(b, receiver)) orelse continue;
                        var h = std.mem.trimEnd(u8, head, "?");
                        if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
                        const want = typeHead(std.mem.trimEnd(u8, crt.name.name, "?"));
                        if (!std.mem.eql(u8, typeHead(h), want) and !b.module.classIsOrExtends(typeHead(h), want)) continue;
                        if (cf.params.len != args.len) continue;
                    } else {
                        if (inline_state.inlineMemberOwner(cf) == null) continue;
                        if (!try memberOwnerOnReceiverChain(b, receiver, cf)) continue;
                    }
                    const names = inline_call.inferReifiedNamesForCall(b, cf, args, ast_arg_names, callee.Member.name.span.file.int()) orelse
                        (try reifiedNamesFromExpected(b, cf, exp_ptr)) orelse
                    {
                        if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: names=null\n", .{mname});
                        continue;
                    };
                    const fid = blk: {
                        for (b.module.funcsBySimpleName(mname)) |cand_fid| {
                            const ds = b.module.decl_span.get(cand_fid.int()) orelse continue;
                            if (ds.file.int() == cf.name.span.file.int() and ds.start == cf.name.span.start) {
                                if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: fid by span -> {s}\n", .{ mname, if (b.module.funcById(cand_fid)) |cfn| cfn.fqn else "?" });
                                break :blk cand_fid;
                            }
                        }
                        // Instance methods are not in the simple-name index, so
                        // match by declaration span; a user-file method has none,
                        // so identify the overload by its parameter-name sequence
                        // behind the implicit `this`.
                        var fi: u32 = 0;
                        const appended: u32 = @intCast(b.module.appendedFuncCount());
                        const base_n: u32 = @intCast(b.module.func_header_offsets.len);
                        while (fi < appended) : (fi += 1) {
                            const mf = b.module.funcById(FuncId.from(base_n + fi)) orelse continue;
                            if (!std.mem.eql(u8, mf.name, mname)) continue;
                            if (mf.kind != .instance_method) continue;
                            if (mf.params.len != cf.params.len + 1) continue;
                            var all_match = mf.params.len > 0 and std.mem.eql(u8, mf.params[0].name, "this");
                            if (all_match) {
                                for (cf.params, 0..) |*cp, pi| {
                                    if (!std.mem.eql(u8, mf.params[pi + 1].name, cp.name.name)) {
                                        all_match = false;
                                        break;
                                    }
                                }
                            }
                            if (all_match) {
                                if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: fid by param names -> {s}\n", .{ mname, mf.fqn });
                                break :blk mf.id;
                            }
                        }
                        break :blk null;
                    } orelse {
                        // No registered function for the member (a pack's reified
                        // inline member is a header stub), so splice its AST.
                        if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: fid=null -> splice\n", .{mname});
                        inline_call.splice_route_tag = "lowerCall:6578";
                        if (try tryInlineCallWithTypeArgs(b, mname, cf, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| return r;
                        continue;
                    };
                    // A registered function with no type-parameter record cannot
                    // bind the stamped names at runtime, leaving only the splice.
                    {
                        const tp_rec = b.module.registry.func_type_params.get(fid);
                        const n_rec: usize = if (tp_rec) |l| l.items.len else 0;
                        if (n_rec < cf.type_params.len) {
                            if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: fid without type params -> splice\n", .{mname});
                            inline_call.splice_route_tag = "lowerCall:6590";
                            if (try tryInlineCallWithTypeArgs(b, mname, cf, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| return r;
                        }
                    }
                    // A reified inline callee with no written type arguments binds
                    // `T` only through the splice; the typed member call below
                    // stamps written names and would otherwise read a stale one.
                    reified_splice: {
                        var any_reified = false;
                        for (cf.type_params) |*tp| {
                            if (tp.is_reified) any_reified = true;
                        }
                        if (!any_reified) break :reified_splice;
                    // Only when the registered target is this declaration: `cf`
                    // came from a simple-name lookup, and another class's
                    // same-named inline member must not splice onto this receiver.
                        const cf_recv: ?[]const u8 = if (cf.receiver_type) |*rt|
                            typeHead(std.mem.trimEnd(u8, rt.name.name, "?"))
                        else
                            inline_state.inlineMemberOwner(cf);
                        const mf_reg = b.module.funcById(fid) orelse break :reified_splice;
                        const mf_recv: ?[]const u8 = if (mf_reg.params.len != 0 and std.mem.eql(u8, mf_reg.params[0].name, "this"))
                            typeHead(std.mem.trimEnd(u8, mf_reg.params[0].ty.name, "?"))
                        else
                            null;
                        const same_target = blk_same: {
                            const cr = cf_recv orelse break :blk_same mf_recv == null;
                            const mr = mf_recv orelse break :blk_same false;
                            break :blk_same std.mem.eql(u8, typeHead(cr), mr);
                        };
                        if (!same_target) break :reified_splice;
                        // And the call-site receiver must be that type or a
                        // subtype; an untyped receiver keeps the typed call.
                        const site_ty: ?ir.TypeRef = staticExprTypeRef(b, receiver) catch null;
                        const recv_ok = blk_recv: {
                            const mr = mf_recv orelse break :blk_recv site_ty == null;
                            const st = site_ty orelse break :blk_recv false;
                            const sh = typeHead(std.mem.trimEnd(u8, st.name, "?"));
                            break :blk_recv std.mem.eql(u8, sh, mr) or b.module.classIsOrExtends(sh, mr);
                        };
                        if (!recv_ok) break :reified_splice;
                        if (runtime.envOnce("KLIO_SAM_TRACE") != null) std.debug.print("[marm] {s}: reified -> splice first\n", .{mname});
                        inline_call.splice_route_tag = "lowerCall:reified";
                        if (try tryInlineCallWithTypeArgs(b, mname, cf, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| return r;
                    }
                    const recv = try lowerReceiver(b, receiver);
                    const run = try lowerArgRun(b, args);
                    const arg_names_c = try internArgNames(b.allocator, b.module, ast_arg_names);
                    var ta_ids = try b.allocator.alloc(ir.ConstId, names.len);
                    for (names, 0..) |n, i| ta_ids[i] = try b.module.internConst(b.allocator, .{ .String = n });
                    const nm = try b.module.internConst(b.allocator, .{ .String = mname });
                    const dst = b.allocReg();
                    orEmitAudit(b, "member_inline_typed", "CallMemberOrGlobal", mname);
                    try b.push(.{ .CallMemberOrGlobal = .{
                        .dst = dst,
                        .this_idx = 0,
                        .name = nm,
                        .trailing_lambda = b.callTrailingLambda(),
                        .args = run[0],
                        .n_args = run[1],
                        .arg_names = arg_names_c,
                        .recv = recv,
                        .func = fid,
                        .candidates = try cmgCandidates(b, mname, callee.Member.name.span.file, run[1]),
                        .type_args = ta_ids,
                    } });
                    return dst;
                }
            }
            if (member_target == null) member_target = plain_member_inline;
            if (runtime.envOnce("KLIO_PMI_TRACE") != null and plain_member_inline != null and
                member_target == plain_member_inline)
            {
                std.debug.print("[pmi] {s}\n", .{mname});
            }
            inline_call.splice_route_tag = "lowerCall:6623";
            // A receiver whose static class declares a member that binds this
            // call outranks any extension in Kotlin's resolution order.
            const member_binds = member_target == null and try receiverConcreteMemberTakes(b, receiver, mname, args, ast_arg_names);
            if (!member_binds) {
                if (try tryInlineCallWithTypeArgs(b, mname, member_target, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| {
                    if (runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
                        if (std.mem.eql(u8, w, mname)) std.debug.print("[splice-ok] {s} span={}:{}\n", .{ mname, exprSpan(callee).file, exprSpan(callee).start });
                    }
                    return r;
                }
            }
            if (runtime.envOnce("KLIO_SPLICE_TRACE")) |w| {
                if (std.mem.eql(u8, w, mname)) std.debug.print("[splice-bail] {s} span={}:{}\n", .{ mname, exprSpan(callee).file, exprSpan(callee).start });
            }
            // Splice bailed, so dispatch plainly. The body then reads the reified
            // parameters from the process-wide slot the splice writes, so write
            // this call's type arguments there first.
            try storeExplicitReifiedGlobals(b, mname, ast_type_args);
            const recv = try lowerReceiver(b, receiver);
            const bail_arity: ?[]const i16 = try memberCallArgArities(b, receiver, mname, args, ast_arg_names);
            const run = try lowerArgRunWithArity(b, args, bail_arity);
            const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
            const nm = try b.module.internConst(b.allocator, .{ .String = mname });
            const dst = b.allocReg();
            // An unsafe cast's target fixes the static type for overload
            // resolution even on this bail, so a deprecated stub cast to its
            // supertype does not re-bind itself and self-recurse.
            const bail_declared: ?ir.ConstId = blk: {
                if (receiver.* != .As or receiver.As.safe) break :blk null;
                const t = argDeclTypeRef(b, receiver) orelse break :blk null;
                const head = std.mem.trimEnd(u8, t.name, "?");
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
                .declared_recv = bail_declared,
            } });
            return dst;
        }
    }

    // An explicit-receiver call to a no-lambda inline extension on a scalar
    // receiver splices as kotlinc inlines it. Scalar heads with no member
    // namesake in the program only, since a member would outrank it.
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        ast_type_args.len == 0 and args.len <= 2 and
        inline_call.rfsEnabled() and
        !lastArgIsLambdaOrAnon(args))
    scalar_ext: {
        const mname = callee.Member.name.name;
        const receiver = callee.Member.receiver;
        const sxt = if (runtime.envOnce("KLIO_SEXT_TRACE")) |w| std.mem.eql(u8, w, mname) else false;
        const cands = inline_state.candidatesForName(mname) orelse {
            if (sxt) std.debug.print("[sext] {s}: no candidates\n", .{mname});
            break :scalar_ext;
        };
        const head = (try inline_call.gateReceiverHead(b, receiver)) orelse {
            if (sxt) std.debug.print("[sext] {s}: no receiver head (in {s})\n", .{ mname, build.currentRealFn() orelse "-" });
            break :scalar_ext;
        };
        const h = typeHead(std.mem.trimEnd(u8, head, "?"));
        if (sxt) std.debug.print("[sext] {s}: head={s} in {s}\n", .{ mname, h, build.currentRealFn() orelse "-" });
        // `class_member_names` is owner-blind, so any class declaring the name
        // would suppress the splice program-wide; on a scalar head only the
        // scalar's own hierarchy can outrank the extension.
        if (b.module.registry.class_member_names.contains(mname)) {
            const shadowed = blk: {
                const hs = b.module.registry.hierarchy_shadow_names.get(h) orelse break :blk true;
                if (!hs.complete) break :blk true;
                break :blk hs.names.contains(mname);
            };
            if (shadowed) break :scalar_ext;
        }
        const scalar = for ([_][]const u8{
            "Int",   "Long",  "Short",  "Byte",  "Char", "Boolean",
            "Float", "Double", "UInt",  "ULong", "UShort", "UByte",
        }) |sc| {
            if (std.mem.eql(u8, h, sc)) break true;
        } else false;
        if (!scalar) break :scalar_ext;
        for (cands) |cf| {
            const rt = cf.receiver_type orelse continue;
            if (!std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, rt.name.name, "?")), h)) continue;
            if (cf.params.len != args.len) continue;
            var has_fn_or_vararg = false;
            for (cf.params) |*p| {
                if (p.ty.function != null or p.is_vararg) has_fn_or_vararg = true;
            }
            if (has_fn_or_vararg) continue;
            if (anyReified(cf.type_params)) continue;
            // Scalar overload sets differ only by parameter width, so every
            // argument's derived head must equal the declared param head.
            var args_match = true;
            for (cf.params, 0..) |*p, pi| {
                const want = typeHead(std.mem.trimEnd(u8, p.ty.name.name, "?"));
                var got_owned: ?ir.TypeRef = null;
                defer if (got_owned) |*t| t.deinit(b.allocator);
                const got: ?ir.TypeRef = argDeclTypeRefLazy(b, &args[pi]) orelse gblk: {
                    got_owned = try staticExprTypeRef(b, &args[pi]);
                    break :gblk got_owned;
                };
                const gv = got orelse {
                    args_match = false;
                    break;
                };
                if (!std.mem.eql(u8, typeHead(std.mem.trimEnd(u8, gv.name, "?")), want)) {
                    args_match = false;
                    break;
                }
            }
            if (!args_match) continue;
            const expected0 = b.peekExpected();
            const exp_ptr0: ?*const ast.TypeRef = if (expected0) |*_e| _e else null;
            inline_call.splice_route_tag = "lowerCall:6755";
            if (try inline_call.tryInlineCallWithTypeArgs(b, mname, cf, args, ast_arg_names, receiver, ast_type_args, exp_ptr0)) |r| {
                return r;
            }
            break;
        }
    }

    // A qualified member-inline call whose lambda carries a labeled return
    // targeting an open splice must splice: the label names a frameless scope in
    // the caller, which a dynamic dispatch cannot deliver a return to.
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        inline_call.argLambdaTargetsSplicedLabel(b, args))
    {
        const mname = callee.Member.name.name;
        const receiver = callee.Member.receiver;
        const expected = b.peekExpected();
        const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
        if (inline_state.candidatesForName(mname)) |cands| {
            // Strict owner evidence only: a lenient unknown-receiver keep would
            // splice an unrelated same-named member.
            const head = try inline_call.gateReceiverHead(b, receiver);
            if (head != null) {
                for (cands) |cf| {
                    if (cf.receiver_type != null) continue;
                    const owner = inline_state.inlineMemberOwner(cf) orelse continue;
                // A duplicated class name is uniquified per file at registration
                // (`SlotTable$f356`) while the inferred head keeps the
                // source-level name, so accept a base-name match too.
                    const owner_base = if (std.mem.find(u8, owner, "$f")) |i| owner[0..i] else owner;
                    if (!classIsOrExtendsHosted(b, head.?, owner) and
                        !std.mem.eql(u8, head.?, owner_base)) continue;
                    inline_call.splice_route_tag = "lowerCall:6794";
                    if (try tryInlineCallWithTypeArgs(b, mname, cf, args, ast_arg_names, receiver, ast_type_args, exp_ptr)) |r| {
                        return r;
                    }
                    break;
                }
            }
        }
    }

    // An explicit-receiver call to a top-level inline extension with an fn-typed
    // last param fed a lambda splices. The declared receiver may be a concrete
    // head or a bounded fn type param the derived head extends; unbounded `T` and
    // unknown heads keep other routes, and a member of the head's own hierarchy
    // outranks the extension.
    if (!is_infix and callee.* == .Member and !callee.Member.safe and
        ast_type_args.len == 0 and args.len >= 1 and
        !std.mem.eql(u8, runtime.envOnce("KLIO_XLE") orelse "1", "0") and
        !inline_call.argLambdaTargetsLabel(args, callee.Member.name.name))
    ext_lambda: {
        const mname = callee.Member.name.name;
        const receiver = callee.Member.receiver;
        const xlt = if (runtime.envOnce("KLIO_XLE_TRACE")) |w|
            (std.mem.eql(u8, w, "*") or std.mem.eql(u8, w, mname))
        else
            false;
        const last = &args[args.len - 1];
        const last_forwarded = last.* == .Path and last.Path.segments.len == 1 and
            b.inlineLambdaFor(last.Path.segments[0].name) != null;
        if (last.* != .Lambda and last.* != .AnonFun and !last_forwarded) break :ext_lambda;
        const cands = inline_state.candidatesForName(mname) orelse break :ext_lambda;
        // Declared evidence only: an unsafe cast's target, a declared local or
        // param type, a constructor call, or the enclosing extension's receiver
        // for `this`. The general chain resolves overloaded returns heuristically
        // and can hand back a supertype whose eager overload misfits.
        const head0: []const u8 = blk: {
            switch (receiver.*) {
                .As => |a| {
                    if (a.safe) break :ext_lambda;
                    break :blk a.ty.name.name;
                },
                .This => |t| {
                    if (t.qualifier != null) break :ext_lambda;
                    break :blk b.recvTy() orelse break :ext_lambda;
                },
                else => {
                    if (argDeclTypeRefLazy(b, receiver)) |ty| break :blk ty.name;
                    break :ext_lambda;
                },
            }
        };
        const h = typeHead(std.mem.trimEnd(u8, head0, "?"));
        if (b.module.registry.class_member_names.contains(mname)) {
            const cid = b.module.classIdIndexed(h, b.self_package, callee.Member.name.span.file) orelse {
                if (xlt) std.debug.print("[xle] {s}: head {s} unresolvable for shadow check\n", .{ mname, h });
                break :ext_lambda;
            };
            if (b.module.classHierarchyDeclaresMember(cid, mname)) {
                if (xlt) std.debug.print("[xle] {s}: member shadows on {s}\n", .{ mname, h });
                break :ext_lambda;
            }
        }
        var picked: ?*const ast.Function = null;
        var ambiguous = false;
        for (cands) |cf| {
            if (inline_state.inlineMemberOwner(cf) != null) continue;
            const rt = cf.receiver_type orelse continue;
            if (cf.params.len != args.len) continue;
            if (anyReified(cf.type_params)) continue;
            if (anyCrossOrNoinlineParam(cf)) continue;
            if (cf.params[cf.params.len - 1].ty.function == null) continue;
            const rhead = typeHead(std.mem.trimEnd(u8, rt.name.name, "?"));
            var head_ok = std.mem.eql(u8, rhead, h);
            if (!head_ok) {
                for (cf.type_params) |tp| {
                    if (!std.mem.eql(u8, tp.name.name, rhead)) continue;
                    const ub = tp.upper_bound orelse break;
                    const ub_head = typeHead(std.mem.trimEnd(u8, ub.name.name, "?"));
                    head_ok = b.module.classIsOrExtends(h, ub_head);
                    break;
                }
            }
            if (!head_ok) continue;
            if (picked != null) {
                ambiguous = true;
                break;
            }
            picked = cf;
        }
        if (ambiguous) {
            if (xlt) std.debug.print("[xle] {s}: ambiguous candidates\n", .{mname});
            break :ext_lambda;
        }
        const cf = picked orelse {
            if (xlt) std.debug.print("[xle] {s}: no applicable candidate (head {s})\n", .{ mname, h });
            break :ext_lambda;
        };
        if (xlt) std.debug.print("[xle] {s}: splicing head={s} in {s}\n", .{ mname, h, build.currentRealFn() orelse "-" });
        const expected0 = b.peekExpected();
        const exp_ptr0: ?*const ast.TypeRef = if (expected0) |*_e| _e else null;
        inline_call.splice_route_tag = "lowerCall:6899";
        if (try inline_call.tryInlineCallWithTypeArgs(b, mname, cf, args, ast_arg_names, receiver, ast_type_args, exp_ptr0)) |r| {
            return r;
        }
    }

    // `recv?.m(args)`: null-guard the whole call.
    if (callee.* == .Member and callee.Member.safe) {
        const receiver = callee.Member.receiver;
        const name = callee.Member.name;
        const recv = try lowerReceiver(b, receiver);
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = recv, .rhs = null_r } });
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
        b.switchTo(then_b);
        const n = try b.emitConst(.Null);
        try b.push(.{ .Move = .{ .dst = dst, .src = n } });
        b.terminate(.{ .Goto = join });
        b.switchTo(else_b);
        // The receiver is proven non-null here, so declared nullability no longer
        // disqualifies a member, and it is already in a register.
        const declared_from_expr = argDeclTypeRef(b, receiver);
        // The full static deriver, matching the plain member path.
        var inferred_ty: ?ir.TypeRef = if (declared_from_expr == null)
            try staticExprTypeRef(b, receiver)
        else
            null;
        defer if (inferred_ty) |*t| t.deinit(b.allocator);
        switch (try lowerResolvedMemberCall(
            b,
            receiver,
            name,
            args,
            ast_arg_names,
            ast_type_args,
            declared_from_expr orelse inferred_ty,
            .{ .reg = recv, .non_null = true },
        )) {
            .lowered => |reg| {
                try b.push(.{ .Move = .{ .dst = dst, .src = reg } });
                b.terminate(.{ .Goto = join });
                b.switchTo(join);
                return dst;
            },
            .deferred, .none => {},
        }
        // The ordinary call path has more to try, an inline splice above all:
        // `x?.let { it.f() }` gives `it` the non-null receiver type in Kotlin,
        // which a runtime member call does not. Rewrite onto a temporary holding
        // the already-lowered receiver.
        if (declared_from_expr orelse inferred_ty) |rty| non_null_rewrite: {
            const nn_name = std.mem.trimEnd(u8, rty.name, "?");
            if (nn_name.len == 0) break :non_null_rewrite;
            const tmp_name = try std.fmt.allocPrint(b.allocator, "$nn{d}", .{recv});
            var tmp_ty = try rty.clone(b.allocator);
            tmp_ty.nullable = false;
            b.allocator.free(tmp_ty.name);
            tmp_ty.name = try b.allocator.dupe(u8, nn_name);
            try b.pushScope();
            try b.bind(tmp_name, recv);
            try b.setLocalDeclTypeOwned(tmp_name, tmp_ty);
            var segs = [_]ast.Ident{.{ .name = tmp_name, .span = receiver.span() }};
            var recv_expr = Expr{ .Path = .{ .segments = segs[0..], .span = receiver.span() } };
            var plain_callee = Expr{ .Member = .{
                .receiver = &recv_expr,
                .name = name,
                .safe = false,
                .span = callee.span(),
            } };
            var plain = expr.Call;
            plain.callee = &plain_callee;
            const rewritten = Expr{ .Call = plain };
            const rv = try lowerCall(b, &rewritten);
            try b.popScope();
            try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
            b.terminate(.{ .Goto = join });
            b.switchTo(join);
            return dst;
        }
        const run = try lowerArgRun(b, args);
        const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
        const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
        const v = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = v,
            .receiver = recv,
            .name = nm,
            .trailing_lambda = b.callTrailingLambda(),
            .args = run[0],
            .n_args = run[1],
            .arg_names = arg_names,
        } });
        try b.push(.{ .Move = .{ .dst = dst, .src = v } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // `repeat(n) { … }`: inline-desugar to a counted loop.
    if (!is_infix and args.len == 2 and args[1] == .Lambda and
        callee.* == .Path and callee.Path.segments.len == 1 and
        std.mem.eql(u8, callee.Path.segments[0].name, "repeat") and
        b.resolve("repeat") == null and b.module.funcId("repeat") == null)
    {
        return lowerRepeat(b, &args[0], &args[1]);
    }

    // Calls containing a `*spread` argument.
    if (anySpread(args)) {
        if (callee.* == .Member and !callee.Member.safe) {
            const member = callee.Member;
            switch (try lowerResolvedMemberCall(
                b,
                member.receiver,
                member.name,
                args,
                ast_arg_names,
                ast_type_args,
                argDeclTypeRef(b, member.receiver),
                .{},
            )) {
                .lowered => |reg| return reg,
                .deferred, .none => {},
            }
        }
        return lowerCallSpread(b, callee, args, ast_arg_names);
    }

    b.call_tail = call_tail;
    return lowerCallGeneral(b, expr);
}

/// Whether any argument is written `expr as Any` / `as Any?`.
pub fn anyCastToAny(args: []const Expr) bool {
    for (args) |*a| {
        if (a.* == .As and std.mem.eql(u8, std.mem.trimEnd(u8, a.As.ty.name.name, "?"), "Any")) return true;
    }
    return false;
}

pub fn anyReified(type_params: []const ast.TypeParam) bool {
    for (type_params) |tp| {
        if (tp.is_reified) return true;
    }
    return false;
}

/// Number of element or entry heads a bare stdlib container creator carries
/// (`emptyList` -> 1, `emptyMap` -> 2), 0 otherwise. Mirrors
/// `runtime.attachDeclaredElemTypes`'s creator sets.
pub fn emptyContainerCreatorArity(name: []const u8) u8 {
    const elem_creators = [_][]const u8{
        "listOf",      "mutableListOf", "emptyList", "arrayListOf",
        "setOf",       "mutableSetOf",  "emptySet",  "hashSetOf",
        "linkedSetOf", "sortedSetOf",   "arrayOf",   "emptyArray",
        "sequenceOf",  "emptySequence",
    };
    const pair_creators = [_][]const u8{
        "mapOf", "mutableMapOf", "emptyMap", "hashMapOf", "linkedMapOf", "sortedMapOf",
    };
    for (elem_creators) |c| {
        if (std.mem.eql(u8, c, name)) return 1;
    }
    for (pair_creators) |c| {
        if (std.mem.eql(u8, c, name)) return 2;
    }
    return 0;
}

/// True when `name` is a concrete type head rather than an erased
/// type-parameter name. Gates the binding-typed empty-container element stamp.
fn isConcreteTypeHead(b: *FuncBuilder, name: []const u8) bool {
    const value_type_heads = [_][]const u8{
        "Int",        "Long",     "Short",       "Byte",       "UInt",       "ULong",
        "UShort",     "UByte",    "Double",      "Float",      "Boolean",    "Char",
        "String",     "Any",      "Number",      "Unit",       "CharObject", "List",
        "Set",        "Map",      "MutableList", "MutableSet", "MutableMap", "Array",
        "Collection", "Iterable", "Sequence",    "Pair",       "Triple",
    };
    for (value_type_heads) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return b.module.classId(name) != null;
}

/// Build `want` synthetic call-site type-arg `TypeRef`s from the expected
/// container type (`List<String>` -> `[String]`). Null when it does not name
/// `want` concrete, non-star, non-type-parameter heads.
fn synthesizeContainerTypeArgs(
    b: *FuncBuilder,
    exp: ast.TypeRef,
    want: u8,
) Allocator.Error!?[]ast.TypeRef {
    if (exp.type_args.len < want) return null;
    const out = try b.allocator.alloc(ast.TypeRef, want);
    var i: usize = 0;
    while (i < want) : (i += 1) {
        const ta = exp.type_args[i];
        if (ta.is_star) return null;
        if (ta.ty.name.name.len == 0) return null;
        // Only a concrete head carries runtime element identity; stamping a bare
        // type-parameter head would forge a proof, so leave it on-demand.
        if (!isConcreteTypeHead(b, ta.ty.name.name)) return null;
        out[i] = ta.ty;
    }
    return out;
}

pub fn anySpread(args: []const Expr) bool {
    for (args) |a| {
        if (a == .Spread) return true;
    }
    return false;
}

fn lowerRepeat(b: *FuncBuilder, n_arg: *const Expr, lam_arg: *const Expr) Allocator.Error!Reg {
    const lam = lam_arg.Lambda;
    const n_reg = try lowerExpr(b, n_arg);
    const i_reg = b.allocReg();
    const zero = try b.emitConst(.{ .Int = 0 });
    try b.push(.{ .Move = .{ .dst = i_reg, .src = zero } });
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });
    b.switchTo(header);
    const cond = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = cond, .op = .Less, .lhs = i_reg, .rhs = n_reg } });
    b.terminate(.{ .Branch = .{ .cond = cond, .t = body_blk, .f = exit } });
    b.switchTo(body_blk);
    try b.pushScope();
    const pname: []const u8 = if (lam.params.len != 0) lam.params[0].name else "it";
    try b.bind(pname, i_reg);
    try b.pushLoop(null, header, exit);
    _ = try lowerBlock(b, &lam.body);
    b.popLoop();
    try b.popScope();
    const one = try b.emitConst(.{ .Int = 1 });
    const nexti = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = nexti, .op = .Add, .lhs = i_reg, .rhs = one } });
    try b.push(.{ .Move = .{ .dst = i_reg, .src = nexti } });
    b.terminate(.{ .Goto = header });
    b.switchTo(exit);
    return b.emitConst(.Unit);
}

/// Compact registers into a contiguous run, returning the start reg, or reg 0
/// when empty.
pub fn packContiguous(b: *FuncBuilder, regs: []const Reg) Allocator.Error!Reg {
    if (regs.len == 0) return Reg.from(0);
    const start = b.allocReg();
    try b.push(.{ .Move = .{ .dst = start, .src = regs[0] } });
    for (regs[1..]) |r| {
        const slot = b.allocReg();
        try b.push(.{ .Move = .{ .dst = slot, .src = r } });
    }
    return start;
}

pub fn lowerSpreadParts(b: *FuncBuilder, args: []const Expr) Allocator.Error![]SpreadPart {
    const parts = try b.allocator.alloc(SpreadPart, args.len);
    for (args, parts) |*arg, *part| {
        if (arg.* == .Spread) {
            part.* = .{ .reg = try lowerExpr(b, arg.Spread.expr), .is_spread = true };
        } else {
            part.* = .{ .reg = try lowerExpr(b, arg), .is_spread = false };
        }
    }
    return parts;
}

/// Resolve a `this` reg for a bare extension call: bound local, else a capture
/// inside a lambda body, else null. Binds the capture so later refs reuse it.
pub fn resolveThisForBareCall(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, true, true);
}

/// Like `resolveThisForBareCall` but does not bind `this` locally.
pub fn resolveThisForBareCallNoBind(b: *FuncBuilder) Allocator.Error!?Reg {
    return resolveThisRegKind(b, true, false);
}

fn lowerCallSpread(
    b: *FuncBuilder,
    callee: *const Expr,
    args: []const Expr,
    ast_arg_names: []const ?[]const u8,
) Allocator.Error!Reg {
    // `recv.method(*array)` dispatches the flattened args through member
    // resolution, not by invoking `recv.method` as a value, so carry the method
    // name and route through `callMemberNamed`.
    var member_id: ?ConstId = null;
    var spread_name: ?ConstId = null;
    var spread_candidates: ?[]const FuncId = null;
    var spread_anchor_pkg: ?ConstId = null;
    const callee_reg = blk: {
        if (callee.* == .Member) {
            const m = callee.Member;
            if (b.resolve(m.name.name) == null and !b.knowsOuter(m.name.name) and !b.isLocalFn(m.name.name)) {
                member_id = try b.module.internConst(b.allocator, .{ .String = m.name.name });
                break :blk try lowerReceiver(b, m.receiver);
            }
        }
        // A bare callee naming an enclosing-class member fn dispatches through
        // `this`: a member fn is not a field, so the value path dies on
        // `get_field`. A known top-level namesake keeps the global path.
        if (callee.* == .Path and callee.Path.segments.len == 1) {
            const name = callee.Path.segments[0].name;
            // Only a plain top-level namesake keeps the global path; an extension
            // namesake needs a receiver of its own type.
            if (b.resolve(name) == null and !b.isLocalFn(name) and b.hasEnclosingMember(name) and
                !b.module.hasNonExtensionBareCallCandidate(name, callee.Path.segments[0].span.file))
            {
                if (try resolveThisForBareCall(b)) |this_reg| {
                    member_id = try b.module.internConst(b.allocator, .{ .String = name });
                    break :blk this_reg;
                }
            }
            // A spread can only bind a `vararg` parameter, so pick among the
            // vararg-bearing candidates; the arg-blind value read below could
            // hand back a zero-arg overload and drop the elements.
            if (b.resolve(name) == null and !b.knowsOuter(name) and !b.isLocalFn(name) and
                !b.hasOwnMember(name) and
                b.module.hasBareCallCandidate(name, callee.Path.segments[0].span.file))
            {
                const nm = try b.module.internConst(b.allocator, .{ .String = name });
                if (try b.module.boundedSpreadCandidates(
                    b.allocator,
                    name,
                    b.self_package,
                    callee.Path.segments[0].span.file,
                )) |ids| {
                    // Every candidate an extension: the bare call binds the
                    // implicit receiver, so route it as a member-form dispatch or
                    // the receiver slot swallows the first spread element.
                    const all_ext = ids.len != 0 and blk_ext: {
                        for (ids) |fid| {
                            const f = b.module.funcById(fid) orelse break :blk_ext false;
                            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) break :blk_ext false;
                        }
                        break :blk_ext true;
                    };
                    if (all_ext) {
                        if (try resolveThisForBareCall(b)) |this_reg| {
                            member_id = nm;
                            break :blk this_reg;
                        }
                    }
                    spread_name = nm;
                    spread_candidates = ids;
                    if (ids.len != 0) {
                        if (b.module.funcById(ids[0])) |f| {
                            spread_anchor_pkg = try b.module.internConst(
                                b.allocator,
                                .{ .String = f.package },
                            );
                        }
                        const dst = b.allocReg();
                        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .func = ids[0] } });
                        break :blk dst;
                    }
                }
                if (b.module.funcIdForSpreadCall(name, b.ownerClass())) |fid| {
                    // An extension binds the implicit receiver, so route it as a
                    // member-form dispatch rather than let the receiver slot
                    // swallow the first spread element.
                    const is_ext = blk_ext2: {
                        const f = b.module.funcById(fid) orelse break :blk_ext2 false;
                        break :blk_ext2 f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
                    };
                    if (is_ext) {
                        if (try resolveThisForBareCall(b)) |this_reg| {
                            member_id = nm;
                            break :blk this_reg;
                        }
                    }
                    const dst = b.allocReg();
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .func = fid } });
                    break :blk dst;
                }
            }
            // No local, global, or recorded enclosing member: a bare call can only
            // be a member of the implicit receiver, and a smart-cast `this` in an
            // extension on a type parameter records no static member set.
            if (b.resolve(name) == null and !b.knowsOuter(name) and !b.isLocalFn(name) and
                !b.module.hasBareCallCandidate(name, callee.Path.segments[0].span.file))
            {
                if (try resolveThisForBareCall(b)) |this_reg| {
                    member_id = try b.module.internConst(b.allocator, .{ .String = name });
                    break :blk this_reg;
                }
            }
        }
        break :blk try lowerExpr(b, callee);
    };
    const parts = try lowerSpreadParts(b, args);
    const arg_names = try internArgNames(b.allocator, b.module, ast_arg_names);
    const dst = b.allocReg();
    try b.push(.{ .CallSpread = .{
        .dst = dst,
        .callee = callee_reg,
        .parts = parts,
        .arg_names = arg_names,
        .member = member_id,
        .name = spread_name,
        .candidates = spread_candidates,
        .anchor_pkg = spread_anchor_pkg,
    } });
    return dst;
}

/// True when the enclosing class declares a primary-ctor property param named
/// `name` and a same-named `vararg` method. A bare `name(args)` must then resolve
/// by argument shape, so route it through member dispatch.
pub fn ctorParamShadowsVarargMethod(b: *FuncBuilder, name: []const u8) bool {
    const owner = b.ownerClass() orelse return false;
    const cid = b.module.classId(owner) orelse return false;
    const idx = cid.int();
    if (idx >= b.module.classes.items.len) return false;
    const cls = &b.module.classes.items[idx];
    var has_prop_param = false;
    for (cls.primary_params) |p| {
        if (p.is_property and std.mem.eql(u8, p.name, name)) {
            has_prop_param = true;
            break;
        }
    }
    if (!has_prop_param) return false;
    for (cls.methods) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (std.mem.eql(u8, f.name, name) and
            f.params.len != 0 and f.params[f.params.len - 1].is_vararg) return true;
    }
    return false;
}

/// A plain function parameter is inapplicable to a trailing-lambda call when its
/// own final value parameter is not function-typed. Inline splices keep this
/// shape through `currentInlineDecl`; the substituted lambda value does not.
pub fn plainFnParamRejectsTrailingLambda(
    b: *const FuncBuilder,
    name: []const u8,
    args: []const Expr,
) bool {
    if (!lastArgIsLambda(args)) return false;
    if (b.isPlainFnParam(name)) return !b.fnParamTakesTrailingLambda(name);
    const decl = b.currentInlineDecl() orelse return false;
    for (decl.params) |*param| {
        if (!std.mem.eql(u8, param.name.name, name)) continue;
        const ft = param.ty.function orelse return false;
        if (ft.receiver != null) return false;
        return ft.params.len == 0 or
            ft.params[ft.params.len - 1].function == null;
    }
    return false;
}

/// Bare-path inline expansion: splice an inline-lambda parameter's body, the
/// reified overload an explicit `<T>` binds, or the resolved inline target of a
/// bare call.
pub fn tryBareInlineExpansion(b: *FuncBuilder, expr: *const Expr) Allocator.Error!?Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    const ast_arg_names = call.arg_names;
    const ast_type_args = call.type_args;
    if (call.is_infix or callee.* != .Path) {
        if (!call.is_infix and callee.* == .Member) return tryQualifiedInlineExpansion(b, expr);
        return null;
    }
    if (callee.Path.segments.len != 1) return tryQualifiedInlineExpansion(b, expr);
    const nm = callee.Path.segments[0].name;
    if (b.inlineLambdaFor(nm)) |lam| {
        if (!plainFnParamRejectsTrailingLambda(b, nm, args)) {
            return try spliceInlineLambda(b, nm, lam, args);
        }
    }
    // A local binding of a function-typed value shadows every top-level namesake
    // for a bare call. A non-function-typed local does not shadow.
    if (b.resolve(nm) != null and !b.isNonFnParam(nm)) return null;
    // A constructible same-named class that shadows per the scope rules is the
    // Kotlin target, so never splice an inline factory over it.
    if (try shadowedByClass(b, callee, args, ast_arg_names)) return null;
    const inline_call_shape = CallShape{
        .want = args.len,
        .last_is_lambda = lastArgIsLambdaOrAnon(args),
        .trailing_lambda_arity = trailingLambdaArity(args),
        .call_file = callee.Path.segments[0].span.file,
        .arg0_class_literal = args.len != 0 and args[0] == .MemberRef and
            std.mem.eql(u8, args[0].MemberRef.name.name, "class"),
    };
    // An explicit `<T>` binds a reified parameter, so a reified inline overload
    // outranks a non-reified `KClass<T>` namesake, which would lower `<T>` as a
    // constructor value instead.
    if (ast_type_args.len != 0) {
        if (inline_state.reifiedInlineFnAstFor(nm, inline_call_shape)) |rf| {
            if (bareInlineNeedsSplice(b, nm, rf, args)) {
                const expected = b.peekExpected();
                const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
                var selected = if (inline_state.inlineIdByAst(rf)) |id|
                    try selectedCallArgsForBuilder(
                        b,
                        FuncId.from(id),
                        args,
                        ast_arg_names,
                        exprSpan(callee),
                        call.has_trailing_lambda,
                    )
                else
                    SelectedCallArgs{ .args = args, .names = ast_arg_names };
                defer selected.deinit(b.allocator);
                inline_call.splice_route_tag = "tryBareInlineExpansion:7457";
                if (try tryInlineCallWithTypeArgs(b, nm, rf, selected.args, selected.names, null, ast_type_args, exp_ptr)) |r| {
                    return r;
                }
            }
        }
    }
    const nlr_dbg = if (runtime.envOnce("KLIO_EF_TRACE")) |efw| std.mem.eql(u8, efw, nm) else false;
    if (try inlineTargetForBareCall(b, &callee.Path.segments[0], args, ast_arg_names, inline_call_shape)) |f| {
        if (nlr_dbg) {
            const last_stmts: usize = if (args.len > 0 and args[args.len - 1] == .Lambda) args[args.len - 1].Lambda.body.stmts.len else 999;
            std.debug.print("[tbie] synchronized file={d} in_fn={s} target-found needs={} nlr={} nstmts={d}\n", .{ callee.Path.segments[0].span.file.int(), build.currentRealFn() orelse "-", bareInlineNeedsSplice(b, nm, f, args), inline_call.argLambdaHasNonlocalReturn(args), last_stmts });
        }
        // A reified inline overload whose type parameter appears only in the
        // trailing lambda's parameter list cannot bind it from a lambda declaring
        // fewer arguments; Kotlin drops such an overload, so decline.
        const reified_underfilled = ast_type_args.len == 0 and
            anyReified(f.type_params) and
            inline_call_shape.trailing_lambda_arity != null and
            reifiedNeedsLambdaArity(b, f, inline_call_shape.trailing_lambda_arity.?) and
            !inline_call.reifiedBindableFromArgs(b, f, args, ast_arg_names);
        if (!reified_underfilled and bareInlineNeedsSpliceT(b, nm, f, args, ast_type_args.len != 0)) {
            const expected = b.peekExpected();
            const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
            var selected = if (inline_state.inlineIdByAst(f)) |id|
                try selectedCallArgsForBuilder(
                    b,
                    FuncId.from(id),
                    args,
                    ast_arg_names,
                    exprSpan(callee),
                    call.has_trailing_lambda,
                )
            else
                SelectedCallArgs{ .args = args, .names = ast_arg_names };
            defer selected.deinit(b.allocator);
            inline_call.splice_route_tag = "tryBareInlineExpansion:7497";
            if (try tryInlineCallWithTypeArgs(b, nm, f, selected.args, selected.names, null, ast_type_args, exp_ptr)) |r| {
                return r;
            }
            if (nlr_dbg) std.debug.print("[tbie] synchronized in_fn={s} SPLICE-DECLINED\n", .{build.currentRealFn() orelse "-"});
        }
    }
    if (nlr_dbg) std.debug.print("[tbie] synchronized file={d} NO-TARGET-OR-DECLINED\n", .{callee.Path.segments[0].span.file.int()});
    return null;
}

/// Package-qualified inline expansion: `kotlin.synchronized(lock) { ... }`.
/// Kotlin inlines an inline fun at every call spelling. Applies only when the
/// whole dotted prefix equals the candidate's declaring package.
fn tryQualifiedInlineExpansion(b: *FuncBuilder, expr: *const Expr) Allocator.Error!?Reg {
    const call = expr.Call;
    const callee = call.callee;
    const args = call.args;
    // Flatten the callee into a dotted name run: a multi-segment Path, or a
    // Member chain whose links are all plain non-safe accesses over a Path head.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(b.allocator);
    {
        var member_names: std.ArrayList([]const u8) = .empty;
        defer member_names.deinit(b.allocator);
        var cur = callee;
        while (cur.* == .Member) {
            if (cur.Member.safe) return null;
            try member_names.append(b.allocator, cur.Member.name.name);
            cur = cur.Member.receiver;
        }
        if (cur.* != .Path) return null;
        for (cur.Path.segments) |seg| try names.append(b.allocator, seg.name);
        var i = member_names.items.len;
        while (i > 0) {
            i -= 1;
            try names.append(b.allocator, member_names.items[i]);
        }
    }
    if (names.items.len < 2) return null;
    const segs = names.items;
    const nm = segs[segs.len - 1];
    const qtrace = if (runtime.envOnce("KLIO_QIE_TRACE")) |w| std.mem.eql(u8, w, nm) else false;
    // A resolvable head names a value chain, not a package path; a class head is
    // a companion or static route.
    if (b.resolve(segs[0]) != null) {
        if (qtrace) std.debug.print("[qie] {s}: head resolves\n", .{nm});
        return null;
    }
    const cands = inline_state.candidatesForName(nm) orelse {
        if (qtrace) std.debug.print("[qie] {s}: no candidates\n", .{nm});
        return null;
    };
    var pkg_buf: std.ArrayList(u8) = .empty;
    defer pkg_buf.deinit(b.allocator);
    for (segs[0 .. segs.len - 1], 0..) |seg, i| {
        if (i != 0) try pkg_buf.append(b.allocator, '.');
        try pkg_buf.appendSlice(b.allocator, seg);
    }
    const pkg = pkg_buf.items;
    var picked: ?*const ast.Function = null;
    for (cands) |f| {
        if (f.receiver_type != null) continue;
        if (inline_state.inlineMemberOwner(f) != null) continue;
        const fpkg = b.module.packageOfFile(f.name.span.file) orelse {
            if (qtrace) std.debug.print("[qie] {s}: cand file={d} no package\n", .{ nm, f.name.span.file.int() });
            continue;
        };
        if (!std.mem.eql(u8, fpkg, pkg)) {
            if (qtrace) std.debug.print("[qie] {s}: cand pkg={s} want={s}\n", .{ nm, fpkg, pkg });
            continue;
        }
        if (!qualifiedInlineArityFits(f, args.len)) {
            if (qtrace) std.debug.print("[qie] {s}: arity misfit\n", .{nm});
            continue;
        }
        // Same-package overloads that both fit: the dynamic path ranks.
        if (picked != null) return null;
        picked = f;
    }
    const f = picked orelse {
        if (qtrace) std.debug.print("[qie] {s}: no pick\n", .{nm});
        return null;
    };
    if (!bareInlineNeedsSpliceT(b, nm, f, args, call.type_args.len != 0)) {
        if (qtrace) std.debug.print("[qie] {s}: needs-splice false\n", .{nm});
        return null;
    }
    if (qtrace) std.debug.print("[qie] {s}: splicing pkg={s}\n", .{ nm, pkg });
    const expected = b.peekExpected();
    const exp_ptr: ?*const ast.TypeRef = if (expected) |*_e| _e else null;
    var selected = if (inline_state.inlineIdByAst(f)) |id|
        try selectedCallArgsForBuilder(
            b,
            FuncId.from(id),
            args,
            call.arg_names,
            exprSpan(callee),
            call.has_trailing_lambda,
        )
    else
        SelectedCallArgs{ .args = args, .names = call.arg_names };
    defer selected.deinit(b.allocator);
    inline_call.splice_route_tag = "tryQualifiedInlineExpansion:7606";
    return try tryInlineCallWithTypeArgs(b, nm, f, selected.args, selected.names, null, call.type_args, exp_ptr);
}

fn qualifiedInlineArityFits(f: *const ast.Function, want: usize) bool {
    if (want > f.params.len) return false;
    for (f.params) |*p| {
        if (p.is_vararg) return false;
    }
    var i: usize = want;
    while (i < f.params.len) : (i += 1) {
        if (f.params[i].default == null) return false;
    }
    return true;
}

/// Whether any registered class's fqn ends in `.{name}` or `${name}`. Splice
/// windows with an unknown owner chain cannot walk the nesting tree, so this
/// probe keeps a capitalized bare call from being read as a member.
pub fn anyClassNamed(b: *FuncBuilder, name: []const u8) bool {
    for (b.module.classes.items) |*c| {
        const fqn = c.fqn;
        if (fqn.len > name.len and std.mem.endsWith(u8, fqn, name)) {
            const sep = fqn[fqn.len - name.len - 1];
            if (sep == '.' or sep == '$') return true;
        }
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

/// Whether the eager-vs-lazy audit is enabled (`KLIO_EAGER_AUDIT=1`).
pub fn eagerAuditOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.envOnce("KLIO_EAGER_AUDIT") != null;
    S.cached = on;
    return on;
}

/// Whether a member self-call's written receiver names the function's own
/// dispatch: any receiver for a top-level extension, `this`, `this@Owner`, or
/// the owner object for a member.
pub fn tailrecReceiverIsSelf(b: *FuncBuilder, receiver: *const Expr) bool {
    const owner = b.ownerClass() orelse return true;
    const simple = if (std.mem.findScalarLast(u8, owner, '.')) |dot| owner[dot + 1 ..] else owner;
    // kotlinc does not treat a companion member called through its outer class
    // as a self-call; neither does this.
    return switch (receiver.*) {
        .This => |t| t.qualifier == null or std.mem.eql(u8, t.qualifier.?.name, simple),
        .Path => |p| std.mem.eql(u8, p.segments[p.segments.len - 1].name, simple),
        else => false,
    };
}

pub fn lowerCallGeneralNoJump(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    b.call_tail = false;
    return lowerCallGeneral(b, expr);
}
