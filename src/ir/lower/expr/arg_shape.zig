//! Argument shape evidence and the smart-cast narrowing probes.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const compose_pass = @import("compose_pass");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;

const paths_mod = @import("paths.zig");
const loweredCheckTypeName = paths_mod.loweredCheckTypeName;

const lambda_mod = @import("lambda.zig");
const fnTypeArityAlias = lambda_mod.fnTypeArityAlias;

const static_type_mod = @import("static_type.zig");
const argDeclTypeRefLazyUncached = static_type_mod.argDeclTypeRefLazyUncached;
const lazyMemoGet = static_type_mod.lazyMemoGet;
const lazyMemoLeave = static_type_mod.lazyMemoLeave;
const staticExprTypeRef = static_type_mod.staticExprTypeRef;
const tyMemoEnter = static_type_mod.tyMemoEnter;

const probe_mod = @import("probe.zig");
const typeHead = probe_mod.typeHead;

/// Whether a single-segment class-name call resolves to the constructor
/// rather than a same-named factory function.
pub const LitKind = enum { numeric, string, boolean, char };

/// Whether an expression's STATIC type head is definitely a list-family
/// value: a call to a list factory, or a `listOf(...) + x` chain. Used to
/// route `list + (rhs as Any)` through `plusElement`.
pub fn staticListHead(e: *const Expr) bool {
    return switch (e.*) {
        .Call => |c| blk: {
            if (c.callee.* != .Path or c.callee.Path.segments.len != 1) break :blk false;
            const n = c.callee.Path.segments[0].name;
            break :blk std.mem.eql(u8, n, "listOf") or std.mem.eql(u8, n, "mutableListOf") or
                std.mem.eql(u8, n, "emptyList") or std.mem.eql(u8, n, "arrayListOf");
        },
        .Binary => |bi| bi.op == .Add and staticListHead(bi.lhs),
        else => false,
    };
}

/// Definite builtin value kind of a literal argument expression, or null when
/// the argument's type is not a known literal (so it can never *disprove* a
/// candidate parameter type).
pub fn argLitKind(e: *const Expr) ?LitKind {
    return switch (e.*) {
        .IntLit, .FloatLit => .numeric,
        .BoolLit => .boolean,
        .CharLit => .char,
        .StringTemplate => .string,
        // A signed literal is a literal: `nextInt(-1)` carries numeric
        // evidence exactly as `nextInt(1)` does.
        .Unary => |u| if ((u.op == .Neg or u.op == .Pos) and
            (u.expr.* == .IntLit or u.expr.* == .FloatLit)) .numeric else null,
        else => null,
    };
}

/// Whether a local's initializer is a constructor call of a concrete class
/// that provably has no `invoke` operator — member (own or inherited) or
/// applicable extension — making the local's value non-invokable, so a bare
/// call of its name must bind a same-named function or member instead.
/// Answers false whenever anything is unknown (qualified callee, abstract
/// classifier, absent hierarchy entry): unknown keeps the local binding.
/// Whether a local initialized by an ordinary FUNCTION call is non-invocable,
/// judged from that function's declared return type. `ctorInitNonInvocable`
/// answers only `val x = X(...)`; this answers `val box = mk()` and, the shape
/// that matters across kotlinx's flow tests, `val flow = flowOf(1, 2)` — a
/// `Flow` declares no `invoke`, so the call `flow { … }` written beside it
/// names the `flow { … }` builder, exactly as Kotlin resolves it.
/// The same non-invokable test over the initializer's STATIC TYPE, so a
/// local initialised by anything the deriver can type — a member call
/// (`val flow = listOf(1).asFlow()`), a property read, a chain — shadows a
/// same-named function only when its own type could actually take the call.
/// `Flow` declares no `invoke`, so `flow { emit(42) }` beside such a local
/// is the BUILDER.
pub fn initTypeNonInvocable(b: *FuncBuilder, init_e: *const Expr, argc: usize) Allocator.Error!bool {
    var ty = (staticExprTypeRef(b, init_e) catch null) orelse return false;
    defer ty.deinit(b.allocator);
    const head = typeHead(std.mem.trimEnd(u8, ty.name, "?"));
    if (head.len == 0) return false;
    if (std.mem.startsWith(u8, head, "Function")) return false;
    if (std.mem.eql(u8, head, "<function>")) return false;
    const cid = b.module.uniqueClassIdBySimpleName(head) orelse b.module.classId(head) orelse return false;
    if (cid.int() >= b.module.classes.items.len) return false;
    const cls = &b.module.classes.items[cid.int()];
    const methods = b.module.registry.hierarchy_methods.get(cls.fqn) orelse
        b.module.registry.hierarchy_methods.get(cls.name) orelse return false;
    if (methods.contains("invoke")) return false;
    return b.module.extCouldApplyWhy(b.allocator, cls.name, "invoke", argc) == .none;
}

pub fn callInitNonInvocable(b: *FuncBuilder, init_e: *const Expr, argc: usize) bool {
    const call = switch (init_e.*) {
        .Call => |*c| c,
        else => return false,
    };
    const path = switch (call.callee.*) {
        .Path => |*p| p,
        else => return false,
    };
    if (path.segments.len != 1) return false;
    const fid = b.module.funcId(path.segments[0].name) orelse return false;
    const f = b.module.funcById(fid) orelse return false;
    if (!f.return_ty_declared) return false;
    const head = typeHead(std.mem.trimEnd(u8, f.return_ty.name, "?"));
    if (std.mem.indexOf(u8, f.return_ty.name, "->") != null) return false;
    if (std.mem.startsWith(u8, head, "Function")) return false;
    const cid = b.module.classId(head) orelse return false;
    if (cid.int() >= b.module.classes.items.len) return false;
    const cls = &b.module.classes.items[cid.int()];
    const methods = b.module.registry.hierarchy_methods.get(cls.fqn) orelse
        b.module.registry.hierarchy_methods.get(cls.name) orelse return false;
    if (methods.contains("invoke")) return false;
    return b.module.extCouldApplyWhy(b.allocator, cls.name, "invoke", argc) == .none;
}

/// The last dotted segment of a type head (`kotlin.text.StringBuilder` ->
/// `StringBuilder`), so a qualified and an unqualified spelling of the same
/// class compare equal.
pub fn simpleTail(h: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, h, '.')) |i| return h[i + 1 ..];
    return h;
}

pub fn ctorInitNonInvocable(b: *FuncBuilder, init_e: *const Expr, argc: usize) bool {
    const call = switch (init_e.*) {
        .Call => |*c| c,
        else => return false,
    };
    const path = switch (call.callee.*) {
        .Path => |*p| p,
        else => return false,
    };
    if (path.segments.len != 1) return false;
    const cls_name = path.segments[0].name;
    const cid = b.module.classId(cls_name) orelse return false;
    if (cid.int() >= b.module.classes.items.len) return false;
    const cls = &b.module.classes.items[cid.int()];
    if (cls.is_abstract) return false;
    const methods = b.module.registry.hierarchy_methods.get(cls.fqn) orelse
        b.module.registry.hierarchy_methods.get(cls.name) orelse return false;
    if (methods.contains("invoke")) return false;
    return b.module.extCouldApplyWhy(b.allocator, cls.name, "invoke", argc) == .none;
}

/// Declared parameter arity of a single lambda / anon-fun argument
/// expression, or null when it is neither. A zero-`->` `{ … }` (its `it`
/// injected by the parser) reports 0 — the literal declares no parameters,
/// so overload resolution treats it as a `() -> R` handler.
fn astArgLambdaArity(arg: *const Expr) ?u8 {
    return switch (arg.*) {
        .Lambda => |l| blk: {
            if (l.implicit_it) break :blk @as(u8, 0);
            // The compose plugin threads every composable lambda BEFORE
            // lowering, appending `($composer, $changed)`. Those are not
            // source params: overload selection must rank the literal by
            // its DECLARED header, or the +2 shift binds `{ d -> }` to a
            // 3-param overload (`movableContentOf`'s P3 form).
            var n = l.params.len;
            if (n >= 2 and std.mem.eql(u8, l.params[n - 1].name, "$changed") and
                std.mem.eql(u8, l.params[n - 2].name, "$composer"))
            {
                n -= 2;
            }
            break :blk @intCast(n);
        },
        .AnonFun => |af| @intCast(af.params.len),
        else => blk: {
            // A memo-wrapped sink lambda ranks by the inner literal's
            // declared header, exactly like the bare literal above.
            const lam = compose_pass.memoWrappedLambda(@constCast(arg)) orelse break :blk null;
            if (lam.implicit_it) break :blk @as(u8, 0);
            var n = lam.params.len;
            if (n >= 2 and std.mem.eql(u8, lam.params[n - 1].name, "$changed") and
                std.mem.eql(u8, lam.params[n - 2].name, "$composer"))
            {
                n -= 2;
            }
            break :blk @intCast(n);
        },
    };
}

/// One argument's applicability `ArgShape` at LOWERING time. Only the
/// fields lowering can prove cheaply and soundly are populated — named /
/// spread / lambda binding shape, a literal kind, and the declared-type
/// head of a plain local/param argument; `runtime_class` /
/// `lambda_param_types` / `value` stay null, so the shared scorer treats
/// the arg as UNKNOWN (base points, never disproven) wherever the type is
/// not statically decidable. Declared-type evidence is additive-only in
/// the scorer: it can promote a head-matching candidate but never
/// disqualify one.
/// Head-only `TypeRef`s for a lambda literal's ANNOTATED parameters, or null
/// when it annotates none. Only the head matters: the consumer refutes on a
/// definite mismatch and stays silent otherwise.
fn lambdaDeclaredParamTypes(b: *FuncBuilder, arg: *const Expr) ?[]const ir.TypeRef {
    if (arg.* != .Lambda) return null;
    const tys = arg.Lambda.param_tys;
    if (tys.len == 0) return null;
    var any = false;
    for (tys) |t| {
        if (t != null) any = true;
    }
    if (!any) return null;
    const out = b.allocator.alloc(ir.TypeRef, tys.len) catch return null;
    for (tys, out) |t, *o| {
        o.* = if (t) |ast_ty|
            .{ .name = ast_ty.name.name, .nullable = ast_ty.nullable, .args = &.{} }
        else
            .{ .name = "", .nullable = false, .args = &.{} };
    }
    return out;
}

pub fn shapeOfAstArg(b: *FuncBuilder, arg: *const Expr, name: ?[]const u8) applicability.ArgShape {
    const lazy_ty = argDeclTypeRefLazy(b, arg);
    const ty = argDeclTypeRef(b, arg);
    const declared_fn_arity = if (ty) |t| fnTypeArityAlias(b, t) else null;
    // A memo-wrapped sink lambda is the trailing functional argument for
    // overload selection — the wrap is transparent to the shape.
    const literal_callable = arg.* == .Lambda or arg.* == .AnonFun or
        compose_pass.memoWrappedLambda(@constCast(arg)) != null;
    const sh: applicability.ArgShape = .{
        .named = name,
        .is_spread = arg.* == .Spread,
        .is_null = arg.* == .NullLit,
        .is_lambda = literal_callable or declared_fn_arity != null,
        .lambda_arity = astArgLambdaArity(arg) orelse if (declared_fn_arity) |n| @intCast(n) else null,
        .func_typed = declared_fn_arity != null,
        .lambda_is_literal = literal_callable,
        .literal_kind = if (argEvidenceLitKind(b, arg)) |k| switch (k) {
            .numeric => .numeric,
            .string => .string,
            .boolean => .boolean,
            .char => .char,
        } else null,
        .ty = ty,
        .ty_authoritative = lazy_ty != null,
        // Explicitly annotated lambda parameters are programmer-stated types,
        // and kotlinc drops a candidate whose function parameter cannot accept
        // them.
        .lambda_param_types = lambdaDeclaredParamTypes(b, arg),
    };
    if (runtime.envSetOnce("KLIO_ARGSHAPE_UNK") and
        sh.ty == null and sh.literal_kind == null and !sh.is_lambda)
    {
        noteUnknownArgShape("argshape-unk", arg);
    }
    return sh;
}

/// Diagnostic: which argument SHAPES stay unknown to the applicability
/// scorer (no type, no literal kind, not callable). Those are the shapes
/// that make `memberPromotionProven` answer `arg-unauthoritative`, so the
/// tag histogram names the expression forms worth typing next.
pub fn noteUnknownArgShape(tag: []const u8, arg: *const Expr) void {
    const detail: []const u8 = switch (arg.*) {
        .Path => |p| if (p.segments.len != 0) p.segments[p.segments.len - 1].name else "-",
        .Member => |m| m.name.name,
        .Call => |c| if (c.callee.* == .Member) c.callee.Member.name.name else if (c.callee.* == .Path and c.callee.Path.segments.len != 0) c.callee.Path.segments[c.callee.Path.segments.len - 1].name else "-",
        .Binary => |bin| @tagName(bin.op),
        else => "-",
    };
    std.debug.print("[{s}] {s} {s}\n", .{ tag, @tagName(arg.*), detail });
}

/// Literal-kind evidence for an argument: the argument itself is a literal,
/// or it names a local whose recorded initializer is one (`val x = 1.0;
/// f(x)`). Evidence only, never disproving.
pub fn argEvidenceLitKind(b: *FuncBuilder, arg: *const Expr) ?LitKind {
    if (argLitKind(arg)) |k| return k;
    if (arg.* == .Path and arg.Path.segments.len == 1) {
        if (b.localInitExpr(arg.Path.segments[0].name)) |init_e| {
            return argLitKind(init_e);
        }
    }
    return null;
}

/// Declared-type head of a single-segment Path argument naming a local /
/// parameter whose declared type is known (`b.localDeclType`), as a `TypeRef`
/// for the shared scorer's declared-type evidence. Null for anything else.
/// An `if (x is T)` condition over a bare name smart-casts `x` to `T` for the
/// then-arm. Kotlin resolves extensions against the STATIC type, and lowering
/// hands the receiver's declared head to the extension filter, so without the
/// narrowing the declared head (`Any?`) refutes every `CharSequence` extension
/// and `x.isEmpty()` misses. A negated check narrows nothing here (its
/// information is on the else path).
/// Every smart cast a condition proves for its TRUE branch. Kotlin narrows on
/// each `is` check in an `&&` chain, not only on a condition that is itself an
/// `is` check: `if (!ignoreCase && this is String && prefix is String)` narrows
/// both. Without walking the chain, `CharSequence.startsWith` resolved its own
/// `this.startsWith(prefix)` — written under exactly that guard — back to the
/// CharSequence extension instead of `String.startsWith`, and recursed until
/// the stack ran out.
///
/// Applied in source order; the caller restores in reverse, because each
/// narrowing saves the binding the previous one left.
pub fn narrowIsCheckAll(
    b: *FuncBuilder,
    cond: *const Expr,
    out: *std.ArrayList(build.FuncBuilder.NarrowedLocal),
) Allocator.Error!void {
    if (cond.* == .Binary and cond.Binary.op == .And) {
        try narrowIsCheckAll(b, cond.Binary.lhs, out);
        try narrowIsCheckAll(b, cond.Binary.rhs, out);
        return;
    }
    if (try narrowIsCheck(b, cond)) |n| try out.append(b.allocator, n);
}

pub fn narrowIsCheck(b: *FuncBuilder, cond: *const Expr) Allocator.Error!?build.FuncBuilder.NarrowedLocal {
    if (cond.* != .IsCheck) return null;
    const ck = cond.IsCheck;
    if (ck.negated) return null;
    const head = loweredCheckTypeName(b, &ck.ty);
    if (head.len == 0) return null;
    if (ck.expr.* == .Path and ck.expr.Path.segments.len == 1) {
        return try b.narrowLocal(ck.expr.Path.segments[0].name, head);
    }
    if (ck.expr.* == .This and ck.expr.This.qualifier == null) {
        return try b.narrowLocal("this", head);
    }
    return null;
}

/// Every non-null narrowing a condition proves for the branch it guards.
/// Kotlin narrows on each `!= null` in an `&&` chain, exactly as it does for
/// each `is` check — `if (a != null && b != null)` narrows both — and on each
/// `== null` in an `||` chain for the ELSE branch. Only a condition that was
/// itself the whole check narrowed anything, so the common guarded shape got
/// no narrowing at all and its member calls stayed off the static path.
///
/// Applied in source order; the caller restores in reverse, because each
/// narrowing saves the binding the previous one left.
pub fn narrowNullCheckAll(
    b: *FuncBuilder,
    cond: *const Expr,
    truthy: bool,
    out: *std.ArrayList(build.FuncBuilder.NarrowedLocal),
) Allocator.Error!void {
    if (cond.* == .Binary and
        !std.mem.eql(u8, runtime.envOnce("KLIO_NULL_CHAIN") orelse "1", "0"))
    {
        const op = cond.Binary.op;
        if ((truthy and op == .And) or (!truthy and op == .Or)) {
            try narrowNullCheckAll(b, cond.Binary.lhs, truthy, out);
            try narrowNullCheckAll(b, cond.Binary.rhs, truthy, out);
            return;
        }
    }
    if (try narrowNullCheck(b, cond, truthy)) |n| try out.append(b.allocator, n);
}

/// Whether `cond` narrows the bare `this` receiver to non-null under
/// `truthy` (`if (this != null) ...`), including through `&&`/`||` chains.
/// Used to set the this-narrow so a member call in the branch resolves
/// against the non-null receiver type.
pub fn condNarrowsThisNotNull(cond: *const Expr, truthy: bool) bool {
    if (cond.* == .Binary) {
        const op = cond.Binary.op;
        if ((truthy and op == .And) or (!truthy and op == .Or)) {
            return condNarrowsThisNotNull(cond.Binary.lhs, truthy) or condNarrowsThisNotNull(cond.Binary.rhs, truthy);
        }
        const unequal = op == .Neq or op == .IdentNeq;
        const equal = op == .Eq or op == .IdentEq;
        if (!(if (truthy) unequal else equal)) return false;
        const value = if (cond.Binary.lhs.* == .NullLit)
            cond.Binary.rhs
        else if (cond.Binary.rhs.* == .NullLit)
            cond.Binary.lhs
        else
            return false;
        return value.* == .This and value.This.qualifier == null;
    }
    return false;
}

fn narrowNullCheck(
    b: *FuncBuilder,
    cond: *const Expr,
    truthy: bool,
) Allocator.Error!?build.FuncBuilder.NarrowedLocal {
    if (cond.* != .Binary) return null;
    const binary = cond.Binary;
    const unequal = binary.op == .Neq or binary.op == .IdentNeq;
    const equal = binary.op == .Eq or binary.op == .IdentEq;
    if (!(if (truthy) unequal else equal)) return null;
    const value = if (binary.lhs.* == .NullLit)
        binary.rhs
    else if (binary.rhs.* == .NullLit)
        binary.lhs
    else
        return null;
    if (value.* != .Path or value.Path.segments.len != 1) return null;
    return b.narrowLocalNotNull(value.Path.segments[0].name);
}

pub fn argDeclTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (runtime.envOnce("KLIO_VALTY_TRACE")) |w| {
        if (arg.* == .Path and arg.Path.segments.len == 1 and std.mem.eql(u8, arg.Path.segments[0].name, w)) {
            std.debug.print("[valty] READ {s} decl={s} b={x} fn={s} ndecl={d}\n", .{ w, if (b.localDeclTypeRef(w)) |t| t.name else "<unset>", @intFromPtr(b) & 0xffff, build.currentRealFn() orelse "-", b.localDeclTypeCount() });
        }
    }
    // The E2.1 type-head channel exists (Module.eagerTypeOf) but does
    // NOT feed evidence yet: typeck's permissive inference can hand back
    // a wrong container head (a ByteArray value typed Iterable), and a
    // wrong head DISPROVES valid candidates downstream. The seam flips
    // only after the type-head audit below reaches zero disagreement,
    // mirroring the call channel's per-class trust discipline.
    // A bare `this` narrowed non-null by an enclosing `if (this != null)`
    // resolves member calls against the non-null receiver type: inside
    // `operator fun Int?.inc()`, `this.inc()` in the non-null branch binds
    // the builtin `Int.inc`, not the nullable extension (a recursion).
    // Only the narrowed case answers; an un-narrowed `this` keeps its
    // declared (possibly nullable) type from the ordinary receiver path.
    if (arg.* == .This and arg.This.qualifier == null) {
        if (b.thisNarrow()) |h| {
            return .{ .name = b.allocator.dupe(u8, std.mem.trimEnd(u8, h, "?")) catch h, .nullable = false, .args = &.{} };
        }
        // Un-narrowed `this`: fall through to the normal derivation below
        // (returning null here would strip the receiver type from every
        // `this.method()` call).
    }
    // `x!!` has `x`'s type made NON-null: a member call on it resolves
    // against the non-null type, so `this!!.inc()` inside `Int?.inc` binds
    // the builtin `Int.inc`, not the nullable extension (a recursion).
    if (arg.* == .Postfix and arg.Postfix.op == .NotNull) {
        if (argDeclTypeRef(b, arg.Postfix.expr)) |inner| {
            var out = inner;
            out.nullable = false;
            if (std.mem.endsWith(u8, out.name, "?")) {
                out.name = std.mem.trimEnd(u8, out.name, "?");
            }
            return out;
        }
        return null;
    }
    var lazy_ans = argDeclTypeRefLazy(b, arg);
    // E2.1, ADDITIVE-ONLY: typeck's head fills in where the AST probes
    // have no answer; the declared (AST) answer always wins when both
    // exist — kotlinc resolves overloads against the STATIC DECLARED
    // type, and the audit shows the only both-exist deltas are the
    // legitimate declared-wider-vs-inferred-narrower class.
    if (lazy_ans == null) {
        if (b.module.eagerTypeOf(arg.span())) |th| {
            // `EagerTypeHead` carries a head and nullability, no type
            // ARGUMENTS. For a generic type that makes the answer worse than
            // none: extension selection needs the element type to choose
            // between `Iterable<T>.minOrNull` (total order) and
            // `Iterable<Double>.minOrNull` (IEEE), and a head-only `List`
            // disproves the generic candidate that a null receiver type would
            // have found by the broader walk. Measured: with the head,
            // `minOrNull` on Array/List/Sequence resolves to target=null and
            // falls to runtime dispatch, which picks the IEEE overload and
            // returns NaN where 0.0 is correct.
            const th_head = typeHead(std.mem.trimEnd(u8, th.name, "?"));
            const bare_tp_head = (th_head.len > 0 and th_head.len <= 2 and std.ascii.isUpper(th_head[0])) or
                b.isTypeParam(th_head) or ir.parseClassTypeParamIdentity(th_head) != null;
            if (headDeclaresTypeParams(b, th.name) or bare_tp_head) {
                // A bare TYPE-PARAMETER answer (`expected: T` read on a
                // typed receiver) blocks the substituting deriver behind
                // it, which would answer the instantiated type.
                if (typeheadAuditOn()) {
                    const sp = arg.span();
                    std.debug.print("[TYPEHEAD-SKIP] f{d}:{d} generic head {s} has no args\n", .{ sp.file.int(), sp.start, th.name });
                }
            } else {
                if (typeheadAuditOn()) {
                    const sp = arg.span();
                    std.debug.print("[TYPEHEAD-FILL] f{d}:{d} typeck={s}{s}\n", .{ sp.file.int(), sp.start, th.name, if (th.nullable) @as([]const u8, "?") else "" });
                }
                lazy_ans = .{ .name = th.name, .nullable = th.nullable, .args = &.{} };
            }
        }
    }
    // `KLIO_ARGTY_TRACE=<name>` — the static type this resolution actually
    // used for a named expression, and whether it came from an inline
    // splice's declared parameter type. This is what separates "lowering has
    // no type" from "lowering has the wrong type", which look identical from
    // a failing test.
    if (runtime.envOnce("KLIO_ARGTY_TRACE")) |w| {
        if (arg.* == .Path and arg.Path.segments.len == 1 and std.mem.eql(u8, arg.Path.segments[0].name, w)) {
            if (lazy_ans) |la| {
                std.debug.print("[argty] {s} -> {s} args={d} splice_ty={}\n", .{ w, la.name, la.args.len, b.spliceParamTy(w) != null });
            } else std.debug.print("[argty] {s} -> <none>\n", .{w});
        }
    }
    if (typeheadAuditOn()) {
        if (b.module.eagerTypeOf(arg.span())) |th| {
            if (lazy_ans) |la| {
                if (!std.mem.eql(u8, la.name, th.name) or la.nullable != th.nullable) {
                    const sp = arg.span();
                    std.debug.print("[TYPEHEAD-AUDIT] f{d}:{d} ast={s}{s} typeck={s}{s}\n", .{
                        sp.file.int(), sp.start,
                        la.name,       if (la.nullable) @as([]const u8, "?") else "",
                        th.name,       if (th.nullable) @as([]const u8, "?") else "",
                    });
                }
            }
        }
    }
    return lazy_ans;
}

fn typeheadAuditOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.envOnce("KLIO_TYPEHEAD_AUDIT") != null;
    S.cached = on;
    return on;
}

/// Whether the class named by an eager type HEAD declares type parameters,
/// in which case a head without arguments is incomplete evidence. Builtin
/// container heads are listed explicitly: they are not user classes, so the
/// class table cannot answer for them.
fn headDeclaresTypeParams(b: *FuncBuilder, head: []const u8) bool {
    const generic_builtins = [_][]const u8{
        "Array",           "List",                    "MutableList", "Set",               "MutableSet",
        "Map",             "MutableMap",              "Collection",  "MutableCollection", "Iterable",
        "MutableIterable", "Sequence",                "Iterator",    "MutableIterator",   "Comparable",
        "Comparator",      "Pair",                    "Triple",      "Lazy",              "Result",
        "Map.Entry",       "MutableMap.MutableEntry",
    };
    for (generic_builtins) |g| {
        if (std.mem.eql(u8, g, head)) return true;
    }
    const cid = if (std.mem.indexOfScalar(u8, head, '.') != null)
        b.module.classIdByFqn(head)
    else
        b.module.uniqueClassIdBySimpleName(head);
    if (cid) |id| {
        if (id.int() < b.module.classes.items.len) {
            return b.module.classes.items[id.int()].type_params.len != 0;
        }
    }
    return false;
}

pub fn argDeclTypeRefLazy(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (lazyMemoGet(b, arg)) |hit| return hit.ty;
    const owns = tyMemoEnter(b);
    const r = argDeclTypeRefLazyUncached(b, arg);
    lazyMemoLeave(b, owns, arg, r);
    return r;
}

/// A bare name that denotes an `object` declaration visible from this
/// scope (the enclosing class's nested object first, then the indexed
/// top-level one) types as that object's class.
pub fn objectRefTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* != .Path or arg.Path.segments.len != 1) return null;
    const seg = arg.Path.segments[0];
    const nm = seg.name;
    if (nm.len == 0 or !std.ascii.isUpper(nm[0])) return null;
    const tr = runtime.envOnce("KLIO_SIBEXP_TRACE") != null;
    if (tr) std.debug.print("[objref] {s} resolve={} outer={} param={} decl={} owner={?s} cur={?s}\n", .{ nm, b.resolve(nm) != null, b.knowsOuter(nm), b.isParam(nm), b.localDeclTypeRef(nm) != null, b.ownerClass(), build.currentOwnerClass() });
    if (b.resolve(nm) != null or b.knowsOuter(nm) or b.isParam(nm)) return null;
    if (b.localDeclTypeRef(nm) != null) return null;
    var cid: ?ir.ClassId = null;
    var owner = b.ownerClass() orelse build.currentOwnerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 16) break;
        var qb: [192]u8 = undefined;
        if (std.fmt.bufPrint(&qb, "{s}.{s}", .{ o, nm }) catch null) |qualified| {
            if (b.module.classIdByQualifiedSuffix(qualified)) |n| {
                cid = n;
                break;
            }
        }
        if (b.module.classIdIndexed(o, b.self_package, seg.span.file) orelse b.module.classId(o)) |oid| {
            if (b.module.classIdNestedIn(oid, nm)) |n| {
                cid = n;
                break;
            }
        }
        owner = b.module.registry.enclosing_class.get(o);
    }
    if (cid == null) cid = b.module.classIdIndexed(nm, b.self_package, seg.span.file);
    const id = cid orelse {
        if (tr) std.debug.print("[objref] {s} no class\n", .{nm});
        return null;
    };
    if (id.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[id.int()];
    if (tr) std.debug.print("[objref] {s} -> {s} object={}\n", .{ nm, cls.name, cls.is_object });
    if (!cls.is_object) return null;
    return .{ .name = cls.name, .nullable = false, .args = &.{} };
}

/// The IR class of `name` as seen from the builder's scope: a nested class
/// resolves through its enclosing declaration first, so a same-named
/// top-level class cannot stand in for it.
fn classIdInScope(b: *FuncBuilder, name: []const u8, file: anytype) ?ir.ClassId {
    if (b.module.registry.enclosing_class.get(name)) |enc| {
        var qb: [192]u8 = undefined;
        if (std.fmt.bufPrint(&qb, "{s}.{s}", .{ enc, name }) catch null) |qualified| {
            if (b.module.classIdByQualifiedSuffix(qualified)) |cid| return cid;
        }
    }
    return b.module.classIdIndexed(name, b.self_package, file) orelse b.module.classId(name);
}

/// The enclosing `object` declaration whose hierarchy declares `name`, for
/// a bare reference written in a class nested inside it. Kotlin puts an
/// object's members in the static scope of everything declared in it, so
/// `class Foo : Base(::foo)` inside `object obj` passes `obj::foo` — bound
/// at lowering, since no instance exists while a super-constructor argument
/// evaluates. A member the owner class hierarchy declares itself is the
/// nearer scope and stays on receiver dispatch.
pub fn enclosingObjectDeclaring(b: *FuncBuilder, name: []const u8, file: anytype) ?ir.ClassId {
    var cur = b.ownerClass() orelse build.currentOwnerClass() orelse return null;
    if (classIdInScope(b, cur, file)) |own| {
        if (b.module.classHierarchyDeclaresMember(own, name)) return null;
    }
    var hops: usize = 0;
    while (hops < 16) : (hops += 1) {
        const enc = b.module.registry.enclosing_class.get(cur) orelse return null;
        const cid = classIdInScope(b, enc, file) orelse return null;
        if (cid.int() >= b.module.classes.items.len) return null;
        const cls = &b.module.classes.items[cid.int()];
        if (cls.is_object and b.module.classHierarchyDeclaresMember(cid, name)) return cid;
        cur = enc;
    }
    return null;
}

/// Load an `object` declaration's singleton by class identity.
pub fn loadObjectValue(b: *FuncBuilder, cid: ir.ClassId) Allocator.Error!Reg {
    const identity = b.module.classFqnById(cid) orelse b.module.classes.items[cid.int()].name;
    const nm = try b.module.internConst(b.allocator, .{ .String = identity });
    const dst = b.allocReg();
    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm, .class = cid } });
    return dst;
}
