//! Statement lowering. Free functions over the shared `FuncBuilder`.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const build = @import("../build.zig");

const expr_mod = @import("expr.zig");
const decl_mod = @import("decl.zig");
const helpers = @import("helpers.zig");
const literals = @import("literals.zig");
const ast_scan = @import("ast_scan.zig");
const lambda_body = @import("lambda_body.zig");
const thunks = @import("thunks.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const BinOp = ir.BinOp;
const FuncId = ir.FuncId;
const Terminator = ir.Terminator;
const StringSet = std.StringHashMap(void);

const lowerExpr = expr_mod.lowerExpr;
const lowerReceiver = expr_mod.lowerReceiver;
const exprSpan = helpers.exprSpan;
const boxedCellReg = helpers.boxedCellReg;
const widenNumericLiteral = literals.widenNumericLiteral;
const collectPathIdentsStmt = ast_scan.collectPathIdentsStmt;
const lowerLambdaBodyCapturingKindWith = lambda_body.lowerLambdaBodyCapturingKindWith;
const resolveCapture = lambda_body.resolveCapture;
const lowerExprAsParamThunk = thunks.lowerExprAsParamThunk;

fn typeRefMentionsParams(ty: *const ast.TypeRef, params: []const ast.TypeParam) bool {
    for (params) |param| {
        if (std.mem.eql(u8, ty.name.name, param.name.name)) return true;
    }
    for (ty.type_args) |*arg| {
        if (!arg.is_star and typeRefMentionsParams(&arg.ty, params)) return true;
    }
    if (ty.function) |function| {
        if (function.receiver) |*receiver| {
            if (typeRefMentionsParams(receiver, params)) return true;
        }
        for (function.context_params) |*context| {
            if (typeRefMentionsParams(context, params)) return true;
        }
        for (function.params) |*param| {
            if (typeRefMentionsParams(param, params)) return true;
        }
        if (typeRefMentionsParams(&function.ret, params)) return true;
    }
    return false;
}

fn localTypeParamBounds(
    allocator: Allocator,
    function: *const ast.Function,
) Allocator.Error![]const ir.ModuleRegistry.TypeParamBound {
    const bounds = try allocator.alloc(
        ir.ModuleRegistry.TypeParamBound,
        function.type_params.len,
    );
    for (function.type_params, bounds) |*param, *out| {
        var bound: []const u8 = "kotlin.Any";
        var complete = true;
        var head_only = true;
        var count: usize = 0;
        if (param.upper_bound) |*upper| {
            bound = upper.name.name;
            complete = !upper.nullable and upper.type_args.len == 0 and
                upper.function == null and !upper.definitely_non_null and
                upper.qualified_path == null;
            head_only = !upper.nullable and upper.function == null and
                upper.qualified_path == null and upper.name.name.len != 0;
            count += 1;
        }
        for (function.where_bounds) |*where_bound| {
            if (std.mem.eql(u8, where_bound.name.name, param.name.name)) {
                if (count == 0) {
                    const where_type = &where_bound.bound;
                    bound = where_type.name.name;
                    complete = !where_type.nullable and where_type.type_args.len == 0 and
                        where_type.function == null and !where_type.definitely_non_null and
                        where_type.qualified_path == null;
                    head_only = !where_type.nullable and where_type.function == null and
                        where_type.qualified_path == null and where_type.name.name.len != 0;
                }
                count += 1;
            }
        }
        if (count > 1) {
            complete = false;
            head_only = false;
        }
        out.* = .{
            .param = param.name.name,
            .bound = bound,
            .complete = complete,
            .head_only = head_only,
        };
    }
    return bounds;
}

/// Lower a statement, returning the register holding its value when it is a
/// tail-position expression statement, else null.
pub fn lowerStmt(b: *FuncBuilder, stmt: *const Stmt) Allocator.Error!?Reg {
    // A `Trace` marks each statement's source position so a throw, here or in any
    // call it makes, reports the line each frame is on. One span store at eval
    // time; the JIT hot loops bypass the eval dispatch entirely.
    switch (stmt.*) {
        .Expr => |*e| try b.push(.{ .Trace = .{ .span = helpers.exprSpan(e) } }),
        .Assign => |a| try b.push(.{ .Trace = .{ .span = a.span } }),
        .DestructuringDecl => |dd| try b.push(.{ .Trace = .{ .span = dd.span } }),
    // A `val x = expr` initializer can throw; other declarations have no
    // executable head.
        .Decl => |*d| switch (d.*) {
            .Property => |p| try b.push(.{ .Trace = .{ .span = p.span } }),
            else => {},
        },
    }
    switch (stmt.*) {
        .Expr => |*e| return try lowerExpr(b, e),
        .Decl => |*d| switch (d.*) {
            .Property => |p| return lowerPropertyDecl(b, p),
            .Function => |*f| return lowerLocalFnDecl(b, f),
            .Class => |*c| return lowerLocalClassDecl(b, c),
            else => return null,
        },
        .Assign => |a| {
            if (isSafeIndexTarget(&a.target)) {
                return lowerSafeIndexAssign(b, &a.target, a.op, &a.value);
            }
            if (isSafeMemberTarget(&a.target)) {
                return lowerSafeMemberAssign(b, &a.target, a.op, &a.value);
            }
            return lowerAssign(b, &a.target, a.op, &a.value);
        },
        .DestructuringDecl => |dd| return lowerDestructuringDecl(b, dd.names, dd.by_name, dd.sources, dd.mutable, &dd.init),
    }
}

/// `obj?.items[i] = v`: an `Index` target whose receiver chain is a safe `Member`.
fn isSafeIndexTarget(target: *const Expr) bool {
    return switch (target.*) {
        .Index => |idx| switch (idx.receiver.*) {
            .Member => |m| m.safe,
            else => false,
        },
        else => false,
    };
}

/// `obj?.field = v`: a safe-`Member` target.
fn isSafeMemberTarget(target: *const Expr) bool {
    return switch (target.*) {
        .Member => |m| m.safe,
        else => false,
    };
}

fn lowerPropertyDecl(b: *FuncBuilder, p: *const ast.Property) Allocator.Error!?Reg {
    tracePropertyDeclEntry(b, p);
    // `val x = expr` / `var x = expr`: the init lowers into a fresh register and
    // binds in the current scope, mutability being enforced by typeck.
    try markContextFnLocal(b, p);
    const init: Reg = try lowerPropertyInit(b, p);
    try markAnyTypedLocal(b, p);
    // Record the local's declared type, or its initializer expression when
    // un-annotated, so inline-overload receiver narrowing can type a plain local
    // receiver.
    if (p.ty) |ty| {
        try recordAnnotatedLocalType(b, p, ty);
    } else if (p.init) |*e| {
        try recordInferredLocalType(b, p, e);
        try recordLocalInitExpr(b, p, e);
        try recordLocalNonFnEvidence(b, p, e);
    }
    // Keep the source annotation for later plain assignments to this name: the
    // value of `h = { ... }` lowers under the declared type exactly as the
    // initializer did, so a receiver lambda keeps its receiver context.
    if (p.ty) |*ty| b.setLocalAstTy(p.name.name, ty);
    return try bindPropertyHome(b, p, init);
}

fn tracePropertyDeclEntry(b: *FuncBuilder, p: *const ast.Property) void {
    if (runtime.envOnce("KLIO_VALTY_TRACE")) |w| {
        if (std.mem.eql(u8, w, p.name.name)) {
            std.debug.print("[valty] enter {s} annotated={} init_tag={s} nf={d} in_fn={s} recv={s} encl={s} owner={s} tower={d}:", .{
                p.name.name,
                p.ty != null,
                if (p.init) |*e| @tagName(std.meta.activeTag(e.*)) else "-",
                b.module.funcs.items.len,
                build.currentRealFn() orelse "-",
                b.recvTy() orelse "-",
                b.enclosingRecvTy() orelse "-",
                b.ownerClass() orelse "-",
                b.implicit_receiver_tower.items.len,
            });
            for (b.implicit_receiver_tower.items) |entry| std.debug.print(" {s}", .{entry.head});
            std.debug.print("\n", .{});
        }
    }
}

/// A local holding a contextual function has a call shape, splitting leading
/// context args.
fn markContextFnLocal(b: *FuncBuilder, p: *const ast.Property) Allocator.Error!void {
    if (p.ty) |ty| {
        if (ty.function) |ft| if (ft.context_params.len != 0 and ft.receiver == null) {
            const ctx_types = try b.allocator.alloc([]const u8, ft.context_params.len);
            for (ft.context_params, 0..) |cp, ci| ctx_types[ci] = cp.name.name;
            try b.markContextFnParam(p.name.name, ctx_types, ft.params.len);
        };
    } else if (p.init) |*ie| if (ie.* == .AnonFun and ie.AnonFun.context_params.len != 0) {
        const af = ie.AnonFun;
        const ctx_types = try b.allocator.alloc([]const u8, af.context_params.len);
        for (af.context_params, 0..) |cp, ci| ctx_types[ci] = cp.ty.name.name;
        try b.markContextFnParam(p.name.name, ctx_types, af.params.len);
    };
}

/// The register the declaration's value arrives in: the delegate, the lowered
/// initializer, or the placeholder a deferred declaration starts from.
fn lowerPropertyInit(b: *FuncBuilder, p: *const ast.Property) Allocator.Error!Reg {
    return if (p.delegate) |de| blk: {
        // `val x by D` binds the delegate, after the `provideDelegate` convention, under
        // a hidden `x$klio_delegate` binding for both `val` and `var`. Kotlin dispatches
        // `getValue` on every read and `setValue` on every write, never at the
        // declaration, so a read goes through `lowerDelegateRead`. Bound as an immutable
        // val, the delegate reference itself not changing, so a nested lambda captures it
        // by value. The plain name binds the delegate too, for paths that resolve the
        // name without the delegate read.
        const delegate_expr = try lowerExpr(b, de);
        const delegate = try emitProvideDelegate(b, delegate_expr, p.name.name);
        {
            const dname = try std.fmt.allocPrint(b.allocator, "{s}$klio_delegate", .{p.name.name});
            try b.bind(dname, delegate);
        }
        break :blk delegate;
    } else switch (p.init != null) {
        true => blk: {
            const e = &p.init.?;
            // The declared type is the initializer's expectation, through generic
            // factories too.
            if (p.ty) |*ty| {
                if (expr_mod.loweredOwnedLocalTypeRef(b, ty)) |lt| {
                    var owned = lt;
                    defer owned.deinit(b.allocator);
                    expr_mod.applyExpectedLiteralKinds(b, @constCast(e), owned);
                } else |_| {}
            }
            const widened: ?Expr = if (p.ty) |*ty| widenNumericLiteral(e, ty) else null;
            // A type-annotated initializer puts its declared type in tail position so a
            // reified inline call can infer its type argument.
            const prev = b.pushExpected(p.ty);
            const r = try lowerExpr(b, if (widened) |*w| w else e);
            b.restoreExpected(prev);
            break :blk r;
        },
        // A `lateinit var` starts as `Null`, the state every read checks for; a
        // deferred-init `val` has no read before its definite assignment.
        false => try b.emitConst(if (p.is_lateinit) .Null else .Unit),
    };
}

/// `: Any` annotations are tracked so a later `==` routes through the
/// boxed-equality path.
fn markAnyTypedLocal(b: *FuncBuilder, p: *const ast.Property) Allocator.Error!void {
    if (p.ty) |ty| {
        if (std.mem.eql(u8, ty.name.name, "Any")) {
            try b.markAnyTyped(p.name.name);
        }
    }
}

/// The declared type settles the local's static type outright, along with the
/// nullability, receiver-fn, and collection evidence its head implies.
fn recordAnnotatedLocalType(b: *FuncBuilder, p: *const ast.Property, ty: ast.TypeRef) Allocator.Error!void {
    try b.setLocalDeclTypeOwned(
        p.name.name,
        try expr_mod.loweredOwnedLocalTypeRef(b, &ty),
    );
    if (ty.nullable) try b.setLocalDeclNullable(p.name.name);
    if (ty.function) |ft| {
        if (ft.receiver != null) try b.setLocalDeclRecvFn(p.name.name);
        b.clearNonFnLocal(p.name.name);
    }
    if (ty.function == null and helpers.isBroadCollectionTypeName(ty.name.name)) {
        try b.markBroadCollectionLocal(p.name.name);
    }
    if (ty.function == null and isDefiniteNonFnTypeName(ty.name.name)) {
        try b.markNonFnLocal(p.name.name);
    }
}

/// An un-annotated local takes the static type its initializer shape names.
fn recordInferredLocalType(b: *FuncBuilder, p: *const ast.Property, e: *const Expr) Allocator.Error!void {
    // Preserve the inferred static type of a simple receiver alias, the type
    // kotlinc assigns to `val outerScope = this`, which later explicit-receiver
    // extension calls need before runtime dispatch.
    switch (e.*) {
        .This => |t| if (t.qualifier == null) {
            if (b.enclosingRecvTy()) |ty| {
                try b.setLocalDeclType(p.name.name, ty);
            } else if (b.ownerClass()) |owner| {
                // Inside an ordinary member, `val self = this` is the declaring
                // class, no extension receiver being in scope.
                try b.setLocalDeclType(p.name.name, owner);
            }
        },
        .Path => |path| if (path.segments.len == 1) {
            if (b.localDeclType(path.segments[0].name)) |ty| {
                try b.setLocalDeclType(p.name.name, ty);
                if (b.localDeclNullable(path.segments[0].name)) try b.setLocalDeclNullable(p.name.name);
            }
        },
        // A cast initializer is the local's static type, with the full generic
        // reference, so a member call on it reaches resolution with the type
        // arguments applicability needs.
        .As => |cast| {
            try b.setLocalDeclTypeOwned(
                p.name.name,
                try expr_mod.loweredOwnedLocalTypeRef(b, &cast.ty),
            );
            // `as?` yields the cast type or null, so the local is nullable
            // while its head stays exact.
            if (cast.ty.nullable or cast.safe) try b.setLocalDeclNullable(p.name.name);
        },
        .Call => try recordCallInitLocalType(b, p, e),
        // The elvis arm of `staticExprTypeRef` strips the null.
        .Binary => |bin| if (bin.op == .Elvis) {
            if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                const was_nullable = ct.nullable;
                try b.setLocalDeclTypeOwned(p.name.name, ct);
                if (was_nullable) try b.setLocalDeclNullable(p.name.name);
            }
        } else {
            // A predicate operator types the local `Boolean` outright.
            if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                try b.setLocalDeclTypeOwned(p.name.name, ct);
            }
        },
        // An index initializer is an operator `get` call, so its resolved
        // return types the local, key-solved type parameter included.
        .Index => {
            if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                const was_nullable = ct.nullable;
                try b.setLocalDeclTypeOwned(p.name.name, ct);
                if (was_nullable) try b.setLocalDeclNullable(p.name.name);
            }
        },
        // An object literal's denotable type is its single supertype, and that
        // supertype is the only place its type arguments are written; the head
        // alone leaves a reified `T` with nothing to solve from.
        .ObjectExpr => {
            if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                try b.setLocalDeclTypeOwned(p.name.name, ct);
            }
        },
        // Shapes that name their own type: a cast states it, `this` is the
        // enclosing class, `!x` is Boolean, `-x` keeps its operand's type.
        .Unary, .If, .When => {
            if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                const was_nullable = ct.nullable;
                try b.setLocalDeclTypeOwned(p.name.name, ct);
                if (was_nullable) try b.setLocalDeclNullable(p.name.name);
            }
        },
        else => {},
    }
}

/// A call initializer's declared return type is the local's static type,
/// the same derivation the destructuring arm trusts. Argument shapes
/// built from the local then refute inapplicable members.
fn recordCallInitLocalType(b: *FuncBuilder, p: *const ast.Property, e: *const Expr) Allocator.Error!void {
    const vt = runtime.envOnce("KLIO_VALTY_TRACE");
    if (try expr_mod.staticExprTypeRef(b, e)) |ct0| {
        var ct = ct0;
        // A star-erased return-position parameter re-derives from the
        // call's trailing lambda; recorder-level only.
        try expr_mod.patchStarredCallRecord(b, &ct, e);
        if (vt) |w| if (std.mem.eql(u8, w, p.name.name))
            std.debug.print("[valty] {s} = {s} nargs={d} a0={s} mod={x} classes={d}\n", .{ p.name.name, ct.name, ct.args.len, if (ct.args.len != 0) ct.args[0].name else "-", @intFromPtr(b.module) & 0xffff, b.module.classes.items.len });
        const was_nullable = ct.nullable;
        try b.setLocalDeclTypeOwned(p.name.name, ct);
        if (was_nullable) try b.setLocalDeclNullable(p.name.name);
    } else if (vt) |w| {
        if (std.mem.eql(u8, w, p.name.name))
            std.debug.print("[valty] {s} = <null> mod={x} classes={d}\n", .{ p.name.name, @intFromPtr(b.module) & 0xffff, b.module.classes.items.len });
    }
}

/// Literal initializers are recorded as definite non-callable evidence.
fn recordLocalInitExpr(b: *FuncBuilder, p: *const ast.Property, e: *const Expr) Allocator.Error!void {
    switch (e.*) {
        // A property read lends the property's registered type head to the
        // local, which the declared-type channel reads back. A binary init
        // carries the numeric-promotion evidence the deriver's arm answers.
        .Call, .IntLit, .FloatLit, .BoolLit, .CharLit, .StringTemplate, .Binary, .Unary, .Postfix => try b.setLocalInitExprAt(p.name.name, e, p.name.span),
        // A property read and an indexed read each carry a static type of their
        // own: `val held = row[1]` is `Row.get`'s return type.
        .Member, .Index, .Path => if (!std.mem.eql(u8, runtime.envOnce("KLIO_MEMBER_INIT") orelse "1", "0"))
            try b.setLocalInitExprAt(p.name.name, e, p.name.span),
        // A single-supertype object literal's denotable type is that supertype,
        // which the deriver's ObjectExpr arm answers.
        .ObjectExpr => {
            try b.markObjectInitLocal(p.name.name);
            try b.setLocalInitExprAt(p.name.name, e, p.name.span);
        },
        else => {},
    }
}

/// A literal init is definite non-callable evidence that must survive into
/// nested lambda bodies: a captured `var key = 0` does not shadow the
/// `key(...) {}` composable for a call.
fn recordLocalNonFnEvidence(b: *FuncBuilder, p: *const ast.Property, e: *const Expr) Allocator.Error!void {
    switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .CharLit, .StringTemplate => try b.markNonFnLocal(p.name.name),
        .Lambda, .AnonFun => b.clearNonFnLocal(p.name.name),
        else => {
            // Any initializer whose static type is a class with no `invoke` is
            // non-callable evidence too, whatever its shape. Gated on a
            // same-named bare-call candidate existing, so the derivation runs
            // only where the answer can matter.
            if (b.module.hasBareCallCandidate(p.name.name, p.name.span.file) and
                try initTypeIsNonInvokable(b, e))
            {
                try b.markNonFnLocal(p.name.name);
            }
        },
    }
}

/// Allocate a home register and Move the init value into it for `var`, or for a
/// `val` with no initializer, where multiple branches assign before the first
/// read; that gives reads slot semantics under the flat block IR, while a
/// `val foo = expr` is fixed at decl time.
fn bindPropertyHome(b: *FuncBuilder, p: *const ast.Property, init: Reg) Allocator.Error!?Reg {
    if (b.isBoxed(p.name.name)) {
        // A captured `var` boxes into a shared cell so writes from a nested closure
        // are visible here, per Kotlin `Ref` semantics.
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = init } });
        try b.setMutableHome(p.name.name, home);
        try b.markMutable(p.name.name);
        try b.bind(p.name.name, home);
        if (p.is_lateinit) try b.bind(try expr_mod.lateinitMarkerName(b, p.name.name), home);
    } else if (p.mutable or p.init == null) {
        const home = b.allocReg();
        try b.push(.{ .Move = .{ .dst = home, .src = init } });
        try b.setMutableHome(p.name.name, home);
        if (p.mutable) {
            try b.markMutable(p.name.name);
        }
        try b.bind(p.name.name, home);
        if (p.is_lateinit) try b.bind(try expr_mod.lateinitMarkerName(b, p.name.name), home);
    } else {
        // `val x = y` where `y` is a reassignable var reads `y`'s home register, and
        // a later write to `y` would alias into `x`. Snapshot into a fresh register:
        // in Kotlin a val captures the value, not the variable.
        if (p.init) |*ie| {
            if (ie.* == .Path and ie.Path.segments.len == 1 and
                b.mutableHome(ie.Path.segments[0].name) != null)
            {
                const fresh = b.allocReg();
                try b.push(.{ .Move = .{ .dst = fresh, .src = init } });
                try b.bind(p.name.name, fresh);
                return null;
            }
        }
        try b.bind(p.name.name, init);
    }
    return null;
}

/// The state the local-fn lowering phases share. A value lives here only when
/// more than one phase reads or writes it; scratch a single phase owns stays a
/// local of that phase.
const LocalFnCtx = struct {
    b: *FuncBuilder,
    f: *const ast.Function,
    dummy_span: span.Span,
    /// The block the closure lowers: the declared body, or the synthetic
    /// single-statement block an expression body maps to.
    body: ast.Block,
    /// The shared cell a self-capturing declaration binds itself through.
    self_cell: ?Reg,

    /// The mangled sibling binding, settled by `registerMangledOverload`.
    mangled_cell: Reg = undefined,
    mangled_name: []const u8 = undefined,

    /// The enclosing environment, settled by `captureEnclosingEnv` and handed
    /// to the shared lambda-body lowering.
    is_ext: bool = undefined,
    param_idents: []ast.Ident = undefined,
    param_tys: []?ast.TypeRef = undefined,
    outer_names: StringSet = undefined,
    inherited_rlp: StringSet = undefined,
    outer_boxed: StringSet = undefined,
    inherited_lef: std.StringHashMap(i8) = undefined,
    inherited_erp: StringSet = undefined,
    tailrec_self: ?[]const u8 = undefined,
    enclosing_owner: ?lambda_body.EnclosingOwner = undefined,
    encl_recv: bool = undefined,
};

fn lowerLocalFnDecl(b: *FuncBuilder, f: *const ast.Function) Allocator.Error!?Reg {
    // A local fn lowers as a closure capturing the enclosing scope's visible names,
    // bound to its declared name, equivalent to `val name = { ... }`. Block-body and
    // expression-body forms both map to a synthetic single-statement Block.
    const span_mod = @import("span");
    const dummy_span = span_mod.Span.init(span_mod.FileId.from(0), 0, 0);
    const body_block: ?ast.Block = if (f.body) |fb| switch (fb) {
        .Block => |blk| blk,
        .Expr => |e| body: {
            const stmts = try b.allocator.alloc(Stmt, 1);
            stmts[0] = .{ .Expr = e };
            break :body ast.Block{ .stmts = stmts, .span = dummy_span };
        },
    } else null;
    if (body_block) |body| {
        const self_cell = try localFnSelfCell(b, f, &body);
        var ctx = LocalFnCtx{
            .b = b,
            .f = f,
            .dummy_span = dummy_span,
            .body = body,
            .self_cell = self_cell,
        };
        try markRecursiveLocalExtFn(&ctx);
        try registerMangledOverload(&ctx);
        try captureEnclosingEnv(&ctx);
        defer releaseEnclosingEnv(&ctx);
        publishPendingContextParams(&ctx);
        try publishPendingTypeParams(&ctx);
        try publishPendingReceiverScope(&ctx);
        try publishPendingBodyShape(&ctx);
        // Vararg param names: the body registers the materialized array head, not
        // the annotated element type.
        var vararg_names: std.ArrayList([]const u8) = .empty;
        defer vararg_names.deinit(b.allocator);
        for (f.params) |p| {
            if (p.is_vararg) try vararg_names.append(b.allocator, p.name.name);
        }
        b.module.pending_lambda_vararg_params = if (vararg_names.items.len != 0) vararg_names.items else null;
        defer b.module.pending_lambda_vararg_params = null;
        // A bare `return` in an argument lambda nested in this local fn returns
        // from the local fn, not the enclosing real function, so push the local
        // fn's name as the label and name the body func so the unwind stops here.
        const prev_real_fn = build.pushCurrentRealFn(f.name.name);
        defer build.popCurrentRealFn(prev_real_fn);
        const lowered = try lowerLambdaBodyCapturingKindWith(
            b.module,
            ctx.param_idents,
            ctx.param_tys,
            &ctx.body,
            ctx.outer_names,
            true,
            &ctx.outer_boxed,
            ctx.tailrec_self,
            true,
            ctx.encl_recv,
            ctx.inherited_rlp,
            ctx.inherited_lef,
            ctx.inherited_erp,
            &b.local_fn_overloads,
            ctx.enclosing_owner,
        );
        stampLocalFnVarargParams(&ctx, lowered.func);
        const dst = try emitLocalFnClosure(&ctx, lowered);
        try bindLocalFnName(&ctx, dst);
    }
    return null;
}

/// A recursive local extension binds its own name before the body lowers, so
/// a self-call inside resolves to the in-scope closure, which takes the
/// receiver as its leading parameter, instead of a runtime member lookup.
fn markRecursiveLocalExtFn(ctx: *LocalFnCtx) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    if (ctx.self_cell != null and f.receiver_type != null) {
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
        try b.markLocalFn(f.name.name);
        try b.markLocalExtFn(f.name.name, @intCast(@min(f.params.len - recv_off, 127)));
    }
}

/// Same-named sibling declarations are overloads, not rebindings, so register
/// this declaration's signature and bind its mangled sibling name to a
/// dedicated cell before the body lowers; a call inside any sibling's body
/// then selects the applicable overload instead of recursing through the
/// shared plain-name self-cell.
fn registerMangledOverload(ctx: *LocalFnCtx) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    const ov_tys = try b.allocator.alloc(?[]const u8, f.params.len);
    var overload_transferred = false;
    errdefer if (!overload_transferred) b.allocator.free(ov_tys);
    const ov_names = try b.allocator.alloc([]const u8, f.params.len);
    errdefer if (!overload_transferred) b.allocator.free(ov_names);
    var n_required: usize = 0;
    var has_vararg = false;
    for (f.params, 0..) |p, j| {
        ov_tys[j] = if (p.is_vararg) null else p.ty.name.name;
        ov_names[j] = p.name.name;
        if (p.is_vararg) has_vararg = true else if (p.default == null) n_required += 1;
    }
    // A pass-threaded composable local fn carries a trailing
    // ($composer, $changed) pair the call site never writes, so the pair
    // never counts toward the required arity.
    if (f.params.len >= 2 and n_required >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 1].name.name, "$changed") and
        std.mem.eql(u8, f.params[f.params.len - 2].name.name, "$composer"))
    {
        n_required -= 2;
    }
    const ordinal = if (b.local_fn_overloads.getPtr(f.name.name)) |l| l.items.len else 0;
    // Module-lifetime: the mangled name ships inside the AstLambda
    // instruction's captured-name list, read at runtime.
    const mangled = try std.fmt.allocPrint(b.module.func_name_index.allocator, "{s}$ovl{d}", .{ f.name.name, ordinal });
    ctx.mangled_name = mangled;
    const null_v = try b.emitConst(.Null);
    const home = b.allocReg();
    try b.push(.{ .MakeCell = .{ .dst = home, .src = null_v } });
    try b.bind(mangled, home);
    try b.markBoxed(mangled);
    try b.markLocalFn(mangled);
    if (f.receiver_type != null) {
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
        try b.markLocalExtFn(mangled, @intCast(@min(f.params.len - recv_off, 127)));
    }
    if (f.params.len != 0) try b.setLocalFnParamTys(mangled, ov_tys);
    if (f.return_type) |*rt| {
        try b.setLocalFnReturnTy(mangled, try expr_mod.loweredOwnedLocalTypeRef(b, rt));
    } else if (f.body != null and f.body.? == .Expr) {
        try deriveMangledReturnTy(ctx, mangled);
    }
    const receiver_ty = if (f.receiver_type) |*source_receiver|
        try expr_mod.loweredOwnedLocalTypeRef(b, source_receiver)
    else
        null;
    errdefer if (!overload_transferred) if (receiver_ty) |receiver| {
        var cleanup = receiver;
        cleanup.deinit(b.allocator);
    };
    const local_type_params = try localTypeParamBounds(b.allocator, f);
    errdefer if (!overload_transferred) b.allocator.free(local_type_params);
    overload_transferred = true;
    try b.addLocalFnOverload(f.name.name, .{
        .mangled = mangled,
        .receiver_ty = receiver_ty,
        .receiver_has_type_params = if (f.receiver_type) |*source_receiver|
            typeRefMentionsParams(source_receiver, f.type_params)
        else
            false,
        .type_params = local_type_params,
        .param_tys = ov_tys,
        .param_names = ov_names,
        .n_required = n_required,
        .has_vararg = has_vararg,
        .is_ext = f.receiver_type != null,
    });
    ctx.mangled_cell = home;
}

/// An unannotated expression body's return derives at the declaration under the
/// params' declared types, so a val-init calling the local fn types.
fn deriveMangledReturnTy(ctx: *LocalFnCtx, mangled: []const u8) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    const PSave = struct { name: []const u8, ty: ?ir.TypeRef };
    var psaves: std.ArrayList(PSave) = .empty;
    defer {
        for (psaves.items) |*sv| {
            b.clearLocalDeclType(sv.name);
            if (sv.ty) |t| b.setLocalDeclTypeOwned(sv.name, t) catch {};
        }
        psaves.deinit(b.allocator);
    }
    var shadow_ok = true;
    for (f.params) |*p| {
        const prev: ?ir.TypeRef = if (b.localDeclTypeRef(p.name.name)) |t|
            t.clone(b.allocator) catch null
        else
            null;
        psaves.append(b.allocator, .{ .name = p.name.name, .ty = prev }) catch {
            shadow_ok = false;
            break;
        };
        b.clearLocalDeclType(p.name.name);
        const lowered = expr_mod.loweredOwnedLocalTypeRef(b, &p.ty) catch {
            shadow_ok = false;
            break;
        };
        b.setLocalDeclTypeOwned(p.name.name, lowered) catch {
            shadow_ok = false;
            break;
        };
    }
    if (shadow_ok) {
        if (expr_mod.staticExprTypeRef(b, &f.body.?.Expr) catch null) |derived0| {
            var derived = derived0;
            var h = std.mem.trimEnd(u8, derived.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                ir.parseClassTypeParamIdentity(h) != null;
            if (h.len != 0 and !bare) {
                try b.setLocalFnReturnTy(mangled, derived);
            } else {
                derived.deinit(b.allocator);
            }
        }
    }
}

/// Snapshot the enclosing scope the body lowering reads: the visible names, the
/// boxed-var set, the parameter slots, and the receiver evidence.
fn captureEnclosingEnv(ctx: *LocalFnCtx) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    ctx.outer_names = try b.visibleNames();
    ctx.inherited_rlp = try b.receiverLambdaParamNames();
    try b.stashRecvHeadsForLambda();
    ctx.outer_boxed = try b.boxedVarsSnapshot();
    errdefer ctx.outer_boxed.deinit();
    // A local extension function binds its receiver as the implicit first
    // `this` param so the body's bare member refs resolve. Call sites prepend
    // the receiver.
    ctx.is_ext = f.receiver_type != null;
    ctx.param_idents = try b.allocator.alloc(ast.Ident, f.params.len + @intFromBool(ctx.is_ext));
    errdefer b.allocator.free(ctx.param_idents);
    ctx.param_tys = try b.allocator.alloc(?ast.TypeRef, f.params.len + @intFromBool(ctx.is_ext));
    errdefer b.allocator.free(ctx.param_tys);
    fillLocalFnParamSlots(ctx);
    ctx.tailrec_self = if (f.is_tailrec) f.name.name else null;
    ctx.enclosing_owner = if (b.ownerClass()) |o|
        .{ .class = o, .members = try b.enclosingMembersForChild() }
    else
        null;
    ctx.inherited_lef = try b.localExtFnNames();
    ctx.inherited_erp = try b.erasedRecvParamNames();
    ctx.encl_recv = b.capturesThisSlot() or
        (!b.this_is_plain_param and b.resolve("this") != null) or
        b.ownerClass() != null or b.isParamThunk() or b.recvTy() != null;
}

/// Release what `captureEnclosingEnv` took, in the reverse order it took it.
fn releaseEnclosingEnv(ctx: *LocalFnCtx) void {
    ctx.b.allocator.free(ctx.param_tys);
    ctx.b.allocator.free(ctx.param_idents);
    ctx.outer_boxed.deinit();
}

/// Fill the body's parameter slots, a local extension fn's implicit `this`
/// receiver leading.
fn fillLocalFnParamSlots(ctx: *LocalFnCtx) void {
    const f = ctx.f;
    const offset = @intFromBool(ctx.is_ext);
    if (ctx.is_ext) {
        ctx.param_idents[0] = .{ .name = "this", .span = ctx.dummy_span };
        ctx.param_tys[0] = f.receiver_type;
    }
    for (f.params, 0..) |p, i| {
        ctx.param_idents[offset + i] = p.name;
        ctx.param_tys[offset + i] = p.ty;
    }
}

/// A local contextual function binds its context parameters in the body;
/// stash them for the shared lambda-body lowering.
fn publishPendingContextParams(ctx: *LocalFnCtx) void {
    const b = ctx.b;
    const f = ctx.f;
    if (f.context_params.len != 0) {
        b.module.has_context_decls = true;
        b.module.pending_ctx = .{ .params = f.context_params, .type_params = f.type_params };
    }
}

/// The enclosing type parameters and their bounds cross into the body, with
/// this declaration's own appended.
fn publishPendingTypeParams(ctx: *LocalFnCtx) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    var pending_type_params: std.ArrayList([]const u8) = .empty;
    if (try b.typeParamNamesSlice()) |outer_params| {
        defer b.allocator.free(outer_params);
        try pending_type_params.appendSlice(b.allocator, outer_params);
    }
    for (f.type_params) |param| try pending_type_params.append(b.allocator, param.name.name);
    b.module.pending_lambda_type_params = if (pending_type_params.items.len == 0)
        null
    else
        try pending_type_params.toOwnedSlice(b.allocator);
    defer pending_type_params.deinit(b.allocator);

    var pending_bounds: std.ArrayList(ir.ModuleRegistry.TypeParamBound) = .empty;
    if (try b.typeParamBoundsSlice()) |outer_bounds| {
        defer b.allocator.free(outer_bounds);
        try pending_bounds.appendSlice(b.allocator, outer_bounds);
    }
    const own_bounds = try localTypeParamBounds(b.allocator, f);
    defer b.allocator.free(own_bounds);
    try pending_bounds.appendSlice(b.allocator, own_bounds);
    b.module.pending_lambda_type_param_bounds = if (pending_bounds.items.len == 0)
        null
    else
        try pending_bounds.toOwnedSlice(b.allocator);
    defer pending_bounds.deinit(b.allocator);
}

/// The bound refs, context-fn shapes and receiver tower the body resolves
/// against.
fn publishPendingReceiverScope(ctx: *LocalFnCtx) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    b.module.pending_lambda_type_param_bound_refs = try b.typeParamBoundRefsSlice();
    b.module.pending_lambda_ctx_fn_shapes = try b.contextFnShapesSlice();
    // The receiver type in scope inside this body: a local extension fn's own
    // declared receiver, innermost and winning bare-call disambiguation, else
    // the enclosing receiver, exactly as a receiver lambda carries it.
    b.module.pending_lambda_receiver_tower = try b.collectReceiverTowerLabeled(
        b.allocator,
        if (f.receiver_type) |r| r.name.name else null,
        if (f.receiver_type != null) f.name.name else null,
    );
    // The local extension fn's receiver answers to `this@<name>` exactly as a
    // top-level extension's does, so the body binds the label and nested scopes
    // reach the value.
    if (f.receiver_type != null) b.module.pending_lambda_this_label = f.name.name;
    b.module.pending_lambda_enclosing_recv = if (f.receiver_type) |r|
        r.name.name
    else
        b.enclosingRecvTy();
    if (f.receiver_type) |*receiver| {
        b.module.pending_lambda_own_recv = receiver.name.name;
        b.module.pending_lambda_own_recv_type =
            try expr_mod.loweredOwnedLocalTypeRef(b, receiver);
    }
}

/// The body's fall-through rule, its self-reference route, and the enclosing
/// locals' evidence.
fn publishPendingBodyShape(ctx: *LocalFnCtx) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    // A local `fun` with a block body returns Unit on fall-through, never its
    // tail statement's value; an expression body keeps the expression as the
    // return. Mirrors the top-level and member block-body rule.
    b.module.pending_lambda_fn_block_body = f.body != null and f.body.? == .Block;
    // The body, and any lambda nested in it, must route a bare self-reference
    // through the mangled cell: the plain-name slot is rebound by a later
    // same-named sibling, so a self re-invoke captured by name would run it.
    b.module.pending_lambda_self_fn = .{ .name = f.name.name, .mangled = ctx.mangled_name };
    // Non-callable-local evidence flows into the body.
    b.module.pending_lambda_nonfn_locals = try b.nonFnLocalNames();
    // The enclosing locals' declared types cross into the local fn's body
    // exactly as they cross into a lambda's. Derived-init locals resolve here,
    // the only scope their initializers were written in.
    b.module.pending_lambda_local_decl_types = try b.localDeclTypesSnapshot();
    if (b.module.pending_lambda_local_decl_types) |*locals| {
        var init_it = b.localInitExprIterator();
        while (init_it.next()) |e| {
            if (locals.types.contains(e.key_ptr.*)) continue;
            const derived = expr_mod.staticExprTypeRef(b, e.value_ptr.*) catch null;
            if (derived) |ty| try locals.types.put(e.key_ptr.*, ty);
        }
    }
}

/// The lambda-body lowering builds params with `is_vararg = false`, lambdas
/// being unable to declare varargs, while a local function can and the
/// closure invocation's packing keys on the flag, so stamp them back.
fn stampLocalFnVarargParams(ctx: *LocalFnCtx, body_func: FuncId) void {
    const b = ctx.b;
    const f = ctx.f;
    const offset = @intFromBool(ctx.is_ext);
    if (b.module.funcByIdMut(body_func)) |bf| {
        for (f.params, 0..) |p, i| {
            const pi = offset + i;
            if (pi < bf.params.len) bf.params[pi].is_vararg = p.is_vararg;
        }
        // Carry the declared name so `frameMatchesLabel` stops a nested
        // lambda's non-local return at this frame.
        bf.name = f.name.name;
        bf.lambda_receiver_shape_known = true;
    }
}

/// Resolve the body's captures in the enclosing frame and emit the closure.
fn emitLocalFnClosure(ctx: *LocalFnCtx, lowered: lambda_body.LoweredLambda) Allocator.Error!Reg {
    const b = ctx.b;
    const f = ctx.f;
    const body_func = lowered.func;
    const captured_names = lowered.captures;
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *slot| slot.* = try resolveCapture(b, n);
    var param_names = try b.allocator.alloc([]const u8, f.params.len + @intFromBool(ctx.is_ext));
    {
        const offset = @intFromBool(ctx.is_ext);
        if (ctx.is_ext) param_names[0] = "this";
        for (f.params, 0..) |p, i| param_names[offset + i] = p.name.name;
    }
    try registerLocalFnDefaults(b, f, ctx.is_ext, param_names, body_func);
    const dst = b.allocReg();
    try b.push(.{ .AstLambda = .{
        .dst = dst,
        .params = param_names,
        .body_ast = ctx.body,
        .captures = captures,
        .captured_names = captured_names,
        .absorb_return = true,
        .body_func = body_func,
    } });
    return dst;
}

/// Bind the built closure to its declared name and record the evidence a bare
/// reference and a call site read.
fn bindLocalFnName(ctx: *LocalFnCtx, dst: Reg) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    // A same-named local property owns the plain-name binding; the fun is
    // reachable through its mangled overload cell, since Kotlin resolves the
    // bare reference to the property and only a call picks the fun.
    const name_is_property = ctx.self_cell == null and b.mutableHome(f.name.name) != null and
        !b.isLocalFn(f.name.name);
    if (ctx.self_cell) |home| {
        try b.push(.{ .CellSet = .{ .cell = home, .value = dst } });
    } else if (!name_is_property) {
        try b.bind(f.name.name, dst);
    }
    if (!name_is_property) try b.markLocalFn(f.name.name);
    if (ctx.is_ext and !name_is_property) {
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
        try b.markLocalExtFn(f.name.name, @intCast(@min(f.params.len - recv_off, 127)));
    }
    // Record positional parameter type names, dropping a leading `this`
    // receiver, so a literal argument coerces to a numeric primitive parameter
    // at the call site.
    {
        const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
        if (f.params.len > recv_off) {
            const tys = try b.allocator.alloc(?[]const u8, f.params.len - recv_off);
            defer b.allocator.free(tys);
            for (tys, 0..) |*t, j| {
                const p = f.params[recv_off + j];
                t.* = if (p.is_vararg) null else p.ty.name.name;
            }
            try b.setLocalFnParamTys(f.name.name, tys);
        }
    }
    // The mangled sibling binding, registered before the body lowered, receives
    // the built closure.
    try b.push(.{ .CellSet = .{ .cell = ctx.mangled_cell, .value = dst } });
}

// A local function that calls itself is desugared like
// `var name = null; name = { … name(…) … }`: a shared cell is created first so the
// body can capture it, and the closure stores itself there once built. A cell
// pre-hoisted by `lowerBlock` for mutually capturing siblings is reused.
fn localFnSelfCell(
    b: *FuncBuilder,
    f: *const ast.Function,
    body: *const ast.Block,
) Allocator.Error!?Reg {
    var self_refs = StringSet.init(b.allocator);
    defer self_refs.deinit();
    // A local extension function refers to itself in member-call position, which
    // the bare-identifier scan never reaches, so collect member-call names into the
    // same set and let the recursion cell be built.
    var call_names = StringSet.init(b.allocator);
    defer call_names.deinit();
    for (body.stmts) |*s| try ast_scan.collectIdentsAndCallNamesStmt(s, &self_refs, &call_names);
    if (f.receiver_type != null and call_names.contains(f.name.name)) {
        try self_refs.put(f.name.name, {});
    }
    // Reuse an existing mutable home only when it belongs to a previous local fn of
    // the name. A same-named local property keeps its own cell: storing the closure
    // into the var's cell would clobber the property on every bare read.
    if (b.mutableHome(f.name.name)) |home| {
        if (b.isLocalFn(f.name.name)) return home;
        return null;
    } else if (self_refs.contains(f.name.name)) {
        const null_v = try b.emitConst(.Null);
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = null_v } });
        try b.setMutableHome(f.name.name, home);
        try b.markMutable(f.name.name);
        try b.markBoxed(f.name.name);
        try b.bind(f.name.name, home);
        return home;
    } else {
        return null;
    }
}

// Per-param defaults: lower each default expression as a thunk binding the lowered
// param prefix, so `b = a + 1` can read an earlier param, and register it under the
// body FuncId. The Vm pads missing trailing args from these.
fn registerLocalFnDefaults(
    b: *FuncBuilder,
    f: *const ast.Function,
    is_ext: bool,
    param_names: []const []const u8,
    body_func: FuncId,
) Allocator.Error!void {
    var any_default = false;
    for (f.params) |p| {
        if (p.default != null) {
            any_default = true;
            break;
        }
    }
    if (!any_default) return;

    const offset: usize = @intFromBool(is_ext);
    var slots: std.ArrayList(?FuncId) = .empty;
    errdefer slots.deinit(b.module.registry.allocator);
    const reg_alloc = b.module.registry.allocator;
    var i: usize = 0;
    while (i < offset) : (i += 1) try slots.append(reg_alloc, null);
    for (f.params, 0..) |p, idx| {
        if (p.default) |default_expr| {
            const bind_upto = @min(offset + idx, param_names.len);
            const widened = widenNumericLiteral(default_expr, &p.ty);
            const name = try std.fmt.allocPrint(
                b.allocator,
                "__default_local_{s}_{s}",
                .{ f.name.name, p.name.name },
            );
            const fid = try lowerExprAsParamThunk(
                b.module,
                param_names[0..bind_upto],
                if (widened) |*w| w else default_expr,
                name,
            );
            try slots.append(reg_alloc, fid);
        } else {
            try slots.append(reg_alloc, null);
        }
    }
    try b.module.registry.local_fn_defaults.put(body_func, slots);
}

fn lowerSafeIndexAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    // `obj?.items[i] = v`: null-guard the outer Index assignment when the receiver
    // chain is a safe Member.
    const idx = target.Index;
    const receiver = idx.receiver;
    const idx_args = idx.args;
    const idx_span = idx.span;
    const member = receiver.Member;
    const outer = member.receiver;
    const mname = member.name;
    const mspan = member.span;

    const outer_r = try lowerExpr(b, outer);
    const null_r = try b.emitConst(.Null);
    const is_null = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = is_null,
        .op = .Eq,
        .lhs = outer_r,
        .rhs = null_r,
    } });
    const skip = try b.allocBlock();
    const do_set = try b.allocBlock();
    const join = try b.allocBlock();
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = skip, .f = do_set } });
    b.switchTo(do_set);
    // Synthesize the non-safe equivalent and recurse.
    const inner_recv = try b.allocator.create(Expr);
    inner_recv.* = .{ .Member = .{
        .receiver = outer,
        .name = mname,
        .safe = false,
        .span = mspan,
    } };
    const inner_target = Expr{ .Index = .{
        .receiver = inner_recv,
        .args = idx_args,
        .span = idx_span,
    } };
    const synth = Stmt{ .Assign = .{
        .target = inner_target,
        .op = op,
        .value = value.*,
        .span = idx_span,
    } };
    _ = try lowerStmt(b, &synth);
    b.terminate(.{ .Goto = join });
    b.switchTo(skip);
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return null;
}

fn lowerSafeMemberAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    // `obj?.field = v`, or compound `?.field += v`: a null receiver skips the
    // assignment entirely, otherwise fall through to the regular non-safe assign
    // path with the safe flag cleared.
    const member = target.Member;
    const receiver = member.receiver;
    const name = member.name;
    const member_span = member.span;

    const recv_r = try lowerExpr(b, receiver);
    const null_r = try b.emitConst(.Null);
    const is_null = b.allocReg();
    try b.push(.{ .BinOp = .{
        .dst = is_null,
        .op = .Eq,
        .lhs = recv_r,
        .rhs = null_r,
    } });
    const skip = try b.allocBlock();
    const do_set = try b.allocBlock();
    const join = try b.allocBlock();
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = skip, .f = do_set } });
    b.switchTo(do_set);
    // Synthesize an equivalent non-safe assign and recurse through `Stmt::Assign`,
    // so compound semantics and property setters reuse that path.
    const inner_target = Expr{ .Member = .{
        .receiver = receiver,
        .name = name,
        .safe = false,
        .span = member_span,
    } };
    const synth = Stmt{ .Assign = .{
        .target = inner_target,
        .op = op,
        .value = value.*,
        .span = member_span,
    } };
    _ = try lowerStmt(b, &synth);
    b.terminate(.{ .Goto = join });
    b.switchTo(skip);
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return null;
}

/// Whether the current `this` is an inline-splice receiver whose type is known, is
/// not the enclosing member's owner class, and does not declare `name` as a
/// property, so a bare write must not SetField on it. Unknown shapes answer false.
fn spliceReceiverHidesMember(b: *FuncBuilder, name: []const u8) bool {
    const recv = b.spliceRecvTy() orelse b.spliceHintRecv() orelse return false;
    var head = std.mem.trimEnd(u8, recv, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (std.mem.findScalarLast(u8, head, '.')) |d| head = head[d + 1 ..];
    const owner = b.ownerClass() orelse return false;
    if (std.mem.eql(u8, head, owner)) return false;
    // The receiver type declares the property itself: the SetField is right.
    if (@import("inline_state.zig").memberPropAst(head, name) != null) return false;
    if (b.module.classId(head)) |cid| {
        if (cid.int() < b.module.classes.items.len) {
            const c = &b.module.classes.items[cid.int()];
            for (c.primary_params) |*pp| {
                if (std.mem.eql(u8, pp.name, name)) return false;
            }
        }
    }
    return true;
}

/// Heads that carry an element type for `+=` and `-=` purposes.
fn containerHead(name: []const u8) bool {
    const heads = [_][]const u8{
        "List",           "MutableList",  "ArrayList",       "Collection",
        "MutableCollection", "Iterable",  "Set",             "MutableSet",
        "HashSet",        "LinkedHashSet", "Sequence",       "Array",
    };
    for (heads) |h| if (std.mem.eql(u8, name, h)) return true;
    return false;
}

/// `xs += y` where `xs: MutableList<List<T>>` and `y: List<T>` appends one element:
/// `plusAssign(element: T)` beats `plusAssign(elements: Iterable<T>)` because a
/// `List<T>` is not an `Iterable<List<T>>`. The runtime decides on the argument's
/// tag alone and would flatten, so when the receiver's declared element type is
/// itself the container being added, name the single-element member directly.
/// `compoundTargetDeclType` is the declared type, with arguments, of a
/// compound-assignment target: a local's annotation, or the owning class's property
/// declaration when the target names a member.
fn declaredTargetTypeRef(b: *FuncBuilder, target: *const Expr) ?ast.TypeRef {
    switch (target.*) {
        .Path => |pth| {
            if (pth.segments.len != 1) return null;
            const nm = pth.segments[0].name;
            if (b.localAstTy(nm)) |t| return t.*;
            if (b.resolve(nm) != null or b.knowsOuter(nm)) return null;
            const owner = b.ownerClass() orelse return null;
            const prop = @import("inline_state.zig").memberPropAst(owner, nm) orelse return null;
            return prop.ty;
        },
        .Member => |m| {
            if (m.safe) return null;
            var rty = (expr_mod.staticExprTypeRef(b, m.receiver) catch null) orelse return null;
            defer rty.deinit(b.allocator);
            const head = expr_mod.typeHead(std.mem.trimEnd(u8, rty.name, "?"));
            const prop = @import("inline_state.zig").memberPropAst(head, m.name.name) orelse return null;
            return prop.ty;
        },
        else => return null,
    }
}

fn compoundSingleElementMember(
    b: *FuncBuilder,
    target: *const Expr,
    value: *const Expr,
    op: ast.AssignOp,
) Allocator.Error!?[]const u8 {
    const member: []const u8 = switch (op) {
        .Add => "add",
        .Sub => "remove",
        else => return null,
    };
    // The receiver's declared type with its arguments: a local's annotation, or the
    // owning class's property declaration for a member. The static deriver answers
    // heads without arguments for a member, which is what this rule needs.
    const decl_ty: ast.TypeRef = (declaredTargetTypeRef(b, target) orelse return null);
    if (decl_ty.type_args.len != 1 or decl_ty.type_args[0].is_star) return null;
    if (!containerHead(expr_mod.typeHead(decl_ty.name.name))) return null;
    const elem_head = expr_mod.typeHead(decl_ty.type_args[0].ty.name.name);
    if (!containerHead(elem_head)) return null;

    var val_ty = (expr_mod.staticExprTypeRef(b, value) catch null) orelse return null;
    defer val_ty.deinit(b.allocator);
    const val_head = expr_mod.typeHead(std.mem.trimEnd(u8, val_ty.name, "?"));
    if (!containerHead(val_head)) return null;
    // A value whose own element type is the receiver's element type is the
    // iterable form.
    if (val_ty.args.len == 1 and
        std.mem.eql(u8, expr_mod.typeHead(std.mem.trimEnd(u8, val_ty.args[0].name, "?")), elem_head)) return null;
    return member;
}

/// Whether an initializer's static type is a class that can never take a call:
/// no `invoke` member and no applicable `invoke` extension.
fn initTypeIsNonInvokable(b: *FuncBuilder, e: *const Expr) Allocator.Error!bool {
    var ty = (expr_mod.staticExprTypeRef(b, e) catch null) orelse return false;
    defer ty.deinit(b.allocator);
    const head = expr_mod.typeHead(std.mem.trimEnd(u8, ty.name, "?"));
    if (head.len == 0) return false;
    if (std.mem.startsWith(u8, head, "Function")) return false;
    if (std.mem.eql(u8, head, "<function>")) return false;
    const cid = b.module.uniqueClassIdBySimpleName(head) orelse b.module.classId(head) orelse return false;
    if (cid.int() >= b.module.classes.items.len) return false;
    const cls = &b.module.classes.items[cid.int()];
    const methods = b.module.registry.hierarchy_methods.get(cls.fqn) orelse
        b.module.registry.hierarchy_methods.get(cls.name) orelse return false;
    if (methods.contains("invoke")) return false;
    return b.module.extCouldApplyWhy(b.allocator, cls.name, "invoke", 1) == .none;
}

fn lowerAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    if (indexNeedsCaching(target)) return lowerCachedIndexAssign(b, target, op, value);
    const assign_expected: ?ast.TypeRef = assignExpectedType(b, target, op, value);
    const pre = try lowerAssignPreEval(b, target, op);
    const prev_expected = if (assign_expected != null) b.pushExpected(assign_expected) else null;
    const v = try lowerExpr(b, value);
    if (assign_expected != null) b.restoreExpected(prev_expected);
    if (try emitCompoundSingleElement(b, target, value, op, pre.cur, v)) return null;
    if (try emitCompoundAssignOperator(b, target, op, pre.cur, v)) return null;
    if (try emitCompoundFieldAssign(b, target, op, pre.recv, v)) return null;
    const combined: Reg = try combinedAssignValue(b, target, op, pre.cur, v);
    if (pre.recv) |recv_reg| if (op == .Assign and target.* == .Member) {
        try storeMemberThroughReg(b, &target.Member, recv_reg, combined);
        return null;
    };
    try storeCombinedToTarget(b, target, combined);
    return null;
}

/// `getArray()[getIndex()] += v` evaluates the receiver and every index once,
/// before the value, for the read and the write.
fn lowerCachedIndexAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) Allocator.Error!?Reg {
    try b.pushScope();
    defer b.popScope() catch {};
    const cached = try cacheIndexTarget(b, &target.Index);
    return lowerAssign(b, &cached, op, value);
}

/// A plain assignment of a lambda lowers under the target's declared type, as the
/// declaration's initializer did, so a receiver lambda keeps its receiver context
/// on reassignment. Restricted to lambda values, which alone consume that context
/// and whose receiver-type derivation is too costly to run on every assignment.
fn assignExpectedType(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    value: *const Expr,
) ?ast.TypeRef {
    const value_is_lambda = value.* == .Lambda or value.* == .AnonFun;
    return if (op != .Assign or !value_is_lambda) null else switch (target.*) {
        .Path => |pth| blk: {
            if (pth.segments.len != 1) break :blk null;
            if (b.localAstTy(pth.segments[0].name)) |t| break :blk t.*;
            break :blk null;
        },
        .Member => |m| blk: {
            var rty = (expr_mod.staticExprTypeRef(b, m.receiver) catch null) orelse break :blk null;
            defer rty.deinit(b.allocator);
            var head = std.mem.trimEnd(u8, rty.name, "?");
            if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (std.mem.findScalarLast(u8, head, '.')) |d| head = head[d + 1 ..];
            const prop = @import("inline_state.zig").memberPropAst(head, m.name.name) orelse break :blk null;
            if (prop.ty) |t| break :blk t;
            break :blk null;
        },
        else => null,
    };
}

/// What the target contributes before the value lowers: the operator's receiver
/// for a compound assign, the member receiver for a plain one.
const AssignPreEval = struct {
    cur: ?Reg = null,
    recv: ?Reg = null,
};

/// A compound assignment evaluates its target, the operator's receiver, before the
/// operand, as kotlinc orders `a = a.plus(b)` and `a.plusAssign(b)`. A member
/// target evaluates its receiver expression first for the same reason.
fn lowerAssignPreEval(b: *FuncBuilder, target: *const Expr, op: ast.AssignOp) Allocator.Error!AssignPreEval {
    var pre: AssignPreEval = .{};
    // A plain assignment evaluates its target's receiver before the value.
    if (op == .Assign) {
        switch (target.*) {
            .Member => |m| if (!m.safe and m.receiver.* != .Path and m.receiver.* != .This and m.receiver.* != .Super) {
                pre.recv = try lowerReceiver(b, m.receiver);
            },
            else => {},
        }
    }
    if (op != .Assign) {
        switch (target.*) {
            .Member => |m| if (!m.safe) {
                pre.recv = try lowerReceiver(b, m.receiver);
            },
            .Path => |p| {
                const own_member_compound = p.segments.len == 1 and
                    b.resolve(p.segments[0].name) == null and
                    b.hasOwnMember(p.segments[0].name) and
                    b.resolve("this") != null;
                if (!own_member_compound) pre.cur = try lowerExpr(b, target);
            },
            else => pre.cur = try lowerExpr(b, target),
        }
    }
    return pre;
}

/// `xs += y` where the declared element type is itself the container being added
/// is a single-element `add`, not a flattening `addAll`. Every route below decides
/// on the argument's runtime tag alone, so settle it here.
///
/// Returns whether the assignment was emitted here.
fn emitCompoundSingleElement(
    b: *FuncBuilder,
    target: *const Expr,
    value: *const Expr,
    op: ast.AssignOp,
    pre_cur: ?Reg,
    v: Reg,
) Allocator.Error!bool {
    if (op == .Add or op == .Sub) {
        if (try compoundSingleElementMember(b, target, value, op)) |single| {
            const cur = pre_cur orelse try lowerExpr(b, target);
            const args_start = b.allocReg();
            try b.push(.{ .Move = .{ .dst = args_start, .src = v } });
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = single });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = cur,
                .name = nm,
                .args = args_start,
                .n_args = 1,
                .arg_names = &.{},
            } });
            return true;
        }
    }
    return false;
}

/// Compound assigns first try `<op>Assign` as a member call on the target,
/// covering a user `operator fun plusAssign` and the built-in mutable collections;
/// a raise falls through to the rebind path below.
///
/// Only attempted when the target is not a mutable local Path: for a `var` local
/// the primitive rebind path is what Kotlin does, Int having no plusAssign, while
/// for a `val` Path the value's type declares it. A Path target whose name does
/// not resolve locally is a top-level binding and routes through the BinOp plus
/// StoreGlobal path, so top-level compound assigns and delegated setters fire.
///
/// A boxed var is an assignable variable and stays on the rebind path, while a
/// captured outer `val`, never locally bound and not boxed, takes this one, the
/// rebind path losing the write. A name both locally resolvable and known-outer
/// is a captured immutable, which Kotlin can only mean `<op>Assign` on.
///
/// Returns whether the assignment was emitted here.
fn emitCompoundAssignOperator(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    pre_cur: ?Reg,
    v: Reg,
) Allocator.Error!bool {
    const path_is_val = switch (target.*) {
        .Path => |p| p.segments.len == 1 and
            !b.isMutable(p.segments[0].name) and
            !b.isBoxed(p.segments[0].name) and
            (b.resolve(p.segments[0].name) != null or b.knowsOuter(p.segments[0].name)),
        else => false,
    };
    if (op != .Assign and path_is_val) {
        // A bare name the enclosing class declares as a member is a compound on
        // `this.count`, never an `<op>Assign` on the member's value.
        blk: {
            const pname = target.Path.segments[0].name;
            if (b.resolve(pname) != null or !b.hasOwnMember(pname)) break :blk;
            const this_reg = b.resolve("this") orelse break :blk;
            const bin: BinOp = switch (op) {
                .Add => .Add,
                .Sub => .Sub,
                .Mul => .Mul,
                .Div => .Div,
                .Rem => .Mod,
                .Assign => unreachable,
            };
            const field = try b.module.internConst(b.allocator, .{ .String = pname });
            try b.push(.{ .CompoundField = .{
                .receiver = this_reg,
                .field = field,
                .op = bin,
                .value = v,
            } });
            return true;
        }
        const method_name = switch (op) {
            .Add => "plusAssign",
            .Sub => "minusAssign",
            .Mul => "timesAssign",
            .Div => "divAssign",
            .Rem => "remAssign",
            .Assign => unreachable,
        };
        const recv = pre_cur orelse try lowerExpr(b, target);
        const args_start = b.allocReg();
        try b.push(.{ .Move = .{ .dst = args_start, .src = v } });
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = method_name });
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .args = args_start,
            .n_args = 1,
            .arg_names = &.{},
        } });
        return true;
    }
    return false;
}

/// Compound assign to a property. Kotlin resolves this in place when the field's
/// type carries the `<op>Assign` operator, mutating the field value rather than
/// reassigning the property, so `map.entries += e` dispatches on the read-only
/// view. The value's type is only known at runtime, so emit a single
/// `CompoundField` that reads the field, dispatches `<op>Assign` when supported,
/// and otherwise falls back to read-modify-write. `super.prop += x` reads through
/// the supertype's accessor, so it takes the read-modify-write path below.
///
/// Returns whether the assignment was emitted here.
fn emitCompoundFieldAssign(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    pre_recv: ?Reg,
    v: Reg,
) Allocator.Error!bool {
    if (op != .Assign) {
        if (target.* == .Member and !target.Member.safe and target.Member.receiver.* != .Super) {
            const m = target.Member;
            const recv = pre_recv orelse try lowerReceiver(b, m.receiver);
            const bin: BinOp = switch (op) {
                .Add => .Add,
                .Sub => .Sub,
                .Mul => .Mul,
                .Div => .Div,
                .Rem => .Mod,
                .Assign => unreachable,
            };
            const field = try b.module.internConst(b.allocator, .{ .String = m.name.name });
            try b.push(.{ .CompoundField = .{
                .receiver = recv,
                .field = field,
                .op = bin,
                .value = v,
            } });
            return true;
        }
    }
    return false;
}

/// The value the target is stored back with: the operand itself for a plain
/// assign, the read-modify-write combine for a compound one.
fn combinedAssignValue(
    b: *FuncBuilder,
    target: *const Expr,
    op: ast.AssignOp,
    pre_cur: ?Reg,
    v: Reg,
) Allocator.Error!Reg {
    return switch (op) {
        .Assign => v,
        .Add, .Sub, .Mul, .Div, .Rem => blk: {
            const cur0 = pre_cur orelse try lowerExpr(b, target);
            // `xs += y` on a statically broad collection rebinds to a `List`, so
            // coerce a `Set` runtime value to a list first and let the
            // `List`-returning operator dispatch.
            const cur = if (op == .Add or op == .Sub)
                try helpers.coerceBroadCollectionToList(b, target, cur0)
            else
                cur0;
            const bin: BinOp = switch (op) {
                .Add => .Add,
                .Sub => .Sub,
                .Mul => .Mul,
                .Div => .Div,
                .Rem => .Mod,
                .Assign => unreachable,
            };
            // Mark the combine step so a mutable-collection left operand can mutate
            // in place via `<op>Assign`, but only when the rebind is not viable: a
            // reassignable local follows Kotlin's `a = a.plus(b)` form, which for a
            // read-only-typed local holding a mutable value must produce a fresh
            // list, while a val, member or global target cannot be rebound. A boxed
            // name is a captured-and-written `var`, always reassignable through its
            // shared cell, so it keeps the `a = a.plus(b)` form.
            const target_reassignable_local = switch (target.*) {
                .Path => |p| p.segments.len == 1 and
                    (b.isBoxed(p.segments[0].name) or
                        (b.resolve(p.segments[0].name) != null and b.isMutable(p.segments[0].name))),
                else => false,
            };
            const dst = b.allocReg();
            try b.push(.{ .BinOp = .{
                .dst = dst,
                .op = bin,
                .lhs = cur,
                .rhs = v,
                .compound = !target_reassignable_local,
            } });
            break :blk dst;
        },
    };
}

/// Emit `delegate.setValue(null, ::prop, value)` for a `var x by D` write-through,
/// the delegate being bound under `dname`. Capture-aware resolve, so the write
/// works inside a closure that captured the delegate.
fn emitDelegateSetValue(b: *FuncBuilder, dname: []const u8, prop: []const u8, value: Reg) Allocator.Error!void {
    const delegate = try lambda_body.resolveCapture(b, dname);
    const null_arg = try b.emitConst(.Null);
    const prop_ref = b.allocReg();
    const pname = try b.module.internConst(b.allocator, .{ .String = prop });
    try b.push(.{ .PropertyRef = .{ .dst = prop_ref, .name = pname } });
    // Contiguous args: null (thisRef), ::prop, value.
    const args_start = b.allocReg();
    try b.push(.{ .Move = .{ .dst = args_start, .src = null_arg } });
    const a1 = b.allocReg();
    try b.push(.{ .Move = .{ .dst = a1, .src = prop_ref } });
    const a2 = b.allocReg();
    try b.push(.{ .Move = .{ .dst = a2, .src = value } });
    const dst = b.allocReg();
    const name_c = try b.module.internConst(b.allocator, .{ .String = "setValue" });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = delegate,
        .name = name_c,
        .args = args_start,
        .n_args = 3,
        .arg_names = &.{},
    } });
}

// Route the already-combined value to the assignment target: a single Path name
// (local, cell, capture, member, global), a Member field, or an Index `set` call.
// Shared by compound-assign and prefix and postfix `++`/`--`.
fn exprMayHaveSideEffects(e: *const Expr) bool {
    return switch (e.*) {
        .Path, .This, .Super, .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit => false,
        else => true,
    };
}

/// A `recv[args]` target whose receiver or index must be evaluated exactly once
/// for a read-modify-write.
pub fn indexNeedsCaching(e: *const Expr) bool {
    if (e.* != .Index) return false;
    const ix = e.Index;
    if (exprMayHaveSideEffects(ix.receiver)) return true;
    for (ix.args) |*a| if (exprMayHaveSideEffects(a)) return true;
    return false;
}

fn cachedPath(b: *FuncBuilder, name: []const u8, sp: @FieldType(ast.Ident, "span")) Allocator.Error!Expr {
    const segs = try b.allocator.alloc(ast.Ident, 1);
    segs[0] = .{ .name = name, .span = sp };
    return .{ .Path = .{ .segments = segs, .span = sp } };
}

/// Evaluate an index target's receiver and indices into registers bound under
/// scoped names, the caller owning the scope, and return the same target rewritten
/// to read those locals.
pub fn cacheIndexTarget(b: *FuncBuilder, ix: *const @FieldType(ast.Expr, "Index")) Allocator.Error!Expr {
    const recv_reg = try lowerExpr(b, ix.receiver);
    try b.bind("$lv$recv", recv_reg);
    const recv = try b.allocator.create(Expr);
    recv.* = try cachedPath(b, "$lv$recv", ix.span);
    const args = try b.allocator.alloc(Expr, ix.args.len);
    for (ix.args, 0..) |*a, i| {
        const reg = try lowerExpr(b, a);
        const name = try std.fmt.allocPrint(b.allocator, "$lv$arg{d}", .{i});
        try b.bind(name, reg);
        args[i] = try cachedPath(b, name, ix.span);
    }
    return .{ .Index = .{ .receiver = recv, .args = args, .span = ix.span } };
}

/// Store `value` into member `m` of an already evaluated receiver: the register is
/// bound under a scoped name so the member store lowers a plain local read instead
/// of re-evaluating the receiver expression.
pub fn storeMemberThroughReg(b: *FuncBuilder, m: *const @FieldType(ast.Expr, "Member"), recv_reg: Reg, value: Reg) Allocator.Error!void {
    try b.pushScope();
    defer b.popScope() catch {};
    try b.bind("$assign$recv", recv_reg);
    const segs = try b.allocator.alloc(ast.Ident, 1);
    segs[0] = .{ .name = "$assign$recv", .span = m.span };
    const recv_path = try b.allocator.create(Expr);
    recv_path.* = .{ .Path = .{ .segments = segs, .span = m.span } };
    const rewritten = Expr{ .Member = .{ .receiver = recv_path, .name = m.name, .safe = false, .span = m.span } };
    try storeCombinedToTarget(b, &rewritten, value);
}

pub fn storeCombinedToTarget(b: *FuncBuilder, target: *const Expr, combined: Reg) Allocator.Error!void {
    switch (target.*) {
        .Path => |p| try storeCombinedToPath(b, target, p, combined),
        .Member => |m| try storeCombinedToMember(b, m, combined),
        .Index => |idx| try storeCombinedToIndex(b, idx, combined),
        else => {
            try b.push(.{ .Trace = .{ .span = exprSpan(target) } });
        },
    }
}

fn storeCombinedToPath(
    b: *FuncBuilder,
    target: *const Expr,
    p: @FieldType(ast.Expr, "Path"),
    combined: Reg,
) Allocator.Error!void {
    if (p.segments.len != 1) {
        try b.push(.{ .Trace = .{ .span = exprSpan(target) } });
        return;
    }
    const seg = p.segments[0].name;
    if (try storeThroughImportedCompanion(b, p, seg, combined)) return;
    try storeCombinedToBareName(b, p, seg, combined);
    try writeThroughPathDelegate(b, seg, combined);
}

/// A bare name brought in by `import Object.member` writes the object's
/// property, as its read goes through the object.
///
/// Returns whether the store was routed through the object.
fn storeThroughImportedCompanion(
    b: *FuncBuilder,
    p: @FieldType(ast.Expr, "Path"),
    seg: []const u8,
    combined: Reg,
) Allocator.Error!bool {
    if (b.resolve(seg) == null and !b.knowsOuter(seg) and !b.hasOwnMember(seg)) {
        if (expr_mod.importCompanionRewrite(b, p.segments[0].span.file, seg)) |rw| {
            if (rw.segs.len >= 2) {
                const sp = p.segments[0].span;
                const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len - 1);
                for (rw.segs[0 .. rw.segs.len - 1], 0..) |sname, k| rsegs[k] = .{ .name = sname, .span = sp };
                const recv = try b.allocator.create(Expr);
                recv.* = .{ .Path = .{ .segments = rsegs, .span = sp } };
                const member = Expr{ .Member = .{ .receiver = recv, .name = .{ .name = rw.segs[rw.segs.len - 1], .span = sp }, .safe = false, .span = sp } };
                try storeCombinedToTarget(b, &member, combined);
                return true;
            }
        }
    }
    return false;
}

/// Route a single-segment write to the binding the name denotes: a shared cell,
/// a local home, the receiver's field, or a top-level global.
fn storeCombinedToBareName(
    b: *FuncBuilder,
    p: @FieldType(ast.Expr, "Path"),
    seg: []const u8,
    combined: Reg,
) Allocator.Error!void {
    // The boxed set is computed for the whole body and carries no declaration
    // position, so a name reads as boxed even at sites preceding its `var`.
    // Require the name to be in scope as a local here, bound in this frame or
    // captured from an enclosing one, or a bare write in a receiver lambda
    // sharing a name with a later `var` writes that local's cell instead of
    // the receiver's property. `knowsOuter` keeps genuine captures on the
    // cell path, where `resolve` is null.
    const boxed_in_scope = b.isBoxed(seg) and
        (b.resolve(seg) != null or b.knowsOuter(seg) or decl_mod.isLowerAnonCapture(seg));
    if (boxed_in_scope) {
        // A captured-and-written outer var is boxed into a shared
        // `Value.Cell` at its binding site, so the write lands on the cell
        // and is visible at the declaration site on every path.
        const cell = try boxedCellReg(b, seg);
        try b.push(.{ .CellSet = .{ .cell = cell, .value = combined } });
    } else if (b.mutableHome(seg)) |home| {
        try b.push(.{ .Move = .{ .dst = home, .src = combined } });
    } else if (b.resolve(seg) != null) {
        try b.rebind(seg, combined);
    } else if (b.hasOwnMember(seg) and b.resolve("this") != null and
        !spliceReceiverHidesMember(b, seg)) {
        // A method-body `this.field` write routes SetField on the receiver so
        // the bare-name assign reaches the instance, not a synthetic global.
        // A private shadow of a supertype's same-name property writes its own
        // owner-mangled cell. Not taken inside an inline-spliced receiver
        // lambda whose receiver type does not declare the member, where a
        // SetField would invent a field on the wrong object; the walking
        // store below finds the right owner.
        const this_reg = b.resolve("this").?;
        const store_name: []const u8 = blk: {
            const oc = b.ownerClass() orelse break :blk seg;
            var kb: [256]u8 = undefined;
            const probe = std.fmt.bufPrint(&kb, "{s}\x1f{s}", .{ oc, seg }) catch break :blk seg;
            break :blk b.module.registry.private_shadow_props.getKey(probe) orelse seg;
        };
        const field = try b.module.internConst(b.allocator, .{ .String = store_name });
        try b.push(.{ .SetField = .{
            .receiver = this_reg,
            .field = field,
            .value = combined,
        } });
    } else if (b.capturesThisSlot() or b.resolve("this") != null) {
        // An unqualified write whose name is not a local, param,
        // captured-outer or own-member is, by Kotlin scoping, either a
        // property of the receiver, a member or an extension-property setter
        // on its type or a supertype, or a top-level binding. Decide at
        // runtime, symmetric to the read side's `LoadFromThisOrGlobal`:
        // capture `this` on demand, then `StoreToThisOrGlobal` sets the
        // receiver's property when present.
        const this_idx = try b.recordCapture("this");
        const name_c = try b.module.internConst(b.allocator, .{ .String = seg });
        expr_mod.orEmitAudit(b, "bare_name_assign", "StoreToThisOrGlobal", seg);
        try b.push(.{ .StoreToThisOrGlobal = .{
            .this_idx = this_idx,
            .name = name_c,
            .value = combined,
            // Hand over the receiver register when lowering has one: in a
            // spliced inline body it is the only way the runtime can reach
            // the receiver. Ownership is still checked at run time, so
            // passing it cannot capture a write the receiver does not declare.
            .recv = b.resolve("this"),
        } });
    } else {
        // Top-level binding: route through StoreGlobal so the tree-walker
        // setter or delegate fires. A renamed file-private property writes
        // its per-file global.
        const target_name = expr_mod.filePrivatePropRename(b, seg, p.segments[0].span.file.int()) orelse seg;
        const n = try b.module.internConst(b.allocator, .{ .String = target_name });
        try b.push(.{ .StoreGlobal = .{ .name = n, .value = combined } });
    }
}

/// Write-through for a `var x by D` delegate: when the hidden delegate
/// binding is in scope, directly or as a captured outer, dispatch setValue
/// so a writable delegate receives the write. A stack buffer avoids
/// allocating for the common non-delegated case.
fn writeThroughPathDelegate(b: *FuncBuilder, seg: []const u8, combined: Reg) Allocator.Error!void {
    var namebuf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&namebuf, "{s}$klio_delegate", .{seg})) |dname_stack| {
        if ((b.resolve(dname_stack) != null or b.knowsOuter(dname_stack)) and
            !b.plainShadowsDelegate(seg, dname_stack))
        {
            const dname = try b.allocator.dupe(u8, dname_stack);
            try emitDelegateSetValue(b, dname, seg, combined);
        }
    } else |_| {}
}

fn storeCombinedToMember(
    b: *FuncBuilder,
    m: @FieldType(ast.Expr, "Member"),
    combined: Reg,
) Allocator.Error!void {
    const recv = try lowerReceiver(b, m.receiver);
    // Explicit `this.x = v` where the enclosing class declares `x` as a
    // private shadow of a supertype's same-name stored property writes its
    // own owner-mangled cell, matching the bare-name write and read.
    const store_field_name: []const u8 = blk: {
        if (m.receiver.* != .This or m.receiver.This.qualifier != null) break :blk m.name.name;
        const oc = b.ownerClass() orelse break :blk m.name.name;
        var kb: [256]u8 = undefined;
        const probe = std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ oc, m.name.name }) catch break :blk m.name.name;
        break :blk b.module.registry.private_shadow_props.getKey(probe) orelse m.name.name;
    };
    const field = try b.module.internConst(b.allocator, .{ .String = store_field_name });
    // `super.prop = v` lowers to a SetField on `this`, super not being a
    // value, so the setter search would find the overriding setter and
    // re-enter it. Carry the writing class so the search starts at its
    // supertypes, as a `super.prop` read does.
    const super_owner: ?ir.ConstId = blk: {
        if (m.receiver.* != .Super) break :blk null;
        const oc = if (m.receiver.Super.label) |l|
            expr_mod.scopeTypeRename(b, l.name, l.span.file.int()) orelse l.name
        else
            b.ownerClass() orelse break :blk null;
        break :blk try b.module.internConst(b.allocator, .{ .String = oc });
    };
    if (m.safe) {
        // `a?.b = v` stores only when the receiver is non-null; dropping
        // the store entirely lost updates on non-null parents.
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = recv, .rhs = null_r } });
        const skip_b = try b.allocBlock();
        const store_b = try b.allocBlock();
        const join = try b.allocBlock();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = skip_b, .f = store_b } });
        b.switchTo(skip_b);
        b.terminate(.{ .Goto = join });
        b.switchTo(store_b);
        try b.push(.{ .SetField = .{
            .receiver = recv,
            .field = field,
            .value = combined,
        } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return;
    }
    try b.push(.{ .SetField = .{
        .receiver = recv,
        .field = field,
        .value = combined,
        .super_owner = super_owner,
    } });
}

/// `m[k] = v` lowers to `receiver.set(k, v)` so map and mutable-list
/// assignment dispatch through the same `call_member` path built-in
/// collection mutation uses.
fn storeCombinedToIndex(
    b: *FuncBuilder,
    idx: @FieldType(ast.Expr, "Index"),
    combined: Reg,
) Allocator.Error!void {
    const recv = try lowerReceiver(b, idx.receiver);
    // Reserve a contiguous run of slots for keys and value before lowering
    // the key expressions, since lowering each key may allocate auxiliary
    // registers and the run must stay tight for `read_arg_run`.
    const n_keys = idx.args.len;
    const key_start = b.allocReg();
    var key_slots = try b.allocator.alloc(Reg, if (n_keys == 0) 1 else n_keys);
    defer b.allocator.free(key_slots);
    key_slots[0] = key_start;
    var i: usize = 1;
    while (i < n_keys) : (i += 1) key_slots[i] = b.allocReg();
    const val_slot = b.allocReg();
    for (key_slots[0..n_keys], idx.args) |slot, *arg| {
        const r = try lowerExpr(b, arg);
        try b.push(.{ .Move = .{ .dst = slot, .src = r } });
    }
    try b.push(.{ .Move = .{ .dst = val_slot, .src = combined } });
    const dst = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = "set" });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .args = key_start,
        .n_args = @as(u32, @intCast(n_keys)) + 1,
        .arg_names = &.{},
    } });
}

fn lowerLocalClassDecl(b: *FuncBuilder, c: *const ast.Class) Allocator.Error!?Reg {
    // A local class declaration inside a function body captures the visible scope
    // so its methods can read the enclosing fn's names.
    var visible = try b.visibleNames();
    defer visible.deinit();
    // Inside a member extension the body's `this` is the extension receiver and the
    // dispatch receiver lives only on the runtime receiver chain, so read it here
    // through the qualified-this walk and capture it under its label.
    var owner_label: ?[]const u8 = null;
    var owner_reg: Reg = undefined;
    if (b.dispatchClass()) |oc| {
        const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{oc});
        if (!visible.contains(label)) {
            if (b.resolve("this")) |this_reg| {
                const nm = try b.module.internConst(b.allocator, .{ .String = oc });
                const dst = b.allocReg();
                try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm, .soft = true } });
                owner_label = label;
                owner_reg = dst;
            }
        }
    }
    const n_extra: usize = if (owner_label != null) 1 else 0;
    const captured_names = try b.allocator.alloc([]const u8, visible.count() + n_extra);
    var it = visible.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) captured_names[i] = k.*;
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names[0..visible.count()], captures[0..visible.count()]) |n, *slot| slot.* = try resolveCapture(b, n);
    if (owner_label) |label| {
        captured_names[visible.count()] = label;
        captures[visible.count()] = owner_reg;
    }
    // Bind the class name to its registered `.Class` value so a `C(args)` call in
    // scope constructs the local class, which in Kotlin shadows a same-named
    // top-level function. The binding flows into nested lambdas through capture.
    const dst = b.allocReg();
    try b.push(.{ .RegisterClass = .{
        .class = FF(ast.Class).fromPtr(c),
        .captured_names = captured_names,
        .captures = captures,
        .dst = dst,
    } });
    try b.bind(c.name.name, dst);
    // A nested lambda's bare `C(args)` must construct this local class through the
    // captured binding, not a same-simple-name module class.
    build.pushLocalClassName(c.name.name);
    // Lowering-time typing record: the local class's transitive supertype chain under
    // a function-scoped mangle, so a local initialized from its constructor carries a
    // head that proves Collection-ness to extension binding.
    {
        const ra = b.module.registry.allocator;
        if (std.fmt.allocPrint(ra, "{s}$lc{s}", .{ c.name.name, build.currentRealFn() orelse "" }) catch null) |key| {
            var chain: std.ArrayList([]const u8) = .empty;
            var chain_ok = true;
            for (c.supertypes) |*sup| {
                const sn = sup.name.name;
                chain.append(ra, ra.dupe(u8, sn) catch {
                    chain_ok = false;
                    break;
                }) catch {
                    chain_ok = false;
                    break;
                };
                if (b.module.registry.class_super_names.get(sn)) |transitive| {
                    for (transitive) |tn| {
                        chain.append(ra, ra.dupe(u8, tn) catch {
                            chain_ok = false;
                            break;
                        }) catch {
                            chain_ok = false;
                            break;
                        };
                    }
                }
                if (!chain_ok) break;
            }
            if (chain_ok) {
                // An empty chain still registers: the key's presence is the typing
                // record a supertype-less local class's methods bind through.
                const owned = chain.toOwnedSlice(ra) catch null;
                if (owned) |sl| b.module.registry.class_super_names.put(key, sl) catch {};
            } else {
                chain.deinit(ra);
            }
            // Reserved-fid method headers: each of the local class's own methods gets
            // a bodyless header row under the mangled owner, so a member call on a
            // local-class-typed receiver binds its virtual slot at lowering.
            for (c.members) |*m| {
                if (m.* != .Function) continue;
                const mf = &m.Function;
                if (mf.receiver_type != null) continue;
                decl_mod.retainLocalClassMemberHeader(b.module, key, mf) catch {};
            }
        }
    }
    return null;
}

/// The `provideDelegate` convention at a delegated property's creation: `val x by e`
/// first offers `e` the call `provideDelegate(thisRef, ::x)`, and the delegate is its
/// result when a member or extension operator applies, a miss keeping `e`.
pub fn emitProvideDelegate(b: *FuncBuilder, delegate: Reg, prop_name: []const u8) Allocator.Error!Reg {
    const null_arg = try b.emitConst(.Null);
    const prop_ref = b.allocReg();
    const pname = try b.module.internConst(b.allocator, .{ .String = prop_name });
    try b.push(.{ .PropertyRef = .{ .dst = prop_ref, .name = pname } });
    const args_start = b.allocReg();
    try b.push(.{ .Move = .{ .dst = args_start, .src = null_arg } });
    _ = b.allocReg();
    try b.push(.{ .Move = .{ .dst = Reg.from(args_start.int() + 1), .src = prop_ref } });
    const dst = b.allocReg();
    const name_c = try b.module.internConst(b.allocator, .{ .String = "$provideDelegate" });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = delegate,
        .name = name_c,
        .args = args_start,
        .n_args = 2,
        .arg_names = &.{},
    } });
    return dst;
}

/// A destructured name binds like a local: a `var` gets a home register the way
/// `lowerPropertyDecl` gives one to `var x = …`, so `p += 1` updates the slot
/// instead of dispatching `plusAssign` on the value.
fn bindDestructured(b: *FuncBuilder, name: []const u8, value: Reg, mutable: bool) Allocator.Error!void {
    if (b.isBoxed(name)) {
        // A captured `var` takes a shared cell so writes from a nested closure are
        // visible here.
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = value } });
        try b.setMutableHome(name, home);
        try b.markMutable(name);
        return b.bind(name, home);
    }
    if (!mutable) return b.bind(name, value);
    const home = b.allocReg();
    try b.push(.{ .Move = .{ .dst = home, .src = value } });
    try b.setMutableHome(name, home);
    try b.markMutable(name);
    try b.bind(name, home);
}

/// A destructuring entry named `_` is a positional skip placeholder only when
/// written bare. A backtick-escaped `` `_` `` is a real name, its span carrying the
/// backticks, and binds and reads like any other identifier.
pub fn isUnderscorePlaceholder(name: ast.Ident) bool {
    return std.mem.eql(u8, name.name, "_") and name.span.len() == 1;
}

fn lowerDestructuringDecl(
    b: *FuncBuilder,
    names: []const ast.Ident,
    by_name: bool,
    sources: []const ast.Ident,
    mutable: bool,
    init: *const Expr,
) Allocator.Error!?Reg {
    // `val (a, b, ...) = expr` desugars to repeated `expr.componentN()` calls, `_`
    // placeholders skipping the call.
    const recv = try lowerExpr(b, init);
    // Each name's type is its `componentN()`'s declared return type on the
    // initializer's type, so the destructured names carry a receiver type into
    // dispatch instead of arriving untyped.
    var recv_ty = try expr_mod.staticExprTypeRef(b, init);
    defer if (recv_ty) |*t| t.deinit(b.allocator);
    // The name-based form reads each entry's property off the initializer.
    if (by_name) {
        // A discarded name-based entry still reads its property, unlike a
        // positional `_`, which skips its `componentN`.
        for (names, 0..) |name, i| {
            const field = try b.module.internConst(b.allocator, .{ .String = sources[i].name });
            const dst = b.allocReg();
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
            if (isUnderscorePlaceholder(name)) continue;
            try bindDestructured(b, name.name, dst, mutable);
        }
        return null;
    }
    for (names, 0..) |name, i| {
        if (isUnderscorePlaceholder(name)) continue;
        const comp_name = try std.fmt.allocPrint(b.allocator, "component{d}", .{i + 1});
        const nm = try b.module.internConst(b.allocator, .{ .String = comp_name });
        const args_start = b.allocReg();
        const dst = b.allocReg();
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = recv,
            .name = nm,
            .args = args_start,
            .n_args = 0,
            .arg_names = &.{},
        } });
        try bindDestructured(b, name.name, dst, mutable);
        if (recv_ty) |rty| {
            if (try expr_mod.nullaryMemberReturnTypeRef(b, rty, comp_name, name.span.file)) |ct| {
                try b.setLocalDeclTypeOwned(name.name, ct);
            }
        }
    }
    return null;
}


const testing = std.testing;
const span = @import("span");
const Module = ir.Module;

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

fn intLit(v: i64) Expr {
    return .{ .IntLit = .{ .value = v, .kind = .Int, .span = dummySpan() } };
}

fn freeFunc(func: ir.Func) void {
    for (func.blocks) |blk| {
        if (blk.insts.len != 0) testing.allocator.free(blk.insts);
        if (blk.catches.len != 0) testing.allocator.free(blk.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

fn pathExpr(segs: []ast.Ident) Expr {
    return .{ .Path = .{ .segments = segs, .span = dummySpan() } };
}

test "expr statement returns its register" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const s = Stmt{ .Expr = intLit(7) };
    const r = try lowerStmt(&b, &s);
    try testing.expect(r != null);
    b.terminate(.{ .Return = r.? });
    const func = try b.finish("f", "test.f", build.typeInt());
    defer freeFunc(func);
    // A `Trace` position marker precedes the statement; the value materializes in
    // the following `Const`.
    try testing.expect(func.blocks[0].insts[0] == .Trace);
    try testing.expect(func.blocks[0].insts[1] == .Const);
}

test "val without annotation binds directly" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var p = ast.Property{
        .mutable = false,
        .name = .{ .name = "x", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(3),
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    const r = try lowerStmt(&b, &s);
    try testing.expect(r == null);
    // `val x = 3` binds `x` to the init register without a home slot.
    try testing.expect(b.resolve("x") != null);
    try testing.expect(b.mutableHome("x") == null);
}

test "val initialized from this retains the receiver type" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setEnclosingRecvTy("TestScope");
    var p = ast.Property{
        .mutable = false,
        .name = .{ .name = "outerScope", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = .{ .This = .{ .qualifier = null, .span = dummySpan() } },
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &s);
    try testing.expectEqualStrings("TestScope", b.localDeclType("outerScope").?);
}

test "var declaration gets a mutable home slot" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var p = ast.Property{
        .mutable = true,
        .name = .{ .name = "n", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(0),
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &s);
    try testing.expect(b.isMutable("n"));
    try testing.expect(b.mutableHome("n") != null);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    // Trace marker, then the const fused into the home slot: the single-use
    // `Const T; Move home <- T` pair coalesces at `finish`.
    try testing.expect(func.blocks[0].insts[0] == .Trace);
    try testing.expect(func.blocks[0].insts.len == 2);
    try testing.expect(func.blocks[0].insts[1] == .Const);
}

test "lateinit var starts Null, binds its marker, and reads through LateinitCheck" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var p = ast.Property{
        .mutable = true,
        .name = .{ .name = "s", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = null,
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = true,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const decl = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &decl);
    // The marker binding shares the lateinit's home register.
    const home = b.resolve("s").?;
    try testing.expectEqual(home.int(), b.resolve("s$klio_lateinit").?.int());
    var segs = [_]ast.Ident{.{ .name = "s", .span = dummySpan() }};
    const read = Expr{ .Path = .{ .segments = &segs, .span = dummySpan() } };
    const r = try expr_mod.lowerExpr(&b, &read);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    // The declaration's Null lands in the home slot; the read is guarded.
    var saw_null = false;
    for (insts) |inst| {
        if (inst == .Const and m.consts.items[inst.Const.value.int()] == .Null) saw_null = true;
    }
    try testing.expect(saw_null);
    const last = insts[insts.len - 1];
    try testing.expect(last == .LateinitCheck);
    try testing.expectEqual(home.int(), last.LateinitCheck.src.int());
    try testing.expectEqual(r.int(), last.LateinitCheck.dst.int());
    try testing.expectEqualStrings("s", m.consts.items[last.LateinitCheck.name.int()].String);
}

test "plain var declared without lateinit reads unchecked" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var p = ast.Property{
        .mutable = true,
        .name = .{ .name = "n", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(0),
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const decl = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &decl);
    try testing.expect(b.resolve("n$klio_lateinit") == null);
    var segs = [_]ast.Ident{.{ .name = "n", .span = dummySpan() }};
    const read = Expr{ .Path = .{ .segments = &segs, .span = dummySpan() } };
    const r = try expr_mod.lowerExpr(&b, &read);
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    for (func.blocks[0].insts) |inst| try testing.expect(inst != .LateinitCheck);
}

test "any-typed val is marked" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const any_ty = ast.TypeRef{
        .name = .{ .name = "Any", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var p = ast.Property{
        .mutable = false,
        .name = .{ .name = "a", .span = dummySpan() },
        .receiver_type = null,
        .ty = any_ty,
        .init = intLit(1),
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const s = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &s);
    try testing.expect(b.isAnyTyped("a"));
}

test "assign to var rebinds through the home slot" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // Set up `var n = 0` first.
    var p = ast.Property{
        .mutable = true,
        .name = .{ .name = "n", .span = dummySpan() },
        .receiver_type = null,
        .ty = null,
        .init = intLit(0),
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = dummySpan(),
    };
    const decl = Stmt{ .Decl = .{ .Property = &p } };
    _ = try lowerStmt(&b, &decl);
    const home = b.mutableHome("n").?;
    // `n = 5`
    var segs = [_]ast.Ident{.{ .name = "n", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(5),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    // Last instruction is a Move into the home register.
    const insts = func.blocks[0].insts;
    // The assignment's value fuses into the home register, the single-use
    // `Const T; Move home <- T` pair coalescing at `finish`.
    const last = insts[insts.len - 1];
    try testing.expect(last == .Const);
    try testing.expectEqual(home, last.Const.dst);
}

test "assign to top-level name emits store global" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var segs = [_]ast.Ident{.{ .name = "g", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(9),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .StoreGlobal);
}

test "compound assign to top-level emits binop then store global" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    var segs = [_]ast.Ident{.{ .name = "g", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(1),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    var saw_binop = false;
    for (insts) |inst| {
        if (inst == .BinOp) saw_binop = true;
    }
    try testing.expect(saw_binop);
    try testing.expect(insts[insts.len - 1] == .StoreGlobal);
}

test "compound assign to val local dispatches plusAssign" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // `val xs = <reg>` (immutable local bound directly).
    const r = b.allocReg();
    try b.bind("xs", r);
    var segs = [_]ast.Ident{.{ .name = "xs", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(1),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .CallMember);
}

test "compound assign to captured val dispatches plusAssign not member store" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    // Lambda body capturing `val xs` from the enclosing frame.
    var outer = build.StringSet.init(testing.allocator);
    try outer.put("xs", {});
    b.setOuterNames(outer);
    var segs = [_]ast.Ident{.{ .name = "xs", .span = dummySpan() }};
    const target = pathExpr(&segs);
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(1),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    // plusAssign member call on the capture; never a SetField / StoreGlobal.
    try testing.expect(insts[insts.len - 1] == .CallMember);
    for (insts) |inst| {
        try testing.expect(inst != .SetField);
        try testing.expect(inst != .StoreGlobal);
    }
}

test "member assign emits set field" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("obj", r);
    var recv_segs = [_]ast.Ident{.{ .name = "obj", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    const target = Expr{ .Member = .{
        .receiver = &recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(2),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    try testing.expect(insts[insts.len - 1] == .SetField);
}

test "compound assign to member emits compound field" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("obj", r);
    var recv_segs = [_]ast.Ident{.{ .name = "obj", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    const target = Expr{ .Member = .{
        .receiver = &recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = false,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Add,
        .value = intLit(2),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    // A property compound-assign defers the plusAssign-vs-rewrite decision to
    // runtime: a single `CompoundField`, never a read-modify-`SetField`.
    try testing.expect(insts[insts.len - 1] == .CompoundField);
    for (insts) |inst| try testing.expect(inst != .SetField);
}

test "index assign emits set call" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("xs", r);
    var recv_segs = [_]ast.Ident{.{ .name = "xs", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    var idx_args = [_]Expr{intLit(0)};
    const target = Expr{ .Index = .{
        .receiver = &recv,
        .args = &idx_args,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(42),
        .span = dummySpan(),
    } };
    _ = try lowerStmt(&b, &assign);
    b.terminate(.{ .Return = null });
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    const insts = func.blocks[0].insts;
    const last = insts[insts.len - 1];
    try testing.expect(last == .CallMember);
    try testing.expectEqual(@as(u8, 2), last.CallMember.n_args);
}

test "safe member assign branches on null" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = b.allocReg();
    try b.bind("obj", r);
    var recv_segs = [_]ast.Ident{.{ .name = "obj", .span = dummySpan() }};
    var recv = pathExpr(&recv_segs);
    const target = Expr{ .Member = .{
        .receiver = &recv,
        .name = .{ .name = "field", .span = dummySpan() },
        .safe = true,
        .span = dummySpan(),
    } };
    const assign = Stmt{ .Assign = .{
        .target = target,
        .op = .Assign,
        .value = intLit(7),
        .span = dummySpan(),
    } };
    const out = try lowerStmt(&b, &assign);
    try testing.expect(out == null);
    const func = try b.finish("f", "test.f", build.typeUnit());
    defer freeFunc(func);
    // Entry block branches; extra blocks were allocated for skip / do / join.
    try testing.expect(func.blocks.len >= 4);
    try testing.expect(func.blocks[0].terminator == .Branch);
}

/// Type names whose values are definitely not callable, so a local declared with
/// one never shadows a same-named function for a call.
fn isDefiniteNonFnTypeName(name: []const u8) bool {
    const names = [_][]const u8{
        "Int",   "Long",   "Short",  "Byte", "Char",  "Boolean",
        "Float", "Double", "String", "UInt", "ULong", "UShort",
        "UByte", "Unit",
    };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
