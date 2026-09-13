//! Inline target selection for a bare call, with its evidence, tier and
//! `this`-scan probes.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const inline_state = @import("../inline_state.zig");
const inline_call = @import("../inline_call.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const FuncId = ir.FuncId;
const inlineFnAstForRecv = inline_state.inlineFnAstForRecv;
const CallShape = inline_state.CallShape;
const argLambdaHasNonlocalReturn = inline_call.argLambdaHasNonlocalReturn;

const paths_mod = @import("paths.zig");
const enclosingMemberTakes = paths_mod.enclosingMemberTakes;
const ownMemberRejectsLambdas = paths_mod.ownMemberRejectsLambdas;

const call_mod = @import("call.zig");
const anyReified = call_mod.anyReified;
const lastArgIsLambdaOrAnon = call_mod.lastArgIsLambdaOrAnon;

const call_general_mod = @import("call_general.zig");
const aFuncFits = call_general_mod.aFuncFits;
const bareInlineVisibleFrom = call_general_mod.bareInlineVisibleFrom;
const classIsOrExtendsHosted = call_general_mod.classIsOrExtendsHosted;
const inlineBodyRecvChain = call_general_mod.inlineBodyRecvChain;
const inlineBodyRecvHead = call_general_mod.inlineBodyRecvHead;
const inlineOwnerInEnclosingHierarchy = call_general_mod.inlineOwnerInEnclosingHierarchy;
const narrowingRecvChain = call_general_mod.narrowingRecvChain;
const nonInlineExtensionFits = call_general_mod.nonInlineExtensionFits;
const receiverMemberTakesCall = call_general_mod.receiverMemberTakesCall;
const retierPlainInlinePick = call_general_mod.retierPlainInlinePick;
const varargSiblingForContainerMismatch = call_general_mod.varargSiblingForContainerMismatch;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;

const type_probe_mod = @import("type_probe.zig");
const paramLitKind = type_probe_mod.paramLitKind;

const audit_mod = @import("audit.zig");
const resolveAuditOn = audit_mod.resolveAuditOn;
const resolveStrictOn = audit_mod.resolveStrictOn;

pub fn inlineTargetForBareCall(
    b: *FuncBuilder,
    seg: *const ast.Ident,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    shape: CallShape,
) Allocator.Error!?*const ast.Function {
    const nm = seg.name;
    // The inline candidate table is keyed by declared name, so an aliased call
    // must look its target up under that name.
    const inline_nm: []const u8 = blk: {
        if (b.module.importAliasIn(seg.span.file, nm)) |asegs| {
            if (asegs.len != 0 and !std.mem.eql(u8, asegs[asegs.len - 1], nm) and
                inline_state.candidatesForName(asegs[asegs.len - 1]) != null)
            {
                break :blk asegs[asegs.len - 1];
            }
        }
        break :blk nm;
    };
    // The active splice's declared receiver serves as evidence when the caller
    // context has none; it feeds only this pick, not binding.
    const evid_chain = try inlineBodyRecvChain(b);

    // Host-backed default imports suppress the simple-name candidate table but not
    // an exact FuncId from the scope-aware index. The source declaration stays the
    // semantic target where a splice is required.
    const narrowed = inlineFnAstForRecv(inline_nm, shape, evid_chain);
    // The correct target is not in the inline candidate set when a receiverless
    // candidate is picked while a same-named non-inline extension fits the
    // in-scope receiver, so decline to normal dispatch. Gated on that extension
    // existing, so a reified splice with no sibling keeps its type argument.
    if (runtime.envOnce("KLIO_SPLICEDECL")) |w| if (std.mem.eql(u8, w, nm)) {
        std.debug.print("[splicedecl] {s} narrowed={} recvty={?s} chain={?d} fits={}\n", .{
            nm, narrowed != null,
            if (narrowed) |p| (if (p.receiver_type) |rt| rt.name.name else null) else null,
            if (evid_chain) |c| c.len else null,
            if (evid_chain) |c| nonInlineExtensionFits(b, nm, c, seg.span.file) else false,
        });
    };
    // Whether the splice that would happen is receiverless: the receiver-narrowed
    // pick is, or narrowing found nothing and the index picks among namesakes.
    const splice_would_be_receiverless = if (narrowed) |p|
        (p.receiver_type == null and inline_state.inlineMemberOwner(p) == null)
    else blk: {
        // Decline only when no candidate takes a receiver, since an inline
        // extension is otherwise the right target. The table is keyed by declared
        // name, so an aliased call must unalias first.
        var cname = nm;
        if (b.module.importAliasIn(seg.span.file, nm)) |segs| {
            if (segs.len != 0) cname = segs[segs.len - 1];
        }
        const cands = inline_state.candidatesForName(cname) orelse break :blk false;
        for (cands) |c| {
            if (c.receiver_type != null or inline_state.inlineMemberOwner(c) != null) break :blk false;
        }
        break :blk cands.len != 0;
    };
    if (splice_would_be_receiverless) {
        if (evid_chain) |chain| {
        // Abandon the splice outright: clearing `narrowed` is not enough, since
        // the indexed resolution re-picks the same receiverless namesake.
            if (nonInlineExtensionFits(b, nm, chain, seg.span.file)) return null;
        }
    }
    const ires = b.module.resolveBareCallIndexed(
        nm,
        b.self_package,
        seg.span.file,
        args.len,
        shape.last_is_lambda,
    );
    if (runtime.envOnce("KLIO_EF_TRACE")) |efw| {
        if (std.mem.eql(u8, efw, nm)) {
            const rid: i64 = switch (ires.outcome) {
                .resolved => |fid| @intCast(fid.int()),
                else => -1,
            };
            std.debug.print("[tbie] {s} outcome={s} fid={d} narrowed={} ast_by_id={}\n", .{
                nm,
                @tagName(ires.outcome),
                rid,
                narrowed != null,
                rid >= 0 and inline_state.inlineAstById(@intCast(rid)) != null,
            });
        }
    }
    var pick: ?*const ast.Function = switch (ires.outcome) {
        .resolved => |fid| blk: {
            // Kotlin resolves an in-scope receiver's extension over a top-level
            // function, and the index never models receivers.
            if (narrowed) |nf| {
                if (nf.receiver_type != null and bareInlineNeedsSplice(b, nm, nf, args)) {
                    break :blk nf;
                }
                // Companion scope is likewise invisible to the index, and Kotlin
                // ranks it above a top-level namesake.
                if (nf.receiver_type == null and bareInlineNeedsSplice(b, nm, nf, args)) {
                    if (inline_state.inlineMemberOwner(nf)) |nowner| {
                        if (companionOwnerInEnclosingHierarchy(b, nowner)) break :blk nf;
                    }
                }
            }
            const idx_pick = inline_state.inlineAstById(fid.int());
            // A trailing-lambda call cannot bind a candidate whose last parameter
            // is not function-typed.
            if (shape.last_is_lambda) {
                if (idx_pick) |ip| {
                    if (!astLastParamHostsLambda(ip)) break :blk null;
                }
            }
            break :blk idx_pick;
        },
        // A receiverless inline fn is a legal target only when its declaring
        // package is in scope; extension picks stay, discriminated by receiver
        // narrowing rather than package scope.
        .deferred => blk: {
            var nf = narrowed orelse break :blk null;
            // A plain pick re-ranks by call-site scope tier: the registration-order
            // pick across packs is bake-order-sensitive.
            nf = retierPlainInlinePick(b, nf, nm, shape, seg.span.file);
            // Member-inline fns are exempt: their discriminator is the enclosing
            // class hierarchy, checked below, not package scope.
            if (nf.receiver_type == null and
                inline_state.inlineMemberOwner(nf) == null and
                !bareInlineVisibleFrom(b, nf, seg.span.file))
            {
                break :blk null;
            }
            break :blk nf;
        },
    };
    // Vararg-versus-container siblings are the same arity, so the index cannot
    // separate them; swap in the vararg sibling when the argument disproves the
    // container parameter.
    if (pick) |pf| {
        if (try varargSiblingForContainerMismatch(b, nm, pf, args)) |alt| pick = alt;
    }

    // A bare call inside a member binds `this.<name>`, so the overload must be
    // declared in the enclosing class's own hierarchy, which the receiverless
    // index resolution cannot enforce.
    if (pick) |pf| {
        if (b.ownerClass()) |enclosing| {
            // The pick is an inline member of a class the enclosing class does not
            // belong to, and a bare call binds `this.<name>`.
            if (pf.receiver_type == null) {
                if (inline_state.inlineMemberOwner(pf)) |powner| {
                    if (!classIsOrExtendsHosted(b, enclosing, powner)) {
                        // Prefer a same-name inline overload declared in the
                        // enclosing class's own hierarchy.
                        var replaced = false;
                        if (inline_state.candidatesForName(nm)) |cands| {
                            if (cands.len >= 2) {
                                for (cands) |cf| {
                                    if (cf == pf or cf.receiver_type != null) continue;
                                    if (inlineOwnerInEnclosingHierarchy(b, enclosing, cf)) {
                                        pick = cf;
                                        replaced = true;
                                        break;
                                    }
                                }
                            }
                        }
                        // Otherwise decline so the normal member-call path binds
                        // the enclosing class's own member, even a non-inline one.
                        // Only an applicable own member outranks the pick.
                        if (!replaced and b.hasEnclosingMember(nm) and
                            enclosingMemberTakes(b, nm, args.len) and !ownMemberRejectsLambdas(b, nm, args))
                        {
                            if (runtime.envOnce("KLIO_INLINE_PICK")) |w| { if (std.mem.eql(u8, w, nm)) std.debug.print("[ipick-why] {s} decline at L229\n", .{nm}); }
                            return null;
                        }
                    }
                }
            }
        } else if (pf.receiver_type == null) {
            // With no enclosing class a member-inline pick is in scope only through
            // an implicit receiver, so when its owner is not on the known chain
            // prefer the same-name extension whose declared receiver is.
            if (inline_state.inlineMemberOwner(pf)) |powner| {
                const chain: ?[]const []const u8 = try narrowingRecvChain(b);
                if (chain) |ch| {
                    var owner_on_chain = false;
                    for (ch) |cn| {
                        if (std.mem.eql(u8, cn, powner)) {
                            owner_on_chain = true;
                            break;
                        }
                    }
                    if (!owner_on_chain) {
                        if (inline_state.candidatesForName(nm)) |cands| {
                            for (cands) |cf| {
                                if (cf == pf) continue;
                                const rt = cf.receiver_type orelse continue;
                                for (ch) |cn| {
                                    if (std.mem.eql(u8, cn, rt.name.name)) {
                                        pick = cf;
                                        break;
                                    }
                                }
                                if (pick != pf) break;
                            }
                        }
                    }
                }
            }
        }
    }
    // An inline overload whose last parameter is a function type does not apply to
    // an object-instance argument, which splicing would invoke as `obj.invoke(…)`.
    if (pick) |pf| {
        const inline_takes_fn = pf.params.len != 0 and pf.params[pf.params.len - 1].ty.function != null;
        if (inline_takes_fn and lastArgIsObjectNotFunction(b, args) and
            b.resolve(nm) == null and b.hasOwnMember(nm))
        {
            if (runtime.envOnce("KLIO_INLINE_PICK")) |w| { if (std.mem.eql(u8, w, nm)) std.debug.print("[ipick-why] {s} decline at L282\n", .{nm}); }
            return null;
        }
    }
    // The selectors above rank by name, arity, and receiver only, so overloads
    // differing in a parameter type tie and the first registered wins. Re-pick the
    // sibling the argument evidence fits.
    if (pick) |pf| {
        if (inlineEvidenceRejects(b, pf, args, arg_names)) {
            var better: ?*const ast.Function = null;
            if (inline_state.candidatesForName(nm)) |cands| {
                for (cands) |cf| {
                    if (cf == pf) continue;
                    if ((cf.receiver_type == null) != (pf.receiver_type == null)) continue;
                    if (!inlineShapeFits(cf, args, shape)) continue;
                    if (inlineEvidenceRejects(b, cf, args, arg_names)) continue;
                    better = cf;
                    break;
                }
            }
            // No sibling fits either, so decline and let the dynamic call path
            // resolve on runtime values.
            if (runtime.envOnce("KLIO_INLINE_PICK")) |w| {
                if (std.mem.eql(u8, w, nm)) std.debug.print("[ipick-why] {s} evidence re-pick better={}\n", .{ nm, better != null });
            }
            pick = better;
        }
    }
    // The enclosing class's own applicable member outranks an inline extension
    // whose declared receiver the chain does not evidence; one on the chain keeps
    // the splice, being Kotlin's pick.
    if (pick) |pf| {
        if (runtime.envOnce("KLIO_INLINE_PICK")) |w| {
            if (std.mem.eql(u8, w, nm)) std.debug.print("[ipick-tail] {s} recv={s} hasOwn={} applicable={}\n", .{ nm, if (pf.receiver_type) |rt| rt.name.name else "-", b.hasOwnMember(nm), b.ownMemberApplicable(nm, args.len) });
        }
        if (pf.receiver_type != null and b.hasOwnMember(nm) and
            enclosingMemberTakes(b, nm, args.len) and !ownMemberRejectsLambdas(b, nm, args))
        {
            const rt_name = pf.receiver_type.?.name.name;
            var evidenced = false;
            if (try inlineBodyRecvChain(b)) |ch| {
                for (ch) |cn| {
                    if (std.mem.eql(u8, cn, rt_name)) {
                        evidenced = true;
                        break;
                    }
                }
            }
            if (!evidenced) return null;
        }
    }
    // An abstract member on the implicit-receiver tower that can take this call
    // outranks an extension or top-level inline candidate. Member-inline picks are
    // exempt, being themselves tower members.
    if (pick) |pf| {
        if (inline_state.inlineMemberOwner(pf) == null and
            receiverMemberTakesCall(b, evid_chain, nm, args.len))
        {
            if (runtime.envOnce("KLIO_ABSVETO_TRACE") != null)
                std.debug.print("[absveto] {s} argc={d} in={s}\n", .{ nm, args.len, build.currentRealFn() orelse "-" });
            if (runtime.envOnce("KLIO_INLINE_PICK")) |w| { if (std.mem.eql(u8, w, nm)) std.debug.print("[ipick-why] {s} decline at L353\n", .{nm}); }
            return null;
        }
    }
    inlineResolveAudit(b, nm, seg.span.file, narrowed, pick, args, shape.last_is_lambda, ires);
    return pick;
}

/// Whether argument type evidence definitely excludes inline candidate `f`: a
/// known user class bound to a builtin-kind parameter, or two distinct known class
/// heads. Conservative, so unknown evidence never rejects.
pub fn inlineEvidenceRejects(b: *FuncBuilder, f: *const ast.Function, args: []const Expr, arg_names: []const ?[]const u8) bool {
    const positional_n = if (args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    }) args.len - 1 else args.len;
    for (args[0..positional_n], 0..) |*a, i| {
        // A named argument fills its declared parameter, not the slot at its
        // call-site position.
        const pi: usize = blk: {
            const nm = if (i < arg_names.len) arg_names[i] else null;
            const n = nm orelse break :blk i;
            for (f.params, 0..) |p, pj| {
                if (std.mem.eql(u8, p.name.name, n)) break :blk pj;
            }
            continue;
        };
        if (pi >= f.params.len) break;
        const ev = argDeclTypeRef(b, a) orelse continue;
        const ehead = std.mem.trimEnd(u8, ev.name, "?");
        const pname = f.params[pi].ty.name.name;
        const phead = std.mem.trimEnd(u8, pname, "?");
        if (std.mem.eql(u8, ehead, phead)) continue;
        // A top-type parameter accepts every argument, so evidence can never
        // disprove it.
        if (std.mem.eql(u8, phead, "Any")) continue;
        const e_builtin = paramLitKind(ehead);
        const p_builtin = paramLitKind(phead);
        // A known user class where a builtin kind is required, or the reverse, is
        // a definite mismatch.
        if (p_builtin != null and e_builtin == null and b.module.classId(ehead) != null) return true;
        if (p_builtin == null and e_builtin != null and b.module.classId(phead) != null and
            !classHasBoundedTypeParam(b, phead) and
            !typeNameIsParam(f, phead)) return true;
    }
    // A trailing lambda binds the last parameter, which a builtin-typed one cannot
    // take, so the overload whose last parameter is a function type is the target.
    if (positional_n + 1 == args.len and f.params.len > positional_n) {
        const lp = &f.params[f.params.len - 1].ty;
        if (lp.function == null and paramLitKind(std.mem.trimEnd(u8, lp.name.name, "?")) != null) return true;
    }
    return false;
}

/// Whether the class named `phead` declares a type parameter with a real,
/// non-`Any` upper bound. The registry records unbounded params under an `Any`
/// bound, so presence alone is not the signal.
fn classHasBoundedTypeParam(b: *FuncBuilder, phead: []const u8) bool {
    const key = if (std.mem.findScalar(u8, phead, '.') != null)
        phead
    else if (b.module.uniqueClassIdBySimpleName(phead)) |id|
        b.module.classes.items[id.int()].fqn
    else
        return false;
    const bounds = b.module.registry.class_type_param_bounds.get(key) orelse return false;
    for (bounds) |bd| {
        if (!std.mem.eql(u8, applicability.simpleName(bd.bound), "Any")) return true;
    }
    return false;
}

/// Whether `name` is one of `f`'s declared type parameters.
fn typeNameIsParam(f: *const ast.Function, name: []const u8) bool {
    for (f.type_params) |*tp| {
        if (std.mem.eql(u8, tp.name.name, name)) return true;
    }
    return false;
}

/// Shape fit for an evidence re-pick: every positional argument has a slot, a
/// trailing lambda has a last parameter to bind, and unfilled parameters default.
fn inlineShapeFits(f: *const ast.Function, args: []const Expr, shape: CallShape) bool {
    const has_trailing = shape.last_is_lambda;
    const positional_n = if (has_trailing and args.len > 0) args.len - 1 else args.len;
    if (f.params.len < args.len) return false;
    if (has_trailing and f.params.len == 0) return false;
    var i: usize = positional_n;
    const last = if (has_trailing) f.params.len - 1 else f.params.len;
    while (i < last) : (i += 1) {
        if (f.params[i].default == null) return false;
    }
    return true;
}

/// Whether the last argument is definitely an object instance rather than a
/// function value, so an inline overload wanting a lambda there is the wrong
/// target.
fn lastArgIsObjectNotFunction(b: *FuncBuilder, args: []const Expr) bool {
    if (args.len == 0) return false;
    switch (args[args.len - 1]) {
        .ObjectExpr => return true,
        .Path => |p| {
            if (p.segments.len != 1) return false;
            return b.isObjectInitLocal(p.segments[0].name);
        },
        else => return false,
    }
}

/// A body cheap enough to splice into every caller: an expression body or a short
/// block with no try machinery, whose splice drags finally and catch lowering into
/// each call site.
fn smallInlineBody(f: *const ast.Function) bool {
    const body = &(f.body orelse return false);
    switch (body.*) {
        .Expr => |*e| return !exprContainsTry(e),
        .Block => |*blk| {
            if (blk.stmts.len > 4) return false;
            for (blk.stmts) |*st| {
                const has_try = switch (st.*) {
                    .Expr => |*e| exprContainsTry(e),
                    .Assign => |asg| exprContainsTry(&asg.value),
                    .DestructuringDecl => |d| exprContainsTry(&d.init),
                    .Decl => |decl| switch (decl) {
                        .Property => |pr| if (pr.init) |*init| exprContainsTry(init) else false,
                        else => false,
                    },
                };
                if (has_try) return false;
            }
            return true;
        },
    }
}

fn exprContainsTry(e: *const Expr) bool {
    return switch (e.*) {
        .Try => true,
        .Lambda => |l| blk: {
            for (l.body.stmts) |*st| {
                if (st.* == .Expr and exprContainsTry(&st.Expr)) break :blk true;
            }
            break :blk false;
        },
        .Call => |c| blk: {
            if (exprContainsTry(c.callee)) break :blk true;
            for (c.args) |*a| {
                if (exprContainsTry(a)) break :blk true;
            }
            break :blk false;
        },
        .Member => |m| exprContainsTry(m.receiver),
        .Binary => |bi| exprContainsTry(bi.lhs) or exprContainsTry(bi.rhs),
        .Unary => |u| exprContainsTry(u.expr),
        .If => |iff| exprContainsTry(iff.cond) or exprContainsTry(iff.then_branch) or
            (if (iff.else_branch) |eb| exprContainsTry(eb) else false),
        else => false,
    };
}

fn anyReceiverFormedFnParam(f: *const ast.Function) bool {
    for (f.params) |*p| {
        if (p.ty.function) |ft| {
            if (ft.receiver != null) return true;
        }
    }
    return false;
}

pub fn anyCrossOrNoinlineParam(f: *const ast.Function) bool {
    for (f.params) |*p| {
        if (p.is_crossinline or p.is_noinline) return true;
    }
    return false;
}

/// Whether `f`'s body contains a `this` inside a nested lambda or anon-fun, which
/// may belong to a receiver-formed block invoked dynamically and would be captured
/// to the wrong receiver by a member-body splice.
fn bodyLambdaBindsThis(f: *const ast.Function) bool {
    const body = &(f.body orelse return false);
    return switch (body.*) {
        .Block => |*blk| thisScanStmts(blk.stmts, false),
        .Expr => |*e| thisScan(e, false),
    };
}

fn thisScanStmts(stmts: []const ast.Stmt, in_lambda: bool) bool {
    for (stmts) |*st| {
        const hit = switch (st.*) {
            .Expr => |*e| thisScan(e, in_lambda),
            .Assign => |asg| thisScan(&asg.target, in_lambda) or thisScan(&asg.value, in_lambda),
            .DestructuringDecl => |d| thisScan(&d.init, in_lambda),
            .Decl => |decl| switch (decl) {
                .Property => |pr| if (pr.init) |*init| thisScan(init, in_lambda) else false,
                else => false,
            },
        };
        if (hit) return true;
    }
    return false;
}

fn thisScanArgs(args: []const Expr, in_lambda: bool) bool {
    for (args) |*a| {
        if (thisScan(a, in_lambda)) return true;
    }
    return false;
}

fn thisScan(e: *const Expr, in_lambda: bool) bool {
    return switch (e.*) {
        .This => in_lambda,
        .Lambda => |l| thisScanStmts(l.body.stmts, true),
        .AnonFun => true,
        .ObjectExpr => true,
        .Member => |m| thisScan(m.receiver, in_lambda),
        .Unary => |u| thisScan(u.expr, in_lambda),
        .Postfix => |po| thisScan(po.expr, in_lambda),
        .Spread => |sp| thisScan(sp.expr, in_lambda),
        .Throw => |t| thisScan(t.value, in_lambda),
        .Labeled => |l| thisScan(l.expr, in_lambda),
        .As => |a| thisScan(a.expr, in_lambda),
        .IsCheck => |c| thisScan(c.expr, in_lambda),
        .MemberRef => |r| thisScan(r.receiver, in_lambda),
        .Return => |r| if (r.value) |v| thisScan(v, in_lambda) else false,
        .Call => |c| thisScan(c.callee, in_lambda) or thisScanArgs(c.args, in_lambda),
        .Index => |i| thisScan(i.receiver, in_lambda) or thisScanArgs(i.args, in_lambda),
        .Binary => |bin| thisScan(bin.lhs, in_lambda) or thisScan(bin.rhs, in_lambda),
        .If => |i| thisScan(i.cond, in_lambda) or thisScan(i.then_branch, in_lambda) or
            (if (i.else_branch) |eb| thisScan(eb, in_lambda) else false),
        .While => |w| thisScan(w.cond, in_lambda) or thisScan(w.body, in_lambda),
        .DoWhile => |dw| (if (dw.body) |db| thisScan(db, in_lambda) else false) or thisScan(dw.cond, in_lambda),
        .For => |fl| thisScan(fl.iter, in_lambda) or thisScan(fl.body, in_lambda),
        .Block => |blk| thisScanStmts(blk.stmts, in_lambda),
        .When => |w| (if (w.subject) |sub| thisScan(sub, in_lambda) else false) or blk: {
            for (w.branches) |*br| {
                if (thisScan(&br.body, in_lambda)) break :blk true;
            }
            break :blk false;
        },
        .StringTemplate => |t| blk: {
            for (t.parts) |*p| {
                if (p.* == .Interp) {
                    if (thisScan(p.Interp, in_lambda)) break :blk true;
                }
            }
            break :blk false;
        },
        .Try => |t| blk: {
            if (thisScanStmts(t.body.stmts, in_lambda)) break :blk true;
            for (t.catches) |*c| {
                if (thisScanStmts(c.body.stmts, in_lambda)) break :blk true;
            }
            if (t.finally) |fin| {
                if (thisScanStmts(fin.stmts, in_lambda)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn bareInlineNeedsSplice(b: *FuncBuilder, nm: []const u8, f: *const ast.Function, args: []const Expr) bool {
    return bareInlineNeedsSpliceT(b, nm, f, args, false);
}

pub fn bareInlineNeedsSpliceT(b: *FuncBuilder, nm: []const u8, f: *const ast.Function, args: []const Expr, has_explicit_type_args: bool) bool {
    const has_reified = anyReified(f.type_params);
    const want = args.len;
    const trailing_lambda = lastArgIsLambdaOrAnon(args);
    const inline_takes_fn = f.params.len != 0 and f.params[f.params.len - 1].ty.function != null;
    const drops_trailing_lambda = trailing_lambda and want >= 2;
    const a_func_fits = aFuncFits(b, nm, want);
    const shadowed_by_member = drops_trailing_lambda and inline_takes_fn and
        !a_func_fits and b.resolve(nm) == null and b.hasOwnMember(nm);
    const recv_mismatch = blk: {
        if (f.receiver_type) |rt| {
            const rn = rt.name.name;
            const in_extension_splice =
                b.lambda_splice_resolve == null and b.spliceRecvTy() != null;
            const owner_accepts = !in_extension_splice and
                (if (b.ownerClass()) |oc| b.module.classIsOrExtends(oc, rn) else false);
            const positive = if (inlineBodyRecvHead(b)) |cur|
                (!b.module.classIsOrExtends(cur, rn) and !owner_accepts)
            else
                false;
            const member_wins = !in_extension_splice and b.hasEnclosingMember(nm) and
                (if (b.ownerClass()) |oc| !std.mem.eql(u8, oc, rn) else false);
            break :blk positive or member_wins;
        }
        break :blk false;
    };
    // An inline member of a companion reached through the enclosing class's
    // hierarchy: member dispatch has no enclosing-supertype-companion walk, while
    // Kotlin resolves this statically.
    const companion_super_member = f.receiver_type == null and blk: {
        const owner = inline_state.inlineMemberOwner(f) orelse break :blk false;
        break :blk companionOwnerInEnclosingHierarchy(b, owner);
    };
    // A bare inline-extension call inside a class member body: `this` there is an
    // interpreted Instance, which the host binding could serve only by draining
    // the receiver per call. Ext-body contexts keep the host fast path.
    // Receiver-formed lambda params are excluded, since a nested splice would bind
    // the block's `this` to the outer member receiver.
    const rfs_on = inline_call.rfsEnabled();
    const member_body_ext = f.receiver_type != null and
        b.lambda_splice_resolve == null and b.spliceRecvTy() == null and
        b.recvTy() == null and b.ownerClass() != null and
        (rfs_on or !anyReceiverFormedFnParam(f)) and !bodyLambdaBindsThis(f) and
        !std.mem.eql(u8, runtime.envOnce("KLIO_MEMBER_EXT_SPLICE") orelse "1", "0");
    // Literal-lambda inline calls splice by default, as kotlinc does; `KLIO_LLP=0`
    // restores the framed route. Exclusions: a class-member callee, whose bare
    // member reads need the declaring class's `this`; receiver-formed lambda
    // params, whose nested receiver rebinding is not spliced; a lambda that
    // `return@<callee>`s its own label, which needs a real frame to unwind to;
    // and `crossinline`/`noinline` params, which embed the lambda in a closure.
    // Positional fit under Kotlin's trailing-lambda rule: the trailing lambda
    // binds the last param, leading args bind positionally, and the gap must be
    // default-filled. `f` is the name's inline pick, not a resolved overload, so
    // a call that does not fit stays on the dynamic path.
    const llp_arity_fits = want >= 1 and want <= f.params.len and blk: {
        for (f.params) |*p| {
            if (p.is_vararg) break :blk false;
        }
        var pi: usize = 0;
        while (pi + 1 < want) : (pi += 1) {
            // A lambda literal must land on a function-typed param: an arity match
            // alone can put it on a Comparator slot.
            const arg_is_lambda = args[pi] == .Lambda or args[pi] == .AnonFun;
            if (arg_is_lambda and f.params[pi].ty.function == null) break :blk false;
        }
        var gi: usize = want - 1;
        while (gi + 1 < f.params.len) : (gi += 1) {
            if (f.params[gi].default == null) break :blk false;
        }
        // Several same-shape inline candidates tie on shape alone and stay
        // dynamic. Receiver-ness separates plain `run` from `T.run`.
        if (inline_state.candidatesForName(nm)) |cands| {
            var fitting: usize = 0;
            for (cands) |cf| {
                if (cf.params.len != f.params.len) continue;
                if ((cf.receiver_type == null) != (f.receiver_type == null)) continue;
                // Only same-package candidates form a genuine overload set;
                // cross-pack namesakes are separated by scope, not types.
                if (cf != f and cf.name.span.file.int() != f.name.span.file.int()) {
                    const cf_pkg = b.module.packageOfFile(cf.name.span.file) orelse "";
                    const f_pkg = b.module.packageOfFile(f.name.span.file) orelse "";
                    if (!std.mem.eql(u8, cf_pkg, f_pkg)) continue;
                }
                fitting += 1;
            }
            if (fitting > 1) break :blk false;
        }
        break :blk true;
    };
    // A same-named member or in-scope binding can win by Kotlin's scope ranking,
    // which the dynamic path resolves, so the splice must not preempt it.
    const llp_unshadowed = !b.hasOwnMember(nm) and !b.hasEnclosingMember(nm) and
        b.resolve(nm) == null and !b.knowsOuter(nm);
    // A member-inline callee taking a lambda splices when the call sits in the
    // owner's hierarchy, where the splice window threads `this` and the owner
    // scope; outside it the dynamic path keeps its member ranking.
    const member_inline_lambda = inline_takes_fn and trailing_lambda and
        llp_arity_fits and rfs_on and
        b.resolve(nm) == null and
        !anyCrossOrNoinlineParam(f) and
        !inline_call.argLambdaTargetsLabel(args, nm) and
        // A cost gate, not a semantics gate: a plain member-inline is identical
        // framed or spliced, while splicing a large body into every hot caller
        // inflates frames past the no-fill mask. Small try-free bodies splice.
        smallInlineBody(f) and blk: {
        const owner = inline_state.inlineMemberOwner(f) orelse break :blk false;
        const enc = b.ownerClass() orelse break :blk false;
        const enc_host = hostClassOfCompanion(enc) orelse enc;
        const own_host = hostClassOfCompanion(owner) orelse owner;
        break :blk b.module.classIsOrExtends(enc_host, own_host);
    };
    const lambda_literal_plain = inline_takes_fn and trailing_lambda and
        llp_arity_fits and llp_unshadowed and
        inline_state.inlineMemberOwner(f) == null and
        (rfs_on or !anyReceiverFormedFnParam(f)) and
        !anyCrossOrNoinlineParam(f) and
        !inline_call.argLambdaTargetsLabel(args, nm) and
        !std.mem.eql(u8, runtime.envOnce("KLIO_LLP") orelse "1", "0");
    // Kotlin inlines every `inline fun`, so a no-lambda member inline otherwise
    // dispatches a full frame per call. Splice when the call is bare inside the
    // owner's hierarchy, positional args fit with a defaulted tail, and no local
    // shadows the name.
    const plain_inline_nolambda = !inline_takes_fn and !trailing_lambda and
        f.receiver_type == null and !f.is_suspend and
        b.resolve(nm) == null and blk: {
        // An explicit type argument on a non-reified inline carries element
        // knowledge the receiver proofs read off the call, which the splice drops.
        if (has_explicit_type_args and !anyReified(f.type_params)) break :blk false;
        // The splice stands in for overload resolution, so it engages only when
        // resolution is trivial: a lone candidate under the name. Committing by
        // name plus inline picks the sole inline overload over its non-inline
        // siblings, and the runtime rank that prefers the other never runs.
        if (b.module.funcsBySimpleName(nm).len != 1) break :blk false;
        for (f.params) |*p| {
            if (p.is_vararg) break :blk false;
        }
        if (want > f.params.len) break :blk false;
        var gi: usize = want;
        while (gi < f.params.len) : (gi += 1) {
            if (f.params[gi].default == null) break :blk false;
        }
        const owner = inline_state.inlineMemberOwner(f) orelse {
            // Top-level: only when unshadowed, mirroring the lambda tier.
            break :blk llp_unshadowed;
        };
        const enc = b.ownerClass() orelse break :blk false;
        const enc_host = hostClassOfCompanion(enc) orelse enc;
        const own_host = hostClassOfCompanion(owner) orelse owner;
        break :blk b.module.classIsOrExtends(enc_host, own_host);
    };
    if (runtime.envOnce("KLIO_EF_TRACE")) |efw| {
        if (std.mem.eql(u8, efw, nm)) {
            std.debug.print("[needs] {s} mismatch={} llp={} llp_unshadowed={} own={} encl={} resolve={} outer={} fits={} mil={} pin={}\n", .{
                nm,                         recv_mismatch,
                lambda_literal_plain,       llp_unshadowed,
                b.hasOwnMember(nm),         b.hasEnclosingMember(nm),
                b.resolve(nm) != null,      b.knowsOuter(nm),
                llp_arity_fits,             member_inline_lambda,
                plain_inline_nolambda,
            });
        }
    }
    return !recv_mismatch and
        (f.is_suspend or argLambdaHasNonlocalReturn(args) or
            inline_call.argsForwardInlineLambda(b, args) or has_reified or shadowed_by_member or
            companion_super_member or member_body_ext or lambda_literal_plain or
            member_inline_lambda or plain_inline_nolambda or
            inline_call.argLambdaMaySuspend(b, f, args));
}

/// True when `owner` names a companion object whose host class is the enclosing
/// class or an ancestor of it. Both sides reduce to their host class: a bare call
/// inside `Sub.Companion` or `Sub`'s body sees the companion members of `Sub`'s
/// superclasses, per Kotlin's static scope.
fn companionOwnerInEnclosingHierarchy(b: *FuncBuilder, owner: []const u8) bool {
    const o_host = hostClassOfCompanion(owner) orelse return false;
    const e = b.ownerClass() orelse return false;
    const e_host = hostClassOfCompanion(e) orelse e;
    return b.module.classIsOrExtends(e_host, o_host);
}

/// The class a `$Companion` mangle belongs to, or null when `name` is not one.
pub fn hostClassOfCompanion(name: []const u8) ?[]const u8 {
    const idx = std.mem.find(u8, name, "$Companion") orelse return null;
    if (idx == 0) return null;
    return name[0..idx];
}

/// Audit one inline-target resolution for `KLIO_RESOLVE_AUDIT`: the simple-name
/// narrowing's pick against the index-first pick, compared on the splice that
/// would actually occur, since a candidate failing the needs-splice gate never
/// splices. Two divergences are explained: `shape_correction`, where the index
/// resolves an exact-arity overload the inline-only simple-name table could not
/// offer, and `tier_correction`, where the index resolves in a strictly better
/// scope tier. Anything else is an interpreter bug; `KLIO_RESOLVE_STRICT` makes
/// it a hard failure.
fn inlineResolveAudit(
    b: *FuncBuilder,
    nm: []const u8,
    file: ir.FileId,
    narrowed: ?*const ast.Function,
    pick: ?*const ast.Function,
    args: []const Expr,
    last_is_lambda: bool,
    ires: ir.Module.BareCallResolution,
) void {
    const audit_on = resolveAuditOn();
    const strict_on = resolveStrictOn();
    if (!audit_on and !strict_on) return;
    const old_eff: ?*const ast.Function = if (narrowed) |f|
        (if (bareInlineNeedsSplice(b, nm, f, args)) f else null)
    else
        null;
    const new_eff: ?*const ast.Function = if (pick) |f|
        (if (bareInlineNeedsSplice(b, nm, f, args)) f else null)
    else
        null;
    const divergent = old_eff != new_eff;
    const tier_corrected = divergent and ires.pick() != null and old_eff != null and blk: {
        const old_id = inline_state.inlineIdByAst(old_eff.?) orelse break :blk false;
        const old_tier = b.module.bareCallTierOf(FuncId.from(old_id), nm, b.self_package, file) orelse break :blk false;
        break :blk ires.tier < old_tier;
    };
    const explained = divergent and ires.pick() != null and
        (old_eff == null or tier_corrected or astPickInexact(old_eff.?, args.len, last_is_lambda));
    if (audit_on) {
        const outcome: []const u8 = switch (ires.outcome) {
            .resolved => "resolved",
            .deferred => "deferred",
        };
        const reason: []const u8 = switch (ires.outcome) {
            .resolved => "-",
            .deferred => |r| @tagName(r),
        };
        const old_np: usize = if (narrowed) |f| f.params.len else 0;
        const new_np: usize = if (pick) |f| f.params.len else 0;
        std.debug.print(
            "[KLIO_RESOLVE_AUDIT] inline name={s} pkg={s} arity={d} outcome={s} reason={s} old={s}/{d} new={s}/{d} splice_old={d} splice_new={d} divergent={d} correction={d}\n",
            .{
                nm,                            b.self_package,                args.len,
                outcome,                       reason,                        inlineCandLabel(narrowed),
                old_np,                        inlineCandLabel(pick),         new_np,
                @intFromBool(old_eff != null), @intFromBool(new_eff != null), @intFromBool(divergent),
                @intFromBool(explained),
            },
        );
    }
    if (strict_on and divergent and !explained) {
        std.debug.panic(
            "KLIO_RESOLVE_STRICT: unexplained inline-target divergence on '{s}' (pkg='{s}' arity={d}): simple-name pick {s} vs index pick {s}",
            .{ nm, b.self_package, args.len, inlineCandLabel(old_eff), inlineCandLabel(new_eff) },
        );
    }
}

/// Whether `f`'s last parameter is function-typed, so it can host a trailing
/// lambda argument. A candidate failing this cannot be the target of a
/// `name(args) { … }` call, whose block would bind a scalar parameter.
fn astLastParamHostsLambda(f: *const ast.Function) bool {
    if (f.params.len == 0) return false;
    const last = f.params[f.params.len - 1];
    if (last.is_vararg) return false;
    return last.ty.function != null;
}

fn astPickInexact(f: *const ast.Function, want: usize, last_is_lambda: bool) bool {
    for (f.params) |p| {
        if (p.is_vararg) return true;
    }
    if (f.params.len != want) {
        const tl_fits = last_is_lambda and f.params.len != 0 and
            f.params[f.params.len - 1].ty.function != null and want >= 1 and
            f.params.len > want;
        if (!tl_fits) return true;
    }
    for (f.params) |p| {
        if (p.default != null) return true;
    }
    return false;
}

/// Audit label classifying an inline candidate's declaration shape; overloads
/// share the simple name, so receiver-ness, suspend-ness, and the printed
/// parameter count identify the declaration.
fn inlineCandLabel(f: ?*const ast.Function) []const u8 {
    const fp = f orelse return "-";
    if (fp.receiver_type != null) {
        return if (fp.is_suspend) "ext+suspend" else "ext";
    }
    return if (fp.is_suspend) "plain+suspend" else "plain";
}
