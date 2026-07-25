//! Inline-call lowering: expanding an `inline fun` body (and splicing its
//! lambda arguments) at the call site. Free functions over the shared
//! `FuncBuilder`; filled in alongside the expression dispatch.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr_lower = @import("expr.zig");
const inline_state = @import("inline_state.zig");
const ast_scan = @import("ast_scan.zig");
const helpers = @import("helpers.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const TypeRef = ast.TypeRef;
const Function = ast.Function;
const Reg = ir.Reg;
const Const = ir.Const;
const Inst = ir.Inst;
const Terminator = ir.Terminator;
const InlineReturn = build.InlineReturn;
const CallShape = inline_state.CallShape;

const lowerExpr = expr_lower.lowerExpr;
const lowerBlock = expr_lower.lowerBlock;

/// Best-effort static type of a member call's receiver, used only to
/// disambiguate same-name reified inline extensions declared on different
/// receiver types. Handles the cases the ktor client surface needs:
/// an implicit/explicit `this` (the enclosing extension's receiver type),
/// and a chained call `recv.foo().bar()` (the inner call's declared return
/// type, looked up from a same-named non-extension function). Returns
/// `null` when the type can't be inferred cheaply — the caller then falls
/// back to shape-based overload resolution.
pub fn inferReceiverType(b: *const FuncBuilder, this_arg: ?*const Expr) Allocator.Error!?[]const u8 {
    const arg = this_arg orelse return b.recvTy();
    switch (arg.*) {
        .This, .Super => return b.recvTy(),
        .Call => |call| {
            // `recv.method(...)` — use the called function's declared return
            // type. Resolve by simple name against the lowered module's
            // functions, preferring a unique return type among candidates.
            const name = switch (call.callee.*) {
                .Member => |m| m.name.name,
                .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
                else => return null,
            };
            // Tally concrete return types across the same-name overloads
            // and pick the most common one. A bare generic type parameter
            // (`V`/`T`), `Unit`, and the untyped case carry no information
            // and are ignored, so an operator `kotlin.collections.get(key):
            // V` neither vetoes nor competes with the ktor `get(...):
            // HttpResponse` extensions. The dominant concrete return wins;
            // an exact tie between two different concrete types is left
            // unresolved (`null`) so the caller keeps shape-based fallback.
            var tally = std.StringHashMap(usize).init(b.allocator);
            defer tally.deinit();
            for (b.module.funcsBySimpleName(name)) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                const rt = f.return_ty.name;
                const is_type_param = rt.len <= 2 and allAsciiUppercase(rt);
                if (rt.len == 0 or std.mem.eql(u8, rt, "Unit") or is_type_param) {
                    continue;
                }
                const gop = try tally.getOrPut(rt);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            var best: ?[]const u8 = null;
            var best_n: usize = 0;
            var tie = false;
            var it = tally.iterator();
            while (it.next()) |entry| {
                const ty = entry.key_ptr.*;
                const n = entry.value_ptr.*;
                if (best == null) {
                    best = ty;
                    best_n = n;
                } else if (n > best_n) {
                    best = ty;
                    best_n = n;
                    tie = false;
                } else if (n == best_n) {
                    tie = true;
                }
            }
            if (tie) return null;
            return best;
        },
        // A plain local: its declared annotation, or the inferred type of
        // its recorded initializer (`val resp = client.get(url)` makes
        // `resp.body<T>()` narrow to the `HttpResponse` overload).
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const name = p.segments[0].name;
            if (b.localDeclType(name)) |t| return t;
            if (b.localInitExpr(name)) |e| return inferReceiverType(b, e);
            // Typeck fills the receiver head only when lexical declaration and
            // initializer evidence could not carry it into the nested body.
            if (b.module.eagerTypeOf(arg.span())) |t| return t.name;
            // A bare name that is not a local is a member of the enclosing
            // class, whose declared type is receiver evidence just as a
            // local's is. Without it a reified inline extension called on a
            // property receiver had NO receiver type, so its declaration was
            // never found and the splice bailed to a plain member dispatch —
            // where the reified `T` has nothing to bind to
            // (`modifierNode.dispatchForKind(Nodes.PointerInput) { … }` inside
            // `HitPathTracker.Node`).
            if (ownerMemberDeclType(b, name)) |t| return t;
            // A bare name that is neither a local nor a member names a TYPE:
            // an `object`, or a class reached through its companion
            // (`Json.decodeFromString<User>(s)` — the receiver is
            // `Json.Default`, a `Json`). The name IS the receiver's type head,
            // and it is the only evidence that can separate an extension
            // overload set spread over several receivers
            // (`Json.decodeFromString` next to `StringFormat.decodeFromString`).
            // Without it the splice declined and the reified `T` reached the
            // runtime unbound, where `T::class` reads an unresolved global.
            if (b.resolve(name) == null and !b.knowsOuter(name) and
                b.module.classId(name) != null) return name;
            return null;
        },
        else => return null,
    }
}

/// The declared type head of member `name` on the enclosing class, searching
/// the class and then its transitive supertypes: a primary-constructor `val`
/// (`class Node(val modifierNode: Modifier.Node)`) or a body property. Null
/// when no enclosing class declares the name.
fn ownerMemberDeclType(b: *const FuncBuilder, name: []const u8) ?[]const u8 {
    const owner = b.ownerClass() orelse return null;
    var seen: [16][]const u8 = undefined;
    var n_seen: usize = 0;
    var queue: [16][]const u8 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    queue[tail] = owner;
    tail += 1;
    while (head < tail) {
        const cur = queue[head];
        head += 1;
        var dup = false;
        for (seen[0..n_seen]) |s| {
            if (std.mem.eql(u8, s, cur)) dup = true;
        }
        if (dup) continue;
        if (n_seen < seen.len) {
            seen[n_seen] = cur;
            n_seen += 1;
        }
        if (b.module.classId(cur)) |cid| {
            if (@intFromEnum(cid) < b.module.classes.items.len) {
                const c = &b.module.classes.items[@intFromEnum(cid)];
                for (c.primary_params) |*pp| {
                    if (std.mem.eql(u8, pp.name, name) and pp.ty.name.len != 0) return pp.ty.name;
                }
            }
        }
        if (inline_state.memberPropAst(cur, name)) |prop| {
            if (prop.ty) |*t| {
                if (t.name.name.len != 0) return t.name.name;
            }
        }
        if (b.module.registry.class_super_names.get(cur)) |sups| {
            for (sups) |s| {
                if (tail < queue.len) {
                    queue[tail] = s;
                    tail += 1;
                }
            }
        }
    }
    return null;
}

fn allAsciiUppercase(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Does any argument that is a lambda literal contain a non-local
/// `return` in its own body (not descending into nested lambdas /
/// local functions, whose returns are their own)?
pub fn argLambdaHasNonlocalReturn(args: []const Expr) bool {
    for (args) |*a| {
        if (a.* == .Lambda) {
            if (scanStmts(a.Lambda.body.stmts)) return true;
        }
    }
    return false;
}

/// Recover the original literal when an inline body forwards one of its
/// lambda parameters to another inline call. The forwarding expression is a
/// plain path in the callee body, but Kotlin keeps the original lambda inline
/// through the entire chain.
pub fn forwardedInlineLambda(b: *const FuncBuilder, arg: *const Expr) ?*const Expr {
    if (arg.* != .Path or arg.Path.segments.len != 1) return null;
    return b.inlineLambdaFor(arg.Path.segments[0].name);
}

pub fn argsForwardInlineLambda(b: *const FuncBuilder, args: []const Expr) bool {
    for (args) |*arg| {
        if (forwardedInlineLambda(b, arg) != null) return true;
    }
    return false;
}

fn scanStmts(stmts: []const Stmt) bool {
    for (stmts) |*s| {
        const hit = switch (s.*) {
            .Expr => |*e| scan(e),
            .Assign => |asg| scan(&asg.target) or scan(&asg.value),
            .DestructuringDecl => |d| scan(&d.init),
            .Decl => |decl| switch (decl) {
                .Property => |p| if (p.init) |*init| scan(init) else false,
                else => false,
            },
        };
        if (hit) return true;
    }
    return false;
}

// A non-local return inside a nested scope (lambda / anon fun / object
// expression) is its own and must not count here; those arms return
// false, kept distinct from the catch-all default.
fn scan(e: *const Expr) bool {
    return switch (e.*) {
        .Return => true,
        .Lambda, .AnonFun, .ObjectExpr => false,
        .Member => |m| scan(m.receiver),
        .Unary => |u| scan(u.expr),
        .Postfix => |p| scan(p.expr),
        .Spread => |s| scan(s.expr),
        .Throw => |t| scan(t.value),
        .Labeled => |l| scan(l.expr),
        .As => |a| scan(a.expr),
        .IsCheck => |c| scan(c.expr),
        .MemberRef => |r| scan(r.receiver),
        .Call => |c| scan(c.callee) or scanArgs(c.args),
        .Index => |i| scan(i.receiver) or scanArgs(i.args),
        .Binary => |bin| scan(bin.lhs) or scan(bin.rhs),
        .If => |i| scan(i.cond) or scan(i.then_branch) or
            (if (i.else_branch) |eb| scan(eb) else false),
        .While => |w| scan(w.cond) or scan(w.body),
        .DoWhile => |dw| (if (dw.body) |body| scan(body) else false) or scan(dw.cond),
        .For => |f| scan(f.iter) or scan(f.body),
        .Block => |blk| scanStmts(blk.stmts),
        .When => |w| (if (w.subject) |sub| scan(sub) else false) or scanWhenBranches(w.branches),
        .Try => |t| scanStmts(t.body.stmts) or scanCatches(t.catches) or
            (if (t.finally) |fb| scanStmts(fb.stmts) else false),
        else => false,
    };
}

fn scanArgs(args: []const Expr) bool {
    for (args) |*a| {
        if (scan(a)) return true;
    }
    return false;
}

fn scanWhenBranches(branches: []const ast.WhenBranch) bool {
    for (branches) |*br| {
        if (scan(&br.body)) return true;
    }
    return false;
}

fn scanCatches(catches: []const ast.Catch) bool {
    for (catches) |*c| {
        if (scanStmts(c.body.stmts)) return true;
    }
    return false;
}

/// Splice an `inline fun` argument lambda where the inlined body
/// invokes the corresponding lambda parameter.
pub fn spliceInlineLambda(
    b: *FuncBuilder,
    lambda_name: []const u8,
    lam: *const Expr,
    arg_exprs: []const Expr,
) Allocator.Error!Reg {
    if (lam.* != .Lambda) {
        return lowerExpr(b, lam);
    }
    const params = lam.Lambda.params;
    const body = lam.Lambda.body;
    const receiver = if (b.isReceiverLambdaParam(lambda_name))
        b.resolve("this")
    else
        null;

    const arg_regs = try b.allocator.alloc(Reg, arg_exprs.len);
    defer b.allocator.free(arg_regs);
    for (arg_exprs, 0..) |*a, i| {
        arg_regs[i] = try lowerExpr(b, a);
    }
    // The lambda being spliced was defined in the inline call's caller
    // scope, so its free names must resolve there — not against the
    // inline fn's parameter scope, whose names would shadow a same-named
    // caller variable the lambda body references. The caller depth was
    // recorded on the current inline-lambda frame at the call site.
    const splice_caller_depth = b.inlineLambdaCallerDepth();
    const counted = inline_state.inlineExpandEnter();
    try b.pushScope();
    const lambda_own_base = b.scopeDepth() - 1;
    if (receiver) |reg| try b.bind("this", reg);
    if (params.len == 0) {
        if (arg_regs.len > 0) {
            try b.bind("it", arg_regs[0]);
        }
    } else {
        const n = @min(params.len, arg_regs.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try b.bind(params[i].name, arg_regs[i]);
        }
    }
    // Capture the owner splice's localize target *before* pushing the new
    // frame, then duplicate it so restoring does not alias the frame's
    // own snapshot (which the frame frees on pop).
    const owner_ret: ?[]InlineReturn = if (b.inlineLambdaOwnerReturn()) |o|
        try b.allocator.dupe(InlineReturn, o)
    else
        null;
    try b.pushInlineLambdaFrame(std.StringHashMap(*const ast.Expr).init(b.allocator), b.scopeDepth());
    const saved = try b.takeInlineReturn();
    if (owner_ret) |o| {
        try b.restoreInlineReturn(o);
    }
    const result = b.allocReg();
    const unit0 = try b.emitConst(Const.Unit);
    try b.push(.{ .Move = .{ .dst = result, .src = unit0 } });
    const end = try b.allocBlock();
    const label = b.currentInlineFn();
    if (label) |lbl| {
        try b.pushInlineLambdaRet(lbl, result, end);
    }
    // Resolve the lambda body's free names against the caller scopes
    // plus the lambda's own scopes, skipping the inline fn's parameter
    // scopes in between.
    const prev_splice = b.lambda_splice_resolve;
    if (splice_caller_depth) |d| b.lambda_splice_resolve = .{ .caller_depth = d, .own_base = lambda_own_base };
    const v = try lowerBlock(b, &body);
    b.lambda_splice_resolve = prev_splice;
    try b.push(.{ .Move = .{ .dst = result, .src = v } });
    b.terminate(.{ .Goto = end });
    b.switchTo(end);
    if (label != null) {
        b.popInlineLambdaRet();
    }
    try b.restoreInlineReturn(saved);
    b.popInlineLambdaFrame();
    try b.popScope();
    if (counted) {
        inline_state.inlineExpandLeave();
    }
    return result;
}

/// Build the effective per-type-parameter argument list for an inline
/// call: each explicit `<…>` argument is kept; any reified parameter
/// left unspecified is inferred by unifying the function's declared
/// return type with the call's expected (tail-position) type. Non-reified
/// parameters and parameters that cannot be inferred stay `null`.
fn inferReifiedTypeArgs(
    allocator: Allocator,
    f: *const Function,
    explicit: []const TypeRef,
    expected: ?*const TypeRef,
    ordered: []const ?*const Expr,
    bb: ?*const FuncBuilder,
) Allocator.Error![]?TypeRef {
    var out = try allocator.alloc(?TypeRef, f.type_params.len);
    for (f.type_params, 0..) |_, i| {
        out[i] = if (i < explicit.len) explicit[i] else null;
    }
    var needs_infer = false;
    for (f.type_params, 0..) |tp, i| {
        if (tp.is_reified and out[i] == null) {
            needs_infer = true;
            break;
        }
    }
    if (!needs_infer) return out;

    var tp_names = std.StringHashMap(void).init(allocator);
    defer tp_names.deinit();
    for (f.type_params) |tp| {
        try tp_names.put(tp.name.name, {});
    }
    var subst = std.StringHashMap(TypeRef).init(allocator);
    defer subst.deinit();

    // Unify each declared value-parameter type against its actual argument.
    // A reified `T` that appears only in a parameter position — including
    // inside a function-typed parameter `block: (T) -> R`, solved from the
    // lambda literal's parameter annotations (`{ s: String -> … }`) — is
    // inferred here, before the return-type fallback below.
    for (f.params, 0..) |*p, i| {
        if (i >= ordered.len) break;
        const arg = ordered[i] orelse continue;
        try unifyParamAgainstArg(allocator, &p.ty, arg, &tp_names, &subst, bb);
    }

    // Fallback: unify the declared return type against the call's expected
    // (tail-position) type, so `val u: User = resp.body()` binds `T = User`
    // with no explicit `<User>`.
    if (expected) |exp| {
        if (f.return_type) |*ret| {
            try unifyTypeParam(ret, exp, &tp_names, &subst);
        }
    }

    for (f.type_params, 0..) |tp, i| {
        if (out[i] == null) {
            if (subst.get(tp.name.name)) |t| {
                out[i] = t;
            }
        }
    }
    return out;
}

/// Whether a member call to inline extension `name` with these value
/// arguments can bind EVERY reified type parameter by inference alone (no
/// explicit `<…>`, no expected type) — the gate for splicing a reified
/// inline extension in statement position, where `drawNode.dispatchForKind(
/// Nodes.Draw) { … }` must splice so `is T` checks the argument's real
/// generic type instead of dispatching at runtime with `T` unbound.
pub fn argsBindAllReified(allocator: Allocator, name: []const u8, args: []const Expr, bb: ?*const FuncBuilder) bool {
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const trailing_arity: ?usize = if (args.len == 0) null else switch (args[args.len - 1]) {
        .Lambda => |l| if (l.implicit_it) 0 else l.params.len,
        .AnonFun => |af| af.params.len,
        else => null,
    };
    const shape = CallShape{ .want = args.len, .last_is_lambda = last_is_lambda, .trailing_lambda_arity = trailing_arity };
    // Scan the full candidate set: the stub-index pick is blind to
    // MEMBER-inline overloads (`NodeCoordinator.visitNodes(type, block)`
    // next to its `(mask, block)` sibling), and the receiver-blind shape
    // pick cannot separate them — a candidate qualifies when it takes a
    // receiver (extension or member), declares a reified parameter, and
    // the value arguments bind every one of them.
    var single_buf: [1]*const ast.Function = undefined;
    // The enclosing extension's declared receiver is receiver evidence for
    // the extensions-only decline in `inlineFnAstForRecvExt` (a bare
    // `filterIsInstance<T>()` inside `List<*>.countOf()` must stay
    // spliceable, or the reified argument is lost to the runtime walk).
    var chain_buf: [1][]const u8 = undefined;
    const recv_chain: ?[]const []const u8 = blk: {
        const b2 = bb orelse break :blk null;
        const rt = b2.recvTy() orelse b2.spliceRecvTy() orelse break :blk null;
        chain_buf[0] = rt;
        break :blk chain_buf[0..1];
    };
    const cands: []const *const ast.Function = inline_state.candidatesForName(name) orelse blk: {
        const f = inline_state.inlineFnAstForRecvExt(name, shape, recv_chain, true) orelse return false;
        single_buf[0] = f;
        break :blk single_buf[0..1];
    };
    for (cands) |f| {
        if (f.receiver_type == null and inline_state.inlineMemberOwner(f) == null) continue;
        var any_reified = false;
        for (f.type_params) |tp| {
            if (tp.is_reified) any_reified = true;
        }
        if (!any_reified) continue;
        const ordered = allocator.alloc(?*const Expr, f.params.len) catch return false;
        defer allocator.free(ordered);
        for (ordered, 0..) |*slot, i| slot.* = if (i < args.len) &args[i] else null;
        const probe = inferReifiedTypeArgs(allocator, f, &.{}, null, ordered, bb) catch return false;
        defer allocator.free(probe);
        var all_bound = true;
        for (f.type_params, 0..) |tp, i| {
            if (tp.is_reified and probe[i] == null) all_bound = false;
        }
        if (all_bound) return true;
    }
    return false;
}

/// Unify one declared value-parameter type against its actual argument
/// expression, recording any reified type-parameter solutions in `subst`.
/// A function-typed parameter `(P…) -> R` unifies each declared parameter
/// type against the lambda literal's corresponding annotation, so a reified
/// `T` carried only by a lambda parameter is solved from `{ s: String -> … }`.
/// A generic-class parameter (`kind: NodeKind<T>`) unifies against the
/// argument's statically evident generic type — a constructor call with
/// explicit call-site type args, or a property access whose declared type /
/// accessor return type / expression body carries them (`Nodes.Draw` ->
/// `NodeKind<DrawModifierNode>`), solving `T` so `is T` in the spliced body
/// checks the real class.
fn unifyParamAgainstArg(
    allocator: Allocator,
    param_ty: *const TypeRef,
    arg: *const Expr,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
    bb: ?*const FuncBuilder,
) Allocator.Error!void {
    // An argument naming an enclosing splice's parameter carries that
    // parameter's declared type (with the enclosing reified substitution
    // already applied): `it.dispatchForKind(type, block)` inside a
    // spliced `visitNodes(type: NodeKind<T>, block: (T) -> Unit)` body
    // solves the nested call's `T` from `type`'s recorded type.
    if (arg.* == .Path and arg.Path.segments.len == 1) {
        if (bb) |b| {
            // Inside a spliced LAMBDA-ARGUMENT body the free names are the
            // CALLER's (`lambda_splice_resolve` window): the enclosing
            // splice's same-named parameter is a different binding, and
            // unifying against its declared type mis-binds the nested
            // reified parameter (the mask-overload's `block: (NodeB) ->
            // Unit` captured `T := NodeB` for the outer lambda's
            // `it.disp(type, block)`).
            const in_lambda_window = b.lambda_splice_resolve != null;
            if (!in_lambda_window) if (b.spliceParamTy(arg.Path.segments[0].name)) |aty| {
                if (param_ty.function) |pft| {
                    if (aty.function) |aft| {
                        const n = @min(pft.params.len, aft.params.len);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            try unifyTypeParam(&pft.params[i], &aft.params[i], tp_names, subst);
                        }
                        if (pft.receiver != null and aft.receiver != null) {
                            try unifyTypeParam(&pft.receiver.?, &aft.receiver.?, tp_names, subst);
                        }
                        try unifyTypeParam(&pft.ret, &aft.ret, tp_names, subst);
                    }
                } else {
                    try unifyTypeParam(param_ty, &aty, tp_names, subst);
                }
                return;
            };
        }
    }
    if (param_ty.function) |ft| {
        if (arg.* == .Lambda) {
            const lam = &arg.Lambda;
            const n = @min(ft.params.len, lam.param_tys.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (lam.param_tys[i]) |*pt| {
                    try unifyTypeParam(&ft.params[i], pt, tp_names, subst);
                }
            }
        }
        return;
    }
    if (param_ty.type_args.len != 0) {
        var mentions_tp = false;
        for (param_ty.type_args) |*ta| {
            if (!ta.is_star and tp_names.contains(ta.ty.name.name)) {
                mentions_tp = true;
                break;
            }
        }
        if (!mentions_tp) return;
        if (try argGenericTypeRef(allocator, arg, 0)) |aty| {
            try unifyTypeParam(param_ty, aty, tp_names, subst);
        }
    }
}

/// The argument expression's generic type, when statically evident:
/// a constructor/factory call with explicit `<…>` type args, or a
/// property access resolvable through the member-property AST registry.
/// Returns null when the type cannot be proven — inference stays
/// positive-proof only.
fn argGenericTypeRef(allocator: Allocator, arg: *const Expr, depth: usize) Allocator.Error!?*const TypeRef {
    if (depth > 4) return null;
    switch (arg.*) {
        .Call => |*c| {
            if (c.type_args.len == 0) return null;
            if (c.callee.* != .Path) return null;
            const segs = c.callee.Path.segments;
            if (segs.len == 0) return null;
            const head = segs[segs.len - 1];
            if (head.name.len == 0 or !std.ascii.isUpper(head.name[0])) return null;
            const targs = try allocator.alloc(ast.TypeArg, c.type_args.len);
            for (c.type_args, 0..) |ta, i| {
                targs[i] = .{ .variance = .Invariant, .is_star = false, .ty = ta, .span = ta.span };
            }
            const out = try allocator.create(TypeRef);
            out.* = .{
                .name = head,
                .nullable = false,
                .span = head.span,
                .type_args = targs,
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            };
            return out;
        },
        .Path => |*p| {
            if (p.segments.len < 2) return null;
            const owner = p.segments[p.segments.len - 2].name;
            const name = p.segments[p.segments.len - 1].name;
            return propGenericTypeRef(allocator, owner, name, depth);
        },
        .Member => |*m| {
            if (m.receiver.* != .Path) return null;
            const rs = m.receiver.Path.segments;
            if (rs.len == 0) return null;
            return propGenericTypeRef(allocator, rs[rs.len - 1].name, m.name.name, depth);
        },
        else => return null,
    }
}

/// Resolve property `owner.name`'s generic type through the registered
/// property AST: the declared type, the getter's return annotation, or —
/// for an expression-body accessor / initializer — the expression itself.
fn propGenericTypeRef(allocator: Allocator, owner: []const u8, name: []const u8, depth: usize) Allocator.Error!?*const TypeRef {
    const p = inline_state.memberPropAst(owner, name) orelse return null;
    if (p.ty) |*t| {
        if (t.type_args.len != 0) return t;
    }
    if (p.getter) |g| {
        if (g.return_type) |*rt| {
            if (rt.type_args.len != 0) return rt;
        }
        if (g.body == .Expr) return argGenericTypeRef(allocator, &g.body.Expr, depth + 1);
    }
    if (p.init) |*init| return argGenericTypeRef(allocator, init, depth + 1);
    return null;
}

/// Unify a declared type (which may mention type parameters) against a
/// concrete actual type, recording each type parameter's solution. When
/// the declared type *is* a bare type parameter, it binds to the whole
/// actual type; otherwise matching heads recurse positionally through
/// generic arguments (`Box<T>` vs `Box<Int>` solves `T = Int`).
fn unifyTypeParam(
    decl: *const TypeRef,
    actual: *const TypeRef,
    tp_names: *const std.StringHashMap(void),
    subst: *std.StringHashMap(TypeRef),
) Allocator.Error!void {
    if (decl.type_args.len == 0 and tp_names.contains(decl.name.name)) {
        if (!subst.contains(decl.name.name)) {
            try subst.put(decl.name.name, actual.*);
        }
        return;
    }
    const n = @min(decl.type_args.len, actual.type_args.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = &decl.type_args[i];
        const a = &actual.type_args[i];
        if (!d.is_star and !a.is_star) {
            try unifyTypeParam(&d.ty, &a.ty, tp_names, subst);
        }
    }
}

/// Add `ty`'s head name (and its generic arguments', recursively) to `out`.
fn putTypeRefNames(ty: *const TypeRef, out: *ast_scan.StringSet) Allocator.Error!void {
    try out.put(ty.name.name, {});
    for (ty.type_args) |*targ| {
        if (!targ.is_star) try putTypeRefNames(&targ.ty, out);
    }
    if (ty.function) |ft| {
        if (ft.receiver) |*r| try putTypeRefNames(r, out);
        for (ft.params) |*p| try putTypeRefNames(p, out);
        try putTypeRefNames(&ft.ret, out);
    }
}

/// Collect the type names a body resolves at runtime — `as T` / `is T`
/// targets, call-site type arguments, and `when` is-patterns — recursing
/// the same expression shapes `collectPathIdents` walks. Together the two
/// scans decide whether a reified inline extension's body ever reads a
/// reified parameter.
fn collectRuntimeTypeNames(e: *const Expr, out: *ast_scan.StringSet) Allocator.Error!void {
    switch (e.*) {
        .As => |u| {
            try putTypeRefNames(&u.ty, out);
            try collectRuntimeTypeNames(u.expr, out);
        },
        .IsCheck => |u| {
            try putTypeRefNames(&u.ty, out);
            try collectRuntimeTypeNames(u.expr, out);
        },
        .Call => |c| {
            for (c.type_args) |*ta| try putTypeRefNames(ta, out);
            try collectRuntimeTypeNames(c.callee, out);
            for (c.args) |*a| try collectRuntimeTypeNames(a, out);
        },
        .When => |w| {
            if (w.subject) |s| try collectRuntimeTypeNames(s, out);
            for (w.branches) |*br| {
                for (br.patterns) |*p| switch (p.kind) {
                    .IsType, .NotIsType => |ty| try putTypeRefNames(&ty, out),
                    .Value, .InRange, .NotInRange => |*ve| try collectRuntimeTypeNames(ve, out),
                    .Else => {},
                };
                try collectRuntimeTypeNames(&br.body, out);
            }
        },
        .Member => |m| try collectRuntimeTypeNames(m.receiver, out),
        .MemberRef => |m| try collectRuntimeTypeNames(m.receiver, out),
        .Index => |idx| {
            try collectRuntimeTypeNames(idx.receiver, out);
            for (idx.args) |*a| try collectRuntimeTypeNames(a, out);
        },
        .Binary => |bin| {
            try collectRuntimeTypeNames(bin.lhs, out);
            try collectRuntimeTypeNames(bin.rhs, out);
        },
        .Unary => |u| try collectRuntimeTypeNames(u.expr, out),
        .Postfix => |u| try collectRuntimeTypeNames(u.expr, out),
        .Spread => |u| try collectRuntimeTypeNames(u.expr, out),
        .Throw => |u| try collectRuntimeTypeNames(u.value, out),
        .Labeled => |u| try collectRuntimeTypeNames(u.expr, out),
        .If => |f| {
            try collectRuntimeTypeNames(f.cond, out);
            try collectRuntimeTypeNames(f.then_branch, out);
            if (f.else_branch) |els| try collectRuntimeTypeNames(els, out);
        },
        .While => |w| {
            try collectRuntimeTypeNames(w.cond, out);
            try collectRuntimeTypeNames(w.body, out);
        },
        .DoWhile => |w| {
            if (w.body) |b| try collectRuntimeTypeNames(b, out);
            try collectRuntimeTypeNames(w.cond, out);
        },
        .For => |f| {
            try collectRuntimeTypeNames(f.iter, out);
            try collectRuntimeTypeNames(f.body, out);
        },
        .Return => |r| {
            if (r.value) |v| try collectRuntimeTypeNames(v, out);
        },
        .Block => |b| {
            for (b.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
        },
        .Lambda => |l| {
            for (l.body.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
        },
        .AnonFun => |af| {
            if (af.body) |fb| switch (fb.*) {
                .Block => |b| {
                    for (b.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
                },
                .Expr => |*ex| try collectRuntimeTypeNames(ex, out),
            };
        },
        .Try => |t| {
            for (t.body.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
            for (t.catches) |*c| {
                try putTypeRefNames(&c.ty, out);
                for (c.body.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
            }
            if (t.finally) |fb| {
                for (fb.stmts) |*s| try collectRuntimeTypeNamesStmt(s, out);
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |*p| switch (p.*) {
                .Interp => |ex| try collectRuntimeTypeNames(ex, out),
                else => {},
            };
        },
        else => {},
    }
}

fn collectRuntimeTypeNamesStmt(s: *const Stmt, out: *ast_scan.StringSet) Allocator.Error!void {
    switch (s.*) {
        .Expr => |*e| try collectRuntimeTypeNames(e, out),
        .Assign => |a| {
            try collectRuntimeTypeNames(&a.target, out);
            try collectRuntimeTypeNames(&a.value, out);
        },
        .DestructuringDecl => |d| try collectRuntimeTypeNames(&d.init, out),
        .Decl => |d| switch (d) {
            .Property => |p| {
                if (p.init) |*e| try collectRuntimeTypeNames(e, out);
                if (p.delegate) |e| try collectRuntimeTypeNames(e, out);
            },
            .Function => |f| {
                if (f.body) |fb| switch (fb) {
                    .Block => |b| {
                        for (b.stmts) |*st2| try collectRuntimeTypeNamesStmt(st2, out);
                    },
                    .Expr => |*ex| try collectRuntimeTypeNames(ex, out),
                };
            },
            else => {},
        },
    }
}

/// Whether `f`'s body never references any of its reified type
/// parameters — neither as a bare name (`T::class` reads through the
/// `Path` head) nor in a runtime type position (`as T`, `is T`, a
/// call-site type argument, a `when` is-pattern, a catch type). Such a
/// body can splice with no binding for the reified parameter, which is
/// what a call with no explicit type arguments and no expected type
/// needs (`Json.encodeToString(value)` in a hook lambda).
pub fn reifiedParamsUnusedInBody(allocator: Allocator, f: *const Function) Allocator.Error!bool {
    var any_reified = false;
    for (f.type_params) |tp| {
        if (tp.is_reified) any_reified = true;
    }
    if (!any_reified) return true;
    const body = if (f.body) |*fb| fb else return false;
    var used = ast_scan.StringSet.init(allocator);
    defer used.deinit();
    switch (body.*) {
        .Expr => |*e| {
            try ast_scan.collectPathIdents(e, &used);
            try collectRuntimeTypeNames(e, &used);
        },
        .Block => |*blk| {
            for (blk.stmts) |*s| {
                try ast_scan.collectPathIdentsStmt(s, &used);
                try collectRuntimeTypeNamesStmt(s, &used);
            }
        },
    }
    for (f.type_params) |tp| {
        if (tp.is_reified and used.contains(tp.name.name)) return false;
    }
    return true;
}

fn inlineVarargFactory(elem: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, elem, "Byte")) return "byteArrayOf";
    if (eq(u8, elem, "Short")) return "shortArrayOf";
    if (eq(u8, elem, "Int")) return "intArrayOf";
    if (eq(u8, elem, "Long")) return "longArrayOf";
    if (eq(u8, elem, "Char")) return "charArrayOf";
    if (eq(u8, elem, "Boolean")) return "booleanArrayOf";
    if (eq(u8, elem, "Float")) return "floatArrayOf";
    if (eq(u8, elem, "Double")) return "doubleArrayOf";
    if (eq(u8, elem, "UByte")) return "ubyteArrayOf";
    if (eq(u8, elem, "UShort")) return "ushortArrayOf";
    if (eq(u8, elem, "UInt")) return "uintArrayOf";
    if (eq(u8, elem, "ULong")) return "ulongArrayOf";
    return "arrayOf";
}

/// Materialize the array value a vararg parameter denotes inside an inline
/// body. Keeping this as an ordinary factory call reuses the call spread path,
/// so `inlineFn(*values)` flattens the supplied array exactly once.
fn inlineVarargArrayExpr(
    b: *FuncBuilder,
    param: *const ast.Param,
    elems: []const Expr,
) Allocator.Error!*const Expr {
    const factory = inlineVarargFactory(param.ty.name.name);
    const segs = try b.allocator.alloc(ast.Ident, 1);
    segs[0] = .{ .name = factory, .span = param.span };
    const callee = try b.allocator.create(Expr);
    callee.* = .{ .Path = .{ .segments = segs, .span = param.span } };
    const copied = try b.allocator.dupe(Expr, elems);
    const out = try b.allocator.create(Expr);
    out.* = .{ .Call = .{
        .callee = callee,
        .args = copied,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = param.span,
    } };
    return out;
}

/// Expand a call to a `suspend inline fun` by splicing its body into
/// the caller. `type_args` carries the call-site `<T = SomeType>` for
/// reified type parameters so the splice can bind each reified
/// parameter's name to the resolved class value before lowering the
/// body — `T::class` and `is T` reads inside the spliced body then
/// resolve to the call site's type. `expected` carries the call's
/// tail-position type so a reified parameter with no explicit `<…>`
/// argument can be inferred from context.
/// The source file a call-site expression was written in, from its span:
/// visibility of a file-private inline candidate is judged against this.
fn callSiteFileOf(e: *const Expr) ?span.FileId {
    return switch (e.*) {
        .Path => |p| if (p.segments.len != 0) p.segments[0].span.file else null,
        .Member => |m| m.name.span.file,
        .Call => |c| callSiteFileOf(c.callee),
        .Lambda => |l| l.span.file,
        .This => |t| t.span.file,
        else => null,
    };
}

pub fn tryInlineCallWithTypeArgs(
    b: *FuncBuilder,
    fname: []const u8,
    target: ?*const ast.Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    this_arg: ?*const Expr,
    type_args: []const TypeRef,
    expected: ?*const TypeRef,
) Allocator.Error!?Reg {
    // A bare call arrives with its `target` already resolved (the
    // symbol index's pick, or the narrowing fallback for the shapes the
    // index defers on) so the splice expands exactly the declaration
    // the call binds. A member call (`recv.f(...)`, `this_arg` set)
    // resolves here by receiver/shape narrowing: the inline target must
    // be a receiver extension, never a same-named top-level overload.
    var f: *const ast.Function = undefined;
    if (target) |t| {
        f = t;
    } else {
        const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
            .Lambda, .AnonFun => true,
            else => false,
        };
        const trailing_arity: ?usize = if (args.len == 0) null else switch (args[args.len - 1]) {
            .Lambda => |l| if (l.implicit_it) 0 else l.params.len,
            .AnonFun => |af| af.params.len,
            else => null,
        };
        const call_shape = CallShape{
            .want = args.len,
            .last_is_lambda = last_is_lambda,
            .trailing_lambda_arity = trailing_arity,
            .call_file = if (this_arg) |ta| callSiteFileOf(ta) else null,
        };
        var recv_ty = try inferReceiverType(b, this_arg);
        // A BARE call inside an extension body has the enclosing
        // extension's declared receiver as its implicit receiver — that
        // is real evidence (`filterIsInstance<T>()` inside
        // `List<*>.countOf()` narrows on List), and without it the
        // extensions-only decline below would push a reified splice to
        // the runtime walk, losing the type argument.
        if (recv_ty == null and this_arg == null) recv_ty = b.recvTy();
        const recv_chain: ?[]const []const u8 = if (recv_ty) |r|
            try expr_lower.recvChainOf(b, r)
        else
            null;
        f = inline_state.inlineFnAstForRecvExt(
            fname,
            call_shape,
            recv_chain,
            this_arg != null,
        ) orelse return null;
    }
    if (b.inlineDeclInProgress(f)) {
        return null;
    }
    // `kotlin.reflect.typeOf<T>()` is a reified intrinsic: its source body
    // is a placeholder throw, and the runtime serves the call from the
    // reified type argument — never splice it.
    if (std.mem.eql(u8, fname, "typeOf") and f.params.len == 0 and
        f.type_params.len == 1 and f.type_params[0].is_reified)
    {
        if (f.return_type) |rt| {
            if (std.mem.endsWith(u8, rt.name.name, "KType")) return null;
        }
    }
    // Materialise the body if it is a deferred image marker before reading it.
    inline_state.ensureInlineBody(f);
    const body = if (f.body) |*body_ref| body_ref else return null;

    var ordered = try b.allocator.alloc(?*const Expr, f.params.len);
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    var vararg_value: ?*const Expr = null;
    // A trailing lambda fills the last parameter even when earlier
    // defaulted parameters are omitted (`assertFailsWith<T> { … }` skips
    // the defaulted `message` and binds the lambda to `block`). Mapping it
    // 1:1 from the front would land it on the first param and leave the
    // last (function-typed, no default) one unfilled, declining the splice.
    const last_is_trailing_lambda = args.len > 0 and
        (args.len > arg_names.len or arg_names[args.len - 1] == null) and
        switch (args[args.len - 1]) {
            .Lambda, .AnonFun => true,
            else => false,
        };
    const lambda_to_last = last_is_trailing_lambda and f.params.len > 0 and
        !f.params[f.params.len - 1].is_vararg;
    if (lambda_to_last) {
        ordered[f.params.len - 1] = &args[args.len - 1];
    }
    const positional_n = if (lambda_to_last) args.len - 1 else args.len;
    const vararg_idx: ?usize = blk: {
        for (f.params, 0..) |p, i| {
            if (p.is_vararg) break :blk i;
        }
        break :blk null;
    };
    if (vararg_idx) |vi| {
        // Parameters after a vararg can only be supplied by name, apart from
        // a trailing lambda. All remaining positional arguments are vararg
        // elements and are materialized into the array the inline body sees.
        var elem_start: usize = 0;
        while (elem_start < positional_n and elem_start < vi) : (elem_start += 1) {
            const nm: ?[]const u8 = if (elem_start < arg_names.len) arg_names[elem_start] else null;
            if (nm != null) break;
            ordered[elem_start] = &args[elem_start];
        }
        var elem_end = positional_n;
        for (args[elem_start..positional_n], elem_start..) |*a, ai| {
            const nm: ?[]const u8 = if (ai < arg_names.len) arg_names[ai] else null;
            if (nm) |name| {
                const idx = paramIndex(f, name) orelse return null;
                if (idx == vi) return null;
                ordered[idx] = a;
                elem_end = @min(elem_end, ai);
            }
        }
        const elems = args[elem_start..elem_end];
        if (elems.len != 0) ordered[vi] = &elems[0];
        vararg_value = try inlineVarargArrayExpr(b, &f.params[vi], elems);
    } else {
        var next_pos: usize = 0;
        for (args[0..positional_n], 0..) |*a, i| {
            const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (nm) |name| {
                const idx = paramIndex(f, name) orelse return null;
                ordered[idx] = a;
            } else {
                while (next_pos < ordered.len and ordered[next_pos] != null) {
                    next_pos += 1;
                }
                if (next_pos >= ordered.len) {
                    return null;
                }
                ordered[next_pos] = a;
                next_pos += 1;
            }
        }
    }
    for (ordered, 0..) |*slot, i| {
        if (slot.* == null) {
            if (f.params[i].is_vararg) {
                continue;
            } else if (f.params[i].default) |d| {
                slot.* = d;
            } else {
                return null;
            }
        }
    }

    // A reified parameter that stays unbound after explicit-argument,
    // expected-type, and callable-reference-argument inference must not
    // be one the body actually reads — splicing would leave `T::class` /
    // `is T` dangling. Decline the splice instead; the member-dispatch
    // fallback binds runtime type arguments. A body that never reads its
    // reified parameters (the `Json.encodeToString(value)` shape) splices
    // fine without a binding.
    {
        const probe = try inferReifiedTypeArgs(b.allocator, f, type_args, expected, ordered, b);
        defer b.allocator.free(probe);
        var unbound_reified = false;
        for (f.type_params, 0..) |tp, i| {
            if (!(tp.is_reified and probe[i] == null)) continue;
            if (callableRefParamFor(f, ordered, tp.name.name) != null) continue;
            unbound_reified = true;
        }
        if (unbound_reified and !(try reifiedParamsUnusedInBody(b.allocator, f))) return null;
    }

    if (!inline_state.inlineExpandEnter()) {
        return null;
    }
    errdefer inline_state.inlineExpandLeave();
    const member_splice = f.receiver_type == null and this_arg != null and
        inline_state.inlineMemberOwner(f) != null;
    const explicit_receiver = if ((f.receiver_type != null or member_splice) and
        this_arg != null)
        try lowerExpr(b, this_arg.?)
    else
        null;
    try b.pushInlineDecl(fname, f);
    // The spliced extension's declared receiver is receiver EVIDENCE for
    // the body's own inline gates (`filterIsInstance<T>()` inside
    // `List<*>.countOf()` must stay spliceable) — via the dedicated
    // splice channel, NOT `recv_ty`, so nested-lambda bare calls
    // (`collect { }` inside a flow operator body) keep resolving through
    // the runtime receiver walk instead of pinning to the innermost this.
    const prev_splice_recv = b.spliceRecvTy();
    if (f.receiver_type) |rt| b.setSpliceRecvTy(rt.name.name);
    defer b.setSpliceRecvTy(prev_splice_recv);
    // Scope depth before the inline fn binds its parameters: a lambda
    // argument spliced from this call resolves its free names in these
    // caller scopes, not against the inline fn's parameter scope.
    const caller_scope_depth = b.scopeDepth();
    try b.pushScope();
    // Precise captured-`var` carrier across the inline splice. The inline
    // body is lowered into THIS (the caller's) builder, so its own `var`
    // decls — and any inline parameter — that a nested closure inside the
    // body *writes* must be boxed into a shared `Value.Cell` here, exactly
    // as a captured `var` is at an ordinary lambda boundary. Without this
    // the body lowers the write through the `StoreGlobal`-for-capture
    // fallback, which only round-trips on the stdlib-HOF scoped env. Box
    // them so the write lowers to `CellSet` on the shared cell and is
    // visible on every closure-execution path. Names newly boxed here are
    // recorded and unboxed after the splice so the mark never leaks onto a
    // same-named caller local.
    var boxed_here: std.ArrayList([]const u8) = .empty;
    defer boxed_here.deinit(b.allocator);
    var splice_boxed = ast_scan.StringSet.init(b.allocator);
    defer splice_boxed.deinit();
    if (body.* == .Block) {
        // Body-declared `var`s captured-and-written by a nested closure.
        var body_boxed = try ast_scan.computeBoxedVars(b.allocator, body.Block.stmts);
        defer body_boxed.deinit();
        var bit = body_boxed.keyIterator();
        while (bit.next()) |k| try splice_boxed.put(k.*, {});
        // Inline parameters written by a nested closure in the body. A
        // parameter is not a body `var` decl, so `computeBoxedVars` does
        // not see it; collect mutation targets inside nested lambdas and
        // box any that name a parameter.
        var assigned = ast_scan.StringSet.init(b.allocator);
        defer assigned.deinit();
        try ast_scan.namesAssignedInLambdas(body.Block.stmts, &assigned);
        for (f.params) |*p| {
            if (assigned.contains(p.name.name)) try splice_boxed.put(p.name.name, {});
        }
    }
    var lambda_map = std.StringHashMap(*const ast.Expr).init(b.allocator);
    const arg_regs = try b.allocator.alloc(Reg, f.params.len);
    defer b.allocator.free(arg_regs);
    for (f.params, 0..) |*p, i| {
        const a = if (p.is_vararg) vararg_value.? else ordered[i].?;
        const forwarded_lambda = forwardedInlineLambda(b, a);
        // A numeric literal argument re-types to its declared primitive
        // parameter (kotlinc literal typing): `f(1)` for `f(x: Long)`
        // binds a `Long`, not an `Int`. The regular call path coerces in
        // `lowerArgRunFull`; the inline splice binds the lowered arg
        // directly, so apply the same coercion here. Without it the bound
        // value stays `Int` and any later `==`/`equals` against a `Long`
        // is a cross-type comparison that is always false.
        const coerced: ?Reg = if (p.ty.function == null and !p.ty.nullable)
            try helpers.coerceNumericLiteralArg(b, a, p.ty.name.name)
        else
            null;
        // A lambda argument bound to a declared function-typed param
        // takes its arity from the declaration — a zero-`->` lambda for
        // a `() -> R` param must NOT keep the parser's implicit `it`
        // (which would swallow the first invocation slot as Null).
        if ((a.* == .Lambda or a.* == .AnonFun) and p.ty.function != null) {
            b.pending_lambda_arity = @intCast(p.ty.function.?.params.len);
        }
        const r = coerced orelse try lowerExpr(b, a);
        b.pending_lambda_arity = -1;
        arg_regs[i] = r;
        // A lambda argument is spliced inline (its body is expanded at the
        // call site), so it is never a closure value to box — skip boxing
        // it even if a deeper nested lambda mentions the param name.
        const box_param = splice_boxed.contains(p.name.name) and a.* != .Lambda;
        if (box_param and !b.isBoxed(p.name.name)) {
            // Box the parameter into a shared cell. The scope-local `bind`
            // is enough for `boxedCellReg` to recover the cell (it falls to
            // `resolve` when no `mutable_home` is set), so the boxing mark
            // and binding live only inside the spliced scope and are torn
            // down with it — no flat `mutable_homes`/`mutables` entry leaks
            // onto a same-named caller local.
            const home = b.allocReg();
            try b.push(.{ .MakeCell = .{ .dst = home, .src = r } });
            try b.markBoxed(p.name.name);
            try b.bind(p.name.name, home);
            try boxed_here.append(b.allocator, p.name.name);
        } else {
            try b.bind(p.name.name, r);
        }
        // `noinline` parameters opt out of the inline-lambda splicing
        // path. Their argument value still flows through the binding
        // above, but a call to that parameter inside the inlined body
        // lowers as a normal CallValue against the reg instead of
        // inlining the lambda literal. Without this gate, every inline
        // call would splice every lambda argument's body — defeating
        // `noinline`'s point of letting the lambda be passed on or
        // stored.
        //
        // `crossinline` keeps the inline-lambda path, but a bare
        // `return` in the lambda body is illegal: the inlined body's
        // return targets the enclosing inline fn's caller, and
        // `crossinline` promises that the lambda will not perform such a
        // non-local return. Klio doesn't currently emit a parser-level
        // diagnostic for the violation; the runtime semantics still
        // match Kotlin.
        if (!p.is_noinline) {
            if (forwarded_lambda orelse (if (a.* == .Lambda) a else null)) |lam| {
                try lambda_map.put(p.name.name, lam);
            }
        }
    }
    // Mark params whose declared type is one of this inline fn's own
    // generic type-parameters, so a comparison operator on such an
    // operand inside the spliced body lowers to `compareTo` (total order
    // for Double/Float) — matching the reference compiler. The splice
    // binds the body in the caller's builder, so record which names we
    // add and remove them once the body is lowered to avoid leaking the
    // mark onto a same-named caller local.
    var marked_generic: std.ArrayList([]const u8) = .empty;
    defer marked_generic.deinit(b.allocator);
    if (f.type_params.len != 0) {
        var tp_names = std.StringHashMap(void).init(b.allocator);
        defer tp_names.deinit();
        for (f.type_params) |tp| {
            try tp_names.put(tp.name.name, {});
        }
        for (f.params) |*p| {
            if (p.ty.function == null and
                !p.ty.nullable and
                tp_names.contains(p.ty.name.name) and
                !b.isGenericTypedParam(p.name.name))
            {
                try b.markGenericTypedParam(p.name.name);
                try marked_generic.append(b.allocator, p.name.name);
            }
        }
    }
    // Mark params whose declared type is a receiver-typed function
    // (`block: T.() -> R`) so a bare `block(...)` in the spliced body
    // dispatches `this.block()`. Same record-and-remove discipline as
    // the generic marks above.
    var marked_rlp: std.ArrayList([]const u8) = .empty;
    defer marked_rlp.deinit(b.allocator);
    for (f.params) |*p| {
        const has_recv = if (p.ty.function) |ft| ft.receiver != null else false;
        if (has_recv and !b.isReceiverLambdaParam(p.name.name)) {
            try b.markReceiverLambdaParam(p.name.name);
            try marked_rlp.append(b.allocator, p.name.name);
        }
    }
    try b.pushInlineLambdaFrame(lambda_map, caller_scope_depth);
    // An inline extension splice's body resolves names against the inline
    // function's own parameter/receiver scopes, not the caller lambda's free
    // names. When this splice is itself nested inside a spliced
    // inline-argument lambda, that outer `lambda_splice_resolve` window skips
    // the very scopes this splice binds its `this`/params into — so a bare
    // member call in the body (`receiveNullable(...)` inside a spliced
    // `ApplicationCall.receive`) cannot see the bound receiver. After lowering
    // the receiver expression (which IS a caller free name and needs the
    // window), suspend the window so the extension body's own bindings resolve
    // normally; it is restored after the body.
    // A member-inline fn spliced through an EXPLICIT receiver
    // (`CC(e, a).pfw<E> { … }`, `coordinator.visitNodes(type) { … }`)
    // binds that receiver as the body's `this` exactly like a
    // receiver extension: the body's own member reads (`e.g()`) and its
    // nested reified calls resolve against it. Without the binding the
    // call fell to runtime member dispatch with the reified parameter
    // dead (`E::class` reading the `kotlin.math.E` global).
    const ext_splice = (f.receiver_type != null or member_splice) and this_arg != null;
    // The member body's bare sibling calls (`visitNodes(mask, include)`
    // inside `visitNodes(type, block)`, `headToTail(...)`) must lower as
    // member-shadowable dispatch on the bound `this`, exactly as the
    // declaration lowering scopes them: activate the owner class and its
    // hierarchy's member-name set for the splice.
    var member_scope_prev_owner: ?[]const u8 = null;
    var member_scope_prev_members: ?build.StringSet = null;
    if (member_splice) {
        const owner = inline_state.inlineMemberOwner(f).?;
        member_scope_prev_owner = b.owner_class;
        b.owner_class = owner;
        var merged = build.StringSet.init(b.allocator);
        var ok = true;
        {
            var it = b.enclosing_members.keyIterator();
            while (it.next()) |k| merged.put(k.*, {}) catch {
                ok = false;
                break;
            };
        }
        if (ok) {
            if (b.module.registry.hierarchy_methods.get(owner)) |methods| {
                var mit = methods.keyIterator();
                while (mit.next()) |k| merged.put(k.*, {}) catch {};
            }
            var prev = merged;
            std.mem.swap(build.StringSet, &prev, &b.enclosing_members);
            member_scope_prev_members = prev;
        } else {
            merged.deinit();
        }
    }
    defer if (member_splice) {
        b.owner_class = member_scope_prev_owner;
        if (member_scope_prev_members) |pm| {
            b.enclosing_members.deinit();
            b.enclosing_members = pm;
        }
    };
    var prev_splice_window: @TypeOf(b.lambda_splice_resolve) = null;
    if (explicit_receiver) |receiver| try b.bind("this", receiver);
    if (ext_splice) {
        prev_splice_window = b.lambda_splice_resolve;
        b.lambda_splice_resolve = null;
    }
    // Bind each reified type parameter to the resolved class value at the
    // call site. Two bindings are needed:
    //
    //   * Local: `T` resolves as a value (the spliced body's `T::class`
    //     read lowers as a bare `T` Path → MemberRef `.class`, the Path
    //     resolves through the local bind).
    //   * Global: `Inst::InstanceOf { ty: TypeRef "T" }` checks the value
    //     against the global named "T" (mirroring how `call_func_typed`
    //     binds runtime type-args). Without the global, `x is T` would
    //     test against a non-existent class `T` and silently fall through
    //     to `true`.
    //
    // The global isn't saved/restored — same shape klio uses for type-arg
    // binding in non-inline calls. A nested splice overwrites it; a later
    // restore happens implicitly when the enclosing call returns.
    // Explicit `<…>` type arguments win; any reified parameter left
    // unspecified is inferred by unifying the function's declared return
    // type against the call's expected (tail-position) type, so
    // `val u: User = resp.body()` binds `T = User` with no `<User>`.
    const effective_type_args = try inferReifiedTypeArgs(b.allocator, f, type_args, expected, ordered, b);
    defer b.allocator.free(effective_type_args);
    const ReifiedRestore = struct { name: []const u8, prev: ?Reg };
    var reified_restores: std.ArrayList(ReifiedRestore) = .empty;
    defer reified_restores.deinit(b.allocator);
    // NAME substitutions for the splice's reified params (`T` -> `E`),
    // consumed by `emitCall`/`emitExtBareCall` to stamp static type args
    // onto nested calls in the spliced body — the body's
    // `enumEntriesIntrinsic()` otherwise reaches the runtime with no type
    // information at all.
    const NameRestore = struct { name: []const u8, prev: ?[]const u8 };
    var reified_name_restores: std.ArrayList(NameRestore) = .empty;
    defer reified_name_restores.deinit(b.allocator);
    defer for (reified_name_restores.items) |nr| b.restoreReifiedTypeName(nr.name, nr.prev);
    for (f.type_params, 0..) |tp, tp_idx| {
        if (!tp.is_reified) continue;
        const arg = if (tp_idx < effective_type_args.len) effective_type_args[tp_idx] else null;
        var cls_reg_opt: ?Reg = null;
        if (arg) |a| {
            // The stamped name resolves through the scope rename too: a
            // mangled nested class (`enumEntries<Item>()` where `Item`
            // lifted as `A$Item`) must reach the runtime as the lifted
            // name the class table actually holds.
            const substituted = b.resolveReifiedTypeName(a.name.name) orelse
                reifiedQualifiedName(b, a) orelse
                (expr_lower.scopeTypeRename(b, a.name.name, a.name.span.file.int()) orelse a.name.name);
            const nprev = try b.bindReifiedTypeName(tp.name.name, substituted);
            try reified_name_restores.append(b.allocator, .{ .name = tp.name.name, .prev = nprev });
        }
        if (arg) |a| {
            // A type argument naming an *enclosing splice's* reified
            // parameter chains lexically: `trySuspend<TaskType>(...)`
            // inside a spliced `sleepWhile<reified TaskType>` body reuses
            // the class value the outer splice already resolved.
            if (b.resolveReifiedType(a.name.name)) |reg| {
                cls_reg_opt = reg;
            } else {
                const cls_reg = b.allocReg();
                // A private / file-local nested class is lifted under a mangled
                // name; resolve the type-arg name through the scope rename (the
                // same path `Nested(args)` construction takes) so a reified
                // `<PrivateNested>` binds its class instead of an unresolved
                // global of the source name.
                //
                // A FUNCTION-TYPE argument (`mutableVectorOf<() -> Unit>()`) has
                // the synthetic name `<function>`, which is not a global — and
                // Kotlin erases function types under reification anyway (a
                // reified `() -> Unit` reifies as `Function0`, not a distinct
                // class). Bind it to `Any` so the reified use (array creation,
                // membership) resolves rather than loading an unresolved global.
                const resolved_name = if (a.function != null)
                    "Any"
                else
                    reifiedQualifiedName(b, a) orelse
                        (expr_lower.scopeTypeRename(b, a.name.name, a.name.span.file.int()) orelse a.name.name);
                const arg_name = try b.module.internConst(b.allocator, .{ .String = resolved_name });
                // Carry the resolved class identity so a builtin/stdlib type
                // whose bare name otherwise resolves to a constructor
                // intrinsic (an exception class) binds the `.Class` value
                // instead, matching how a concrete `Type::class` receiver
                // lowers. Without it `T::class` for such a type yields the
                // intrinsic and member dispatch (`isInstance`) misses.
                const idx_pick = b.module.classIdIndexed(resolved_name, b.self_package, a.name.span.file);
                const flat_pick = b.module.classId(resolved_name);
                const cls_pick: ?ir.ClassId = idx_pick orelse flat_pick;
                // Constructor-ref semantics: a reified type argument binds the
                // CLASS value, so a type that declares a `companion object`
                // yields the class (its `T::class`), not the published
                // companion singleton (which would degrade to
                // `T$Companion$Companion` after the companion is built).
                try b.push(.{ .LoadGlobal = .{ .dst = cls_reg, .name = arg_name, .class = cls_pick, .ctor_ref = true } });
                cls_reg_opt = cls_reg;
            }
        } else if (callableRefParamFor(f, ordered, tp.name.name)) |pi| {
            // Inferred from a constructor-reference argument
            // (`sleepWhile(Slot::Read)` solves `TaskType = Slot.Read`
            // from `createTask: (Continuation<Unit>) -> TaskType`): the
            // lowered reference IS the class value, so bind it directly.
            cls_reg_opt = arg_regs[pi];
        }
        const cls_reg = cls_reg_opt orelse continue;
        try b.bind(tp.name.name, cls_reg);
        const tp_global = try b.module.internConst(b.allocator, .{ .String = tp.name.name });
        try b.push(.{ .StoreGlobal = .{ .name = tp_global, .value = cls_reg } });
        const prev = try b.bindReifiedType(tp.name.name, cls_reg);
        try reified_restores.append(b.allocator, .{ .name = tp.name.name, .prev = prev });
    }
    // Record each parameter's declared type (with this splice's reified
    // substitutions applied) so a nested reified inline call in the body
    // that passes these parameters along can solve its own type
    // parameters lexically.
    const SpRestore = struct { name: []const u8, prev: ?ast.TypeRef };
    var splice_ty_restores: std.ArrayList(SpRestore) = .empty;
    defer splice_ty_restores.deinit(b.allocator);
    defer for (splice_ty_restores.items) |sr| b.restoreSpliceParamTy(sr.name, sr.prev);
    for (f.params) |*p| {
        const sub = try substReifiedInTypeRef(b, &p.ty);
        const sprev = try b.bindSpliceParamTy(p.name.name, sub);
        try splice_ty_restores.append(b.allocator, .{ .name = p.name.name, .prev = sprev });
    }
    // Mark body-declared `var`s that a nested closure writes as boxed so
    // their decl emits `MakeCell` and the closure's write lands on the
    // shared cell. (Params were boxed at bind time above; this covers
    // `var`s declared inside the spliced body.) Record newly-boxed names so
    // the mark is removed after the splice and cannot reach a same-named
    // caller local.
    {
        var sit = splice_boxed.keyIterator();
        while (sit.next()) |k| {
            if (paramIndex(f, k.*) != null) continue; // params handled at bind time
            if (!b.isBoxed(k.*)) {
                try b.markBoxed(k.*);
                try boxed_here.append(b.allocator, k.*);
            }
        }
    }
    const result = b.allocReg();
    const unit0 = try b.emitConst(Const.Unit);
    try b.push(.{ .Move = .{ .dst = result, .src = unit0 } });
    const join = try b.allocBlock();
    try b.pushInlineReturn(result, join);
    const body_val = switch (body.*) {
        // Lower an expression body with the inline function's own declared
        // return type as the expected (tail-position) type — exactly as a
        // normal function body lowers. A tail-position reified call then
        // infers its type argument from this function's return type rather
        // than the splice site's surrounding expected, so a chain like
        // `receiveChannel(): ByteReadChannel = receive()` binds the inner
        // `receive`'s `T` to `ByteReadChannel`.
        .Expr => |*e| blk: {
            const prev = b.pushExpected(f.return_type);
            defer b.restoreExpected(prev);
            break :blk try lowerExpr(b, e);
        },
        .Block => |*blk| try lowerBlock(b, blk),
    };
    try b.push(.{ .Move = .{ .dst = result, .src = body_val } });
    if (ext_splice) b.lambda_splice_resolve = prev_splice_window;
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    for (marked_rlp.items) |n| {
        b.unmarkReceiverLambdaParam(n);
    }
    // Remove the boxing marks added for this splice so a same-named caller
    // local keeps its own (un)boxed status.
    for (boxed_here.items) |n| b.unmarkBoxed(n);
    // Restore enclosing reified-type bindings shadowed by this splice
    // (reverse order so nested same-named params unwind correctly).
    {
        var ri: usize = reified_restores.items.len;
        while (ri > 0) {
            ri -= 1;
            const rr = reified_restores.items[ri];
            b.restoreReifiedType(rr.name, rr.prev);
        }
    }
    b.popInlineReturn();
    b.popInlineLambdaFrame();
    try b.popScope();
    b.popInlineDecl();
    inline_state.inlineExpandLeave();
    return result;
}

/// The runtime-resolvable class name for a reified type argument: a
/// QUALIFIED nested reference (`IntervalList.Interval`) resolves to its
/// lifted `$`-mangled class (`IntervalList$Interval`, trying deeper
/// nesting when two segments miss); an unqualified name falls back to
/// the lexical scope-rename ladder unchanged.
fn reifiedQualifiedName(b: *FuncBuilder, a: ast.TypeRef) ?[]const u8 {
    const qp = a.qualified_path orelse return null;
    var segs: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, qp, '.');
    while (it.next()) |seg| {
        if (n == segs.len) return null;
        segs[n] = seg;
        n += 1;
    }
    if (n < 2) return null;
    var k: usize = 2;
    while (k <= n) : (k += 1) {
        var buf: std.ArrayList(u8) = .empty;
        for (segs[n - k .. n], 0..) |seg, i| {
            if (i != 0) buf.append(b.allocator, '$') catch return null;
            buf.appendSlice(b.allocator, seg) catch return null;
        }
        const cand = buf.toOwnedSlice(b.allocator) catch return null;
        if (b.module.classIdIndexed(cand, b.self_package, a.name.span.file) != null) return cand;
    }
    return null;
}

fn paramIndex(f: *const Function, name: []const u8) ?usize {
    for (f.params, 0..) |p, i| {
        if (std.mem.eql(u8, p.name.name, name)) return i;
    }
    return null;
}

/// Clone `ty` with the builder's active reified NAME substitutions
/// applied (`NodeKind<T>` -> `NodeKind<LayoutAwareModifierNode>`),
/// recursing through generic arguments and function-type positions.
fn substReifiedInTypeRef(b: *FuncBuilder, ty: *const TypeRef) Allocator.Error!TypeRef {
    var out = ty.*;
    if (b.resolveReifiedTypeName(ty.name.name)) |actual| {
        out.name = .{ .name = actual, .span = ty.name.span };
    }
    if (ty.type_args.len != 0) {
        const targs = try b.allocator.alloc(ast.TypeArg, ty.type_args.len);
        for (ty.type_args, 0..) |ta, i| {
            targs[i] = ta;
            if (!ta.is_star) targs[i].ty = try substReifiedInTypeRef(b, &ta.ty);
        }
        out.type_args = targs;
    }
    if (ty.function) |ft| {
        const nf = try b.allocator.create(ast.FunctionTypeRef);
        nf.* = ft.*;
        if (ft.receiver) |*r| nf.receiver = try substReifiedInTypeRef(b, r);
        const nparams = try b.allocator.alloc(TypeRef, ft.params.len);
        for (ft.params, 0..) |*p, i| nparams[i] = try substReifiedInTypeRef(b, p);
        nf.params = nparams;
        nf.ret = try substReifiedInTypeRef(b, &ft.ret);
        out.function = nf;
    }
    return out;
}

/// Whether every reified type parameter of `f` is solvable from the
/// call's non-lambda arguments (explicit generic-typed values, splice
/// parameters carrying recorded types). Used to keep a splice whose
/// trailing lambda under-declares the function-typed parameter's arity:
/// arity only matters when the lambda is the sole evidence for `T`.
/// Resolve the reified type-argument NAMES a call binds by inference
/// (the same evidence `reifiedBindableFromArgs` proves), mapped through
/// the active splice substitutions and scope renames — ready to stamp on
/// a typed dispatch instruction. Null when any reified parameter stays
/// unbound.
pub fn inferReifiedNamesForCall(
    b: *FuncBuilder,
    f: *const Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    file: u32,
) ?[]const []const u8 {
    const ordered = b.allocator.alloc(?*const Expr, f.params.len) catch return null;
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const lambda_to_last = last_is_lambda and args.len <= f.params.len and f.params.len > 0;
    if (lambda_to_last) ordered[f.params.len - 1] = &args[args.len - 1];
    const positional_n = if (lambda_to_last) args.len - 1 else args.len;
    var next_pos: usize = 0;
    for (args[0..positional_n], 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (nm) |name| {
            const idx = paramIndex(f, name) orelse return null;
            ordered[idx] = a;
        } else {
            while (next_pos < ordered.len and ordered[next_pos] != null) next_pos += 1;
            if (next_pos >= ordered.len) return null;
            ordered[next_pos] = a;
            next_pos += 1;
        }
    }
    const probe = inferReifiedTypeArgs(b.allocator, f, &.{}, null, ordered, b) catch return null;
    defer b.allocator.free(probe);
    var out: std.ArrayList([]const u8) = .empty;
    for (f.type_params, 0..) |tp, i| {
        if (!tp.is_reified) continue;
        const t = probe[i] orelse {
            out.deinit(b.allocator);
            return null;
        };
        const substituted = b.resolveReifiedTypeName(t.name.name) orelse
            (expr_lower.scopeTypeRename(b, t.name.name, file) orelse t.name.name);
        out.append(b.allocator, substituted) catch {
            out.deinit(b.allocator);
            return null;
        };
    }
    if (out.items.len == 0) {
        out.deinit(b.allocator);
        return null;
    }
    return out.toOwnedSlice(b.allocator) catch null;
}

pub fn reifiedBindableFromArgs(
    b: *const FuncBuilder,
    f: *const Function,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) bool {
    const ordered = b.allocator.alloc(?*const Expr, f.params.len) catch return false;
    defer b.allocator.free(ordered);
    for (ordered) |*slot| slot.* = null;
    const last_is_lambda = args.len > 0 and switch (args[args.len - 1]) {
        .Lambda, .AnonFun => true,
        else => false,
    };
    const lambda_to_last = last_is_lambda and args.len <= f.params.len and f.params.len > 0;
    if (lambda_to_last) ordered[f.params.len - 1] = &args[args.len - 1];
    const positional_n = if (lambda_to_last) args.len - 1 else args.len;
    var next_pos: usize = 0;
    for (args[0..positional_n], 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (nm) |name| {
            const idx = paramIndex(f, name) orelse return false;
            ordered[idx] = a;
        } else {
            while (next_pos < ordered.len and ordered[next_pos] != null) next_pos += 1;
            if (next_pos >= ordered.len) return false;
            ordered[next_pos] = a;
            next_pos += 1;
        }
    }
    const probe = inferReifiedTypeArgs(b.allocator, f, &.{}, null, ordered, b) catch return false;
    defer b.allocator.free(probe);
    for (f.type_params, 0..) |tp, i| {
        if (tp.is_reified and probe[i] == null) return false;
    }
    return true;
}

/// Index of a parameter that solves type parameter `tp_name` from a
/// constructor-reference argument: the parameter's declared type is a
/// function type whose return is the bare type parameter, and the
/// argument is a `Type::Nested` constructor reference — whose lowered
/// value is the referenced class, so the splice can bind the reified
/// parameter to it directly (`sleepWhile(Slot::Read)` solves
/// `TaskType = Slot.Read`).
fn callableRefParamFor(f: *const Function, ordered: []const ?*const Expr, tp_name: []const u8) ?usize {
    for (f.params, 0..) |*p, i| {
        const ft = p.ty.function orelse continue;
        if (ft.ret.function != null or ft.ret.type_args.len != 0) continue;
        if (!std.mem.eql(u8, ft.ret.name.name, tp_name)) continue;
        const a = (if (i < ordered.len) ordered[i] else null) orelse continue;
        if (isTypeConstructorRef(a)) return i;
    }
    return null;
}

/// Whether an expression is a `Type::Nested` constructor reference —
/// a `MemberRef` whose receiver is a type-name path and whose member
/// itself names a type (`Slot::Read`). A lowercase member (`obj::method`,
/// `String::length`) is a bound callable, not a class, so it never
/// solves a reified parameter here.
fn isTypeConstructorRef(e: *const Expr) bool {
    return switch (e.*) {
        .MemberRef => |mr| nameLooksLikeType(mr.name.name) and isTypeNamePath(mr.receiver),
        else => false,
    };
}

fn isTypeNamePath(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| blk: {
            if (p.segments.len == 0) break :blk false;
            for (p.segments) |s| {
                if (!nameLooksLikeType(s.name)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn nameLooksLikeType(n: []const u8) bool {
    return n.len > 0 and n[0] >= 'A' and n[0] <= 'Z';
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const span = @import("span");

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

fn ident(name: []const u8) ast.Ident {
    return .{ .name = name, .span = dummySpan() };
}

test "arg_lambda_has_nonlocal_return detects bare return" {
    var ret = Expr{ .Return = .{ .value = null, .label = null, .span = dummySpan() } };
    var stmts = [_]Stmt{.{ .Expr = ret }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{lam};
    try testing.expect(argLambdaHasNonlocalReturn(&args));
    _ = &ret;
}

test "arg_lambda_has_nonlocal_return ignores nested lambda return" {
    // A `return` inside a nested lambda is local to that lambda.
    var inner_ret = Expr{ .Return = .{ .value = null, .label = null, .span = dummySpan() } };
    var inner_stmts = [_]Stmt{.{ .Expr = inner_ret }};
    const inner_lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &inner_stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    var outer_stmts = [_]Stmt{.{ .Expr = inner_lam }};
    const outer_lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &outer_stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{outer_lam};
    try testing.expect(!argLambdaHasNonlocalReturn(&args));
    _ = &inner_ret;
}

test "arg_lambda_has_nonlocal_return scans nested control flow" {
    // `if (cond) return` inside a lambda body counts.
    var cond = Expr{ .BoolLit = .{ .value = true, .span = dummySpan() } };
    var ret = Expr{ .Return = .{ .value = null, .label = null, .span = dummySpan() } };
    const if_expr = Expr{ .If = .{
        .cond = &cond,
        .then_branch = &ret,
        .else_branch = null,
        .span = dummySpan(),
    } };
    var stmts = [_]Stmt{.{ .Expr = if_expr }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{lam};
    try testing.expect(argLambdaHasNonlocalReturn(&args));
}

test "arg_lambda_has_nonlocal_return false for plain body" {
    var lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    var stmts = [_]Stmt{.{ .Expr = lit }};
    const lam = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &stmts, .span = dummySpan() },
        .span = dummySpan(),
    } };
    const args = [_]Expr{lam};
    try testing.expect(!argLambdaHasNonlocalReturn(&args));
    _ = &lit;
}

test "arg_lambda_has_nonlocal_return false for non-lambda arg" {
    const lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = dummySpan() } };
    const args = [_]Expr{lit};
    try testing.expect(!argLambdaHasNonlocalReturn(&args));
}

test "inline lambda forwarding preserves the original literal" {
    var module = ir.Module.default(testing.allocator);
    defer module.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &module);
    defer b.deinit();

    var lambda = Expr{ .Lambda = .{
        .params = &.{},
        .body = .{ .stmts = &.{}, .span = dummySpan() },
        .span = dummySpan(),
    } };
    var substitutions = std.StringHashMap(*const ast.Expr).init(testing.allocator);
    try substitutions.put("block", &lambda);
    try b.pushInlineLambdaFrame(substitutions, b.scopeDepth());
    defer b.popInlineLambdaFrame();

    var segments = [_]ast.Ident{ident("block")};
    const forwarded = Expr{ .Path = .{ .segments = &segments, .span = dummySpan() } };
    const args = [_]Expr{forwarded};
    try testing.expectEqual(&lambda, forwardedInlineLambda(&b, &forwarded).?);
    try testing.expect(argsForwardInlineLambda(&b, &args));
}

fn typeRef(name: []const u8) TypeRef {
    return .{
        .name = ident(name),
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

test "unify_type_param binds a bare type parameter" {
    var tp_names = std.StringHashMap(void).init(testing.allocator);
    defer tp_names.deinit();
    try tp_names.put("T", {});
    var subst = std.StringHashMap(TypeRef).init(testing.allocator);
    defer subst.deinit();
    const decl = typeRef("T");
    const actual = typeRef("User");
    try unifyTypeParam(&decl, &actual, &tp_names, &subst);
    const got = subst.get("T") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("User", got.name.name);
}

test "unify_type_param recurses through generic args" {
    var tp_names = std.StringHashMap(void).init(testing.allocator);
    defer tp_names.deinit();
    try tp_names.put("T", {});
    var subst = std.StringHashMap(TypeRef).init(testing.allocator);
    defer subst.deinit();
    // decl: Box<T> ; actual: Box<Int> ; solves T = Int.
    var decl_args = [_]ast.TypeArg{.{
        .variance = .Invariant,
        .is_star = false,
        .ty = typeRef("T"),
        .span = dummySpan(),
    }};
    var actual_args = [_]ast.TypeArg{.{
        .variance = .Invariant,
        .is_star = false,
        .ty = typeRef("Int"),
        .span = dummySpan(),
    }};
    var decl = typeRef("Box");
    decl.type_args = &decl_args;
    var actual = typeRef("Box");
    actual.type_args = &actual_args;
    try unifyTypeParam(&decl, &actual, &tp_names, &subst);
    const got = subst.get("T") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Int", got.name.name);
}
