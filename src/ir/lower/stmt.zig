//! Statement lowering. Free functions over the shared `FuncBuilder`;
//! filled in alongside the expression dispatch.

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

/// Lower a statement. Returns the register holding the statement's value
/// when it is an expression statement in tail position, else `null`.
pub fn lowerStmt(b: *FuncBuilder, stmt: *const Stmt) Allocator.Error!?Reg {
    // Record the executing source position for stack-trace capture: a `Trace`
    // marks each statement so a throw (here or in any call it makes) reports the
    // line each frame is on. Cheap (a single span store at eval time); the JIT
    // hot loops bypass the eval dispatch entirely.
    switch (stmt.*) {
        .Expr => |*e| try b.push(.{ .Trace = .{ .span = helpers.exprSpan(e) } }),
        .Assign => |a| try b.push(.{ .Trace = .{ .span = a.span } }),
        .DestructuringDecl => |dd| try b.push(.{ .Trace = .{ .span = dd.span } }),
        // A `val x = expr` initializer can throw (or call something that does),
        // so mark its line too; other declarations carry no executable head.
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

/// `obj?.items[i] = v` — an `Index` target whose receiver chain is a
/// safe-`Member`.
fn isSafeIndexTarget(target: *const Expr) bool {
    return switch (target.*) {
        .Index => |idx| switch (idx.receiver.*) {
            .Member => |m| m.safe,
            else => false,
        },
        else => false,
    };
}

/// `obj?.field = v` — a safe-`Member` target.
fn isSafeMemberTarget(target: *const Expr) bool {
    return switch (target.*) {
        .Member => |m| m.safe,
        else => false,
    };
}

fn lowerPropertyDecl(b: *FuncBuilder, p: *const ast.Property) Allocator.Error!?Reg {
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
    // `val x = expr` / `var x = expr`. The init is lowered
    // into a fresh register and bound in the current scope;
    // mutability is enforced by typeck, not the IR.
    // A local holding a contextual function — declared with a contextual
    // function type, or initialized by an anonymous context function — has
    // a call shape: `name(c.., a..)` splits its leading context args
    // (`CtxCall`), as a parameter of that type does.
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
    const init: Reg = if (p.delegate) |de| blk: {
        // `val x by D` binds the delegate (after the `provideDelegate`
        // convention) under a hidden binding (`x$klio_delegate`) for BOTH
        // `val` and `var`. Kotlin dispatches `getValue` on every read (and
        // `setValue` on every write) and never at the declaration, so a read
        // of `x` goes through `lowerDelegateRead` -> `D.getValue(null, ::x)`.
        // A `val x by derivedStateOf { … }` must re-read the delegate: its
        // value changes over time and is never written; a `lazy { … }`
        // delegate caches internally, so read-through only costs a method
        // call. Bound as an immutable val — the delegate reference itself
        // does not change — so a nested lambda captures it by value; `var`
        // additionally uses it for setValue write-through (see
        // storeCombinedToTarget). The plain name binds the delegate too, for
        // the paths that resolve the name without the delegate read.
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
            // The declared type is the initializer's expectation, through
            // generic factories too (`val m: Map<String, Long> = mapOf("a" to 1)`
            // makes the `1` a `Long`).
            if (p.ty) |*ty| {
                if (expr_mod.loweredOwnedLocalTypeRef(b, ty)) |lt| {
                    var owned = lt;
                    defer owned.deinit(b.allocator);
                    expr_mod.applyExpectedLiteralKinds(b, @constCast(e), owned);
                } else |_| {}
            }
            const widened: ?Expr = if (p.ty) |*ty| widenNumericLiteral(e, ty) else null;
            // A type-annotated initializer puts its declared type in
            // tail position so a reified inline call (`val u: User =
            // resp.body()`) can infer its type argument.
            const prev = b.pushExpected(p.ty);
            const r = try lowerExpr(b, if (widened) |*w| w else e);
            b.restoreExpected(prev);
            break :blk r;
        },
        false => try b.emitConst(.Unit),
    };
    // Allocate a "home" register and Move the init value
    // into it for `var`, or for `val` declared without an
    // initializer (deferred init — multiple branches assign
    // before the first read). This gives reads through the
    // home reg slot semantics under the flat block IR.
    // For a `val foo = expr` the binding is fixed at decl
    // time and can skip the slot.
    // Track `: Any` annotations so subsequent `==` against
    // this var routes through the boxed-equality path.
    if (p.ty) |ty| {
        if (std.mem.eql(u8, ty.name.name, "Any")) {
            try b.markAnyTyped(p.name.name);
        }
    }
    // Record the local's declared type (or its initializer expression when
    // un-annotated) so inline-overload receiver narrowing can type a plain
    // local receiver (`val resp = client.get(url); resp.body<T>()`).
    if (p.ty) |ty| {
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
    } else if (p.init) |*e| {
        // Preserve the inferred static type of a simple receiver alias. This
        // is the type kotlinc assigns to `val outerScope = this`, and later
        // explicit-receiver extension calls need it before runtime dispatch
        // (notably to type a trailing receiver lambda correctly).
        switch (e.*) {
            .This => |t| if (t.qualifier == null) {
                if (b.enclosingRecvTy()) |ty| {
                    try b.setLocalDeclType(p.name.name, ty);
                } else if (b.ownerClass()) |owner| {
                    // Inside an ordinary member, `val self = this` is the
                    // declaring class — no extension receiver is in scope to
                    // supply it, and without this the local stayed untyped.
                    try b.setLocalDeclType(p.name.name, owner);
                }
            },
            .Path => |path| if (path.segments.len == 1) {
                if (b.localDeclType(path.segments[0].name)) |ty| {
                    try b.setLocalDeclType(p.name.name, ty);
                    if (b.localDeclNullable(path.segments[0].name)) try b.setLocalDeclNullable(p.name.name);
                }
            },
            // A cast initializer IS the local's static type: `val cont =
            // curState as CancellableContinuation<Unit>` types `cont` with
            // the full generic reference, so a member call on it reaches
            // resolution with the type arguments applicability needs.
            .As => |cast| {
                try b.setLocalDeclTypeOwned(
                    p.name.name,
                    try expr_mod.loweredOwnedLocalTypeRef(b, &cast.ty),
                );
                // `as?` yields the cast type OR null, so the local is
                // nullable; the type head is still exact, which is what a
                // member call on it needs.
                if (cast.ty.nullable or cast.safe) try b.setLocalDeclNullable(p.name.name);
            },
            // A call initializer's declared RETURN type is the local's
            // static type (`val onCancellation = clause
            // .createOnCancellationAction(...)`), the same derivation the
            // destructuring arm already trusts. Argument shapes built from
            // the local then refute inapplicable members.
            .Call => {
                const vt = runtime.envOnce("KLIO_VALTY_TRACE");
                if (try expr_mod.staticExprTypeRef(b, e)) |ct0| {
                    var ct = ct0;
                    // A star-erased RETURN-position parameter re-derives
                    // from the call's trailing lambda (recorder-level only;
                    // resolution shapes are untouched).
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
            },
            // `val clause = findClause(x) ?: continue` — the elvis arm of
            // staticExprTypeRef strips the null.
            .Binary => |bin| if (bin.op == .Elvis) {
                if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                    const was_nullable = ct.nullable;
                    try b.setLocalDeclTypeOwned(p.name.name, ct);
                    if (was_nullable) try b.setLocalDeclNullable(p.name.name);
                }
            } else {
                // A predicate operator (`a == b`, `a in xs`, `a && b`) types
                // the local `Boolean` outright.
                if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                    try b.setLocalDeclTypeOwned(p.name.name, ct);
                }
            },
            // An INDEX initializer is an operator `get` call: its resolved
            // return types the local (`val interceptor =
            // context[ContinuationInterceptor]`), including the key-solved
            // type parameter the operator arm derives.
            .Index => {
                if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                    const was_nullable = ct.nullable;
                    try b.setLocalDeclTypeOwned(p.name.name, ct);
                    if (was_nullable) try b.setLocalDeclNullable(p.name.name);
                }
            },
            // An object literal's denotable type is its single supertype,
            // and that supertype is the only place its type ARGUMENTS are
            // written (`object : KSerializer<Int> by …`). Recording the head
            // alone left a call taking `KSerializer<T>` with nothing to
            // solve a reified `T` from.
            .ObjectExpr => {
                if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                    try b.setLocalDeclTypeOwned(p.name.name, ct);
                }
            },
            // Shapes that name their own type: a cast states it, `this` is the
            // enclosing class, `!x` is Boolean and `-x` keeps its operand's
            // type. Each of these left the local untyped, so every member call
            // on it had to resolve by name at run time.
            .Unary, .If, .When => {
                if (try expr_mod.staticExprTypeRef(b, e)) |ct| {
                    const was_nullable = ct.nullable;
                    try b.setLocalDeclTypeOwned(p.name.name, ct);
                    if (was_nullable) try b.setLocalDeclNullable(p.name.name);
                }
            },
            else => {},
        }
        // Literal initializers are recorded too: a call site uses them as
        // definite NON-callable evidence (`var nodeIndex = 0` beside
        // `fun nodeIndex(...)` — the call resolves to the function).
        switch (e.*) {
            // A property read is recorded too: `val node = coord.layoutNode`
            // lends the property's registered type head to the local, which
            // the declared-type channel then reads back.
            // A BINARY init carries the numeric-promotion evidence the
            // deriver's arm answers (`val lineSeparators = (n - 1) / perLine`).
            .Call, .IntLit, .FloatLit, .BoolLit, .CharLit, .StringTemplate, .Binary, .Unary, .Postfix => try b.setLocalInitExprAt(p.name.name, e, p.name.span),
            // A property read and an INDEXED read both carry a static type of
            // their own: `val held = row[1]` is `Row.get`'s return type.
            .Member, .Index, .Path => if (!std.mem.eql(u8, runtime.envOnce("KLIO_MEMBER_INIT") orelse "1", "0"))
                try b.setLocalInitExprAt(p.name.name, e, p.name.span),
            // Recorded as an init too: a single-supertype literal's denotable
            // type is that supertype, which the deriver's ObjectExpr arm
            // answers for the local's reads.
            .ObjectExpr => {
                try b.markObjectInitLocal(p.name.name);
                try b.setLocalInitExprAt(p.name.name, e, p.name.span);
            },
            else => {},
        }
        // A literal init is definite NON-callable evidence that must also
        // survive into nested lambda bodies: a captured `var key = 0` does
        // not shadow the `key(...) {}` composable for a CALL.
        switch (e.*) {
            .IntLit, .FloatLit, .BoolLit, .CharLit, .StringTemplate => try b.markNonFnLocal(p.name.name),
            .Lambda, .AnonFun => b.clearNonFnLocal(p.name.name),
            else => {
                // Any initializer whose static TYPE is a class with no
                // `invoke` is non-callable evidence too, whatever its shape:
                // `val flow = flowOf(1, 2)` beside the `flow { … }` builder
                // must leave the builder reachable, including from a nested
                // lambda that captures the local. Gated on a same-named
                // bare-call candidate existing, so the derivation runs only
                // where the answer can matter.
                if (b.module.hasBareCallCandidate(p.name.name, p.name.span.file) and
                    try initTypeIsNonInvokable(b, e))
                {
                    try b.markNonFnLocal(p.name.name);
                }
            },
        }
    }
    // Keep the source annotation for later plain assignments to this name:
    // the value of `h = { ... }` lowers under the declared type exactly as
    // the initializer did (a `Ctx.() -> R` receiver lambda keeps its
    // receiver context on reassignment).
    if (p.ty) |*ty| b.setLocalAstTy(p.name.name, ty);
    if (b.isBoxed(p.name.name)) {
        // Captured `var` — box into a shared cell so writes
        // from a nested closure / coroutine are visible
        // here (Kotlin `Ref` semantics).
        const home = b.allocReg();
        try b.push(.{ .MakeCell = .{ .dst = home, .src = init } });
        try b.setMutableHome(p.name.name, home);
        try b.markMutable(p.name.name);
        try b.bind(p.name.name, home);
    } else if (p.mutable or p.init == null) {
        const home = b.allocReg();
        try b.push(.{ .Move = .{ .dst = home, .src = init } });
        try b.setMutableHome(p.name.name, home);
        if (p.mutable) {
            try b.markMutable(p.name.name);
        }
        try b.bind(p.name.name, home);
    } else {
        // `val x = y` where `y` is a reassignable var reads `y`'s home register
        // directly; a later write to `y` (`y = …`) Moves into that home and
        // would alias into `x`. Snapshot the value into a fresh register so the
        // val is an independent binding (Kotlin: a val captures the value, not
        // the variable).
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

fn lowerLocalFnDecl(b: *FuncBuilder, f: *const ast.Function) Allocator.Error!?Reg {
    // Local fn: lower as a closure whose body captures the
    // enclosing scope's visible names. Bound to its
    // declared name so subsequent calls resolve to the
    // closure Value. Equivalent to `val name = { ... }`.
    // Both block-body (`fun foo() { ... }`) and
    // expression-body (`fun foo() = expr`) forms map to a
    // synthetic Block carrying the expression as its only
    // statement.
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
        // A recursive local EXTENSION binds its own name before the body
        // lowers, so `(this - 1).fact()` inside it resolves to the in-scope
        // closure (which takes the receiver as its leading parameter) instead
        // of falling through to a runtime member lookup on `Int`.
        if (self_cell != null and f.receiver_type != null) {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
            try b.markLocalFn(f.name.name);
            try b.markLocalExtFn(f.name.name, @intCast(@min(f.params.len - recv_off, 127)));
        }
        // Same-named sibling declarations are OVERLOADS, not rebindings.
        // Register this declaration's signature and bind its mangled
        // sibling name to a dedicated cell BEFORE the body lowers, so a
        // call inside any sibling's body (including this one) selects
        // the applicable overload — the second `assertCompareResult`
        // must reach the first, not recurse into itself through the
        // shared plain-name self-cell. The closure lands in the cell
        // after it is built, below.
        var mangled_name: []const u8 = undefined;
        const mangled_cell: Reg = mangled_blk: {
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
            // ($composer, $changed) pair the CALL SITE never writes: the
            // pair never counts toward the required arity, or a 3-arg call
            // to `fun Composition(a, b, c)` judged inapplicable and the
            // classifier arms constructed the pack's `interface Composition`.
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
            mangled_name = mangled;
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
                // An unannotated EXPRESSION body's return derives at the
                // declaration under the params' declared types, so a
                // val-init calling the local fn types
                // (`fun twoDigitNumber(index: Int) = (s[index]-'0')*10+...`
                // records Int for `val month = twoDigitNumber(i + 1)`).
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
                        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
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
            break :mangled_blk home;
        };
        const outer_names: StringSet = try b.visibleNames();
        const inherited_rlp: StringSet = try b.receiverLambdaParamNames();
        try b.stashRecvHeadsForLambda();
        var outer_boxed = try b.boxedVarsSnapshot();
        defer outer_boxed.deinit();
        // A local *extension* function (`fun List<T>.mid() =
        // …`) binds its receiver as the implicit first `this`
        // param, so the body's bare member refs (`sorted()`,
        // `size`) resolve. Call sites prepend the receiver.
        const is_ext = f.receiver_type != null;
        var param_idents = try b.allocator.alloc(ast.Ident, f.params.len + @intFromBool(is_ext));
        defer b.allocator.free(param_idents);
        const param_tys = try b.allocator.alloc(?ast.TypeRef, f.params.len + @intFromBool(is_ext));
        defer b.allocator.free(param_tys);
        {
            const offset = @intFromBool(is_ext);
            if (is_ext) {
                param_idents[0] = .{ .name = "this", .span = dummy_span };
                param_tys[0] = f.receiver_type;
            }
            for (f.params, 0..) |p, i| {
                param_idents[offset + i] = p.name;
                param_tys[offset + i] = p.ty;
            }
        }
        const tailrec_self: ?[]const u8 = if (f.is_tailrec) f.name.name else null;
        const enclosing_owner: ?lambda_body.EnclosingOwner = if (b.ownerClass()) |o|
            .{ .class = o, .members = try b.enclosingMembersForChild() }
        else
            null;
        const inherited_lef = try b.localExtFnNames();
        const inherited_erp = try b.erasedRecvParamNames();
        const encl_recv = b.capturesThisSlot() or
            (!b.this_is_plain_param and b.resolve("this") != null) or
            b.ownerClass() != null or b.isParamThunk() or b.recvTy() != null;
        // A local contextual function binds its context parameters in the
        // body; stash them for the shared lambda-body lowering to consume.
        if (f.context_params.len != 0) {
            b.module.has_context_decls = true;
            b.module.pending_ctx = .{ .params = f.context_params, .type_params = f.type_params };
        }
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
        b.module.pending_lambda_type_param_bound_refs = try b.typeParamBoundRefsSlice();
        b.module.pending_lambda_ctx_fn_shapes = try b.contextFnShapesSlice();
        // The receiver type in scope inside this body: a local EXTENSION fn's
        // own declared receiver (innermost, wins bare-call disambiguation —
        // `fun MockViewValidator.value() { Text(…) }` must pick the
        // MockViewValidator ext over a same-named top-level fn), else the
        // enclosing receiver, exactly as a receiver lambda carries it.
        b.module.pending_lambda_receiver_tower = try b.collectReceiverTowerLabeled(
            b.allocator,
            if (f.receiver_type) |r| r.name.name else null,
            if (f.receiver_type != null) f.name.name else null,
        );
        // The local extension fn's receiver answers to `this@<name>` exactly
        // as a top-level extension's does; the body binds the label so
        // nested scopes (and the tower emission path) reach the value.
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
        // A local `fun` with a BLOCK body returns Unit on fall-through,
        // never its tail statement's value (an expression body keeps the
        // expression as the return — it lowered to a single-statement
        // synthetic block above). Mirrors the top-level/member block-body
        // rule in `lowerFunctionBodyWithImplicitOwnerEnclosing`.
        b.module.pending_lambda_fn_block_body = f.body != null and f.body.? == .Block;
        // The body (and any lambda nested in it) must route a bare
        // self-reference through the mangled cell: the plain-name slot is
        // rebound by a later same-named sibling declaration, so a self
        // re-invoke captured by name would run the sibling.
        b.module.pending_lambda_self_fn = .{ .name = f.name.name, .mangled = mangled_name };
        // Non-callable-local evidence flows into the body.
        b.module.pending_lambda_nonfn_locals = try b.nonFnLocalNames();
        // The enclosing locals' declared types cross into the local fn's
        // body exactly as they cross into a lambda's — `isoString` (an
        // annotated fn param) read inside a local `parseFailure` lowered
        // untyped without this. Derived-init locals resolve HERE, the only
        // scope their initializers were written in.
        b.module.pending_lambda_local_decl_types = try b.localDeclTypesSnapshot();
        if (b.module.pending_lambda_local_decl_types) |*locals| {
            var init_it = b.localInitExprIterator();
            while (init_it.next()) |e| {
                if (locals.types.contains(e.key_ptr.*)) continue;
                const derived = expr_mod.staticExprTypeRef(b, e.value_ptr.*) catch null;
                if (derived) |ty| try locals.types.put(e.key_ptr.*, ty);
            }
        }
        // Vararg param names: the body registers those as the materialized
        // array head rather than the annotated element type.
        var vararg_names: std.ArrayList([]const u8) = .empty;
        defer vararg_names.deinit(b.allocator);
        for (f.params) |p| {
            if (p.is_vararg) try vararg_names.append(b.allocator, p.name.name);
        }
        b.module.pending_lambda_vararg_params = if (vararg_names.items.len != 0) vararg_names.items else null;
        defer b.module.pending_lambda_vararg_params = null;
        // A bare `return` in an argument lambda nested in THIS local fn
        // returns from the local fn, not from the enclosing real function.
        // Push the local fn's name so such returns stamp it as their label,
        // and (below) name the body func so the runtime unwind stops here.
        const prev_real_fn = build.pushCurrentRealFn(f.name.name);
        defer build.popCurrentRealFn(prev_real_fn);
        const lowered = try lowerLambdaBodyCapturingKindWith(
            b.module,
            param_idents,
            param_tys,
            &body,
            outer_names,
            true,
            &outer_boxed,
            tailrec_self,
            true,
            encl_recv,
            inherited_rlp,
            inherited_lef,
            inherited_erp,
            &b.local_fn_overloads,
            enclosing_owner,
        );
        const body_func = lowered.func;
        // The lambda-body lowering builds params with `is_vararg = false`
        // (lambdas cannot declare varargs) — a local FUNCTION can, and the
        // closure invocation's vararg packing keys on the flag. Stamp the
        // declared flags back onto the lowered body func.
        {
            const offset = @intFromBool(is_ext);
            if (b.module.funcByIdMut(body_func)) |bf| {
                for (f.params, 0..) |p, i| {
                    const pi = offset + i;
                    if (pi < bf.params.len) bf.params[pi].is_vararg = p.is_vararg;
                }
                // Carry the declared name so `frameMatchesLabel` stops a
                // nested lambda's non-local return at this frame.
                bf.name = f.name.name;
                bf.lambda_receiver_shape_known = true;
            }
        }
        const captured_names = lowered.captures;
        const captures = try b.allocator.alloc(Reg, captured_names.len);
        for (captured_names, captures) |n, *slot| slot.* = try resolveCapture(b, n);
        var param_names = try b.allocator.alloc([]const u8, f.params.len + @intFromBool(is_ext));
        {
            const offset = @intFromBool(is_ext);
            if (is_ext) param_names[0] = "this";
            for (f.params, 0..) |p, i| param_names[offset + i] = p.name.name;
        }
        try registerLocalFnDefaults(b, f, is_ext, param_names, body_func);
        const dst = b.allocReg();
        try b.push(.{ .AstLambda = .{
            .dst = dst,
            .params = param_names,
            .body_ast = body,
            .captures = captures,
            .captured_names = captured_names,
            .absorb_return = true,
            .body_func = body_func,
        } });
        // A same-named local PROPERTY owns the plain-name binding: the fun
        // is reachable through its mangled overload cell and the overload
        // registry, while bare `seen` reads stay on the var (Kotlin resolves
        // the bare reference to the property; only a call picks the fun).
        const name_is_property = self_cell == null and b.mutableHome(f.name.name) != null and
            !b.isLocalFn(f.name.name);
        if (self_cell) |home| {
            try b.push(.{ .CellSet = .{ .cell = home, .value = dst } });
        } else if (!name_is_property) {
            try b.bind(f.name.name, dst);
        }
        if (!name_is_property) try b.markLocalFn(f.name.name);
        if (is_ext and !name_is_property) {
            const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name.name, "this")) 1 else 0;
            try b.markLocalExtFn(f.name.name, @intCast(@min(f.params.len - recv_off, 127)));
        }
        // Record positional parameter type names (drop a leading `this`
        // receiver) so a literal argument coerces to a numeric primitive
        // parameter at the call site.
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
        // The overload's mangled sibling binding (registered above, before
        // the body lowered) receives the built closure.
        try b.push(.{ .CellSet = .{ .cell = mangled_cell, .value = dst } });
    }
    return null;
}

// A local function that calls itself is desugared like
// `var name = null; name = { … name(…) … }`: a shared cell is created
// first so the body can capture it and the closure stores itself into
// it once built. This is the same boxed-self-reference path a recursive
// `lateinit var f = { … f(…) … }` already uses. A cell pre-hoisted by
// `lower_block` (so sibling local fns can capture each other) is reused.
fn localFnSelfCell(
    b: *FuncBuilder,
    f: *const ast.Function,
    body: *const ast.Block,
) Allocator.Error!?Reg {
    var self_refs = StringSet.init(b.allocator);
    defer self_refs.deinit();
    // A local EXTENSION function refers to itself in member-call position
    // (`fun Int.fact(): Int = ... (this - 1).fact()`), which the bare-identifier
    // scan never reaches — collect member-call names into the same set so the
    // recursion cell gets built.
    var call_names = StringSet.init(b.allocator);
    defer call_names.deinit();
    for (body.stmts) |*s| try ast_scan.collectIdentsAndCallNamesStmt(s, &self_refs, &call_names);
    if (f.receiver_type != null and call_names.contains(f.name.name)) {
        try self_refs.put(f.name.name, {});
    }
    // Reuse an existing mutable home only when it belongs to a previous
    // LOCAL FN of the name (a redeclaration/recursion cell). A same-named
    // local PROPERTY keeps its own cell: `var seen = ...; fun seen(x) { seen
    // = x }` assigns the var from the fun body, and storing the closure into
    // the var's cell would clobber the property every bare `seen` read.
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

// Per-param defaults: lower each default expression as a thunk binding
// the lowered param prefix (so `b = a + 1` can read an earlier param)
// and register it under the body FuncId. The Vm pads missing trailing
// args from these the same way it does for top-level functions.
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
    // `obj?.items[i] = v` — null-guard the outer Index
    // assignment when the receiver chain is a safe-Member.
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
    // `obj?.field = v` (or compound `?.field += v`):
    //   if obj is null → skip the assignment entirely.
    //   otherwise → fall through to the regular non-safe
    //              assign path with the safe flag cleared.
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
    // Synthesize an equivalent non-safe assign and recurse
    // through Stmt::Assign so compound semantics, setters,
    // and class property setters reuse the existing path.
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

/// Whether the CURRENT `this` is an inline-splice receiver whose type is
/// known, is not the enclosing member's owner class, and does not declare
/// `name` as a property — i.e. a bare write here must NOT SetField on it.
/// Unknown shapes answer false (the SetField arm keeps its behavior).
fn spliceReceiverHidesMember(b: *FuncBuilder, name: []const u8) bool {
    const recv = b.spliceRecvTy() orelse b.spliceHintRecv() orelse return false;
    var head = std.mem.trimEnd(u8, recv, "?");
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
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

/// Heads that carry an element type for `+=` / `-=` purposes.
fn containerHead(name: []const u8) bool {
    const heads = [_][]const u8{
        "List",           "MutableList",  "ArrayList",       "Collection",
        "MutableCollection", "Iterable",  "Set",             "MutableSet",
        "HashSet",        "LinkedHashSet", "Sequence",       "Array",
    };
    for (heads) |h| if (std.mem.eql(u8, name, h)) return true;
    return false;
}

/// `xs += y` where `xs: MutableList<List<T>>` and `y: List<T>` appends ONE
/// element: `plusAssign(element: T)` beats `plusAssign(elements: Iterable<T>)`
/// because a `List<T>` is not an `Iterable<List<T>>`. The runtime decides on
/// the argument's TAG alone and would flatten, so when the receiver's declared
/// ELEMENT type is itself the container being added, name the single-element
/// member directly. `y`'s own element type settles the ambiguity: a
/// `List<List<T>>` really is the iterable form and keeps flattening.
/// The declared type (with arguments) of a compound-assignment target: a
/// local's annotation, or the owning class's property declaration when the
/// target names a member bare or through an explicit receiver.
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
    // The receiver's DECLARED type, with its arguments: a local's annotation,
    // or the owning class's property declaration for `field += y` /
    // `this.field += y`. The static deriver answers heads without arguments
    // for a member, which is exactly the fact this rule needs.
    const decl_ty: ast.TypeRef = (declaredTargetTypeRef(b, target) orelse return null);
    if (decl_ty.type_args.len != 1 or decl_ty.type_args[0].is_star) return null;
    if (!containerHead(expr_mod.typeHead(decl_ty.name.name))) return null;
    const elem_head = expr_mod.typeHead(decl_ty.type_args[0].ty.name.name);
    if (!containerHead(elem_head)) return null;

    var val_ty = (expr_mod.staticExprTypeRef(b, value) catch null) orelse return null;
    defer val_ty.deinit(b.allocator);
    const val_head = expr_mod.typeHead(std.mem.trimEnd(u8, val_ty.name, "?"));
    if (!containerHead(val_head)) return null;
    // A value whose OWN element type is the receiver's element type is the
    // iterable form (`MutableList<List<T>> += listOf(listOf(t))`).
    if (val_ty.args.len == 1 and
        std.mem.eql(u8, expr_mod.typeHead(std.mem.trimEnd(u8, val_ty.args[0].name, "?")), elem_head)) return null;
    return member;
}

/// Whether an initializer's static type is a class that can never take a
/// call: it declares no `invoke` member and no `invoke` extension applies.
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
    // A plain assignment of a LAMBDA lowers under the TARGET's declared
    // type, exactly as the declaration's initializer did — a receiver
    // lambda (`h = { onDraw(...) }` into a `CacheDrawScope.() -> DrawResult`
    // local or field) must keep its receiver context on reassignment.
    // Restricted to lambda values: only they consume the receiver context,
    // and the Member arm's receiver-type derivation is too costly to run
    // on every member assignment in a re-lowering pack.
    const value_is_lambda = value.* == .Lambda or value.* == .AnonFun;
    const assign_expected: ?ast.TypeRef = if (op != .Assign or !value_is_lambda) null else switch (target.*) {
        .Path => |pth| blk: {
            if (pth.segments.len != 1) break :blk null;
            if (b.localAstTy(pth.segments[0].name)) |t| break :blk t.*;
            break :blk null;
        },
        .Member => |m| blk: {
            var rty = (expr_mod.staticExprTypeRef(b, m.receiver) catch null) orelse break :blk null;
            defer rty.deinit(b.allocator);
            var head = std.mem.trimEnd(u8, rty.name, "?");
            if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
            const prop = @import("inline_state.zig").memberPropAst(head, m.name.name) orelse break :blk null;
            if (prop.ty) |t| break :blk t;
            break :blk null;
        },
        else => null,
    };
    const prev_expected = if (assign_expected != null) b.pushExpected(assign_expected) else null;
    const v = try lowerExpr(b, value);
    if (assign_expected != null) b.restoreExpected(prev_expected);
    // `xs += y` where the DECLARED element type is itself the container being
    // added is a single-element `add`, not a flattening `addAll`. Every route
    // below (the `<op>Assign` member call, `CompoundField`, the compound
    // `BinOp`) decides on the argument's runtime TAG alone, so settle it here
    // where the declared types are still in hand.
    if (op == .Add or op == .Sub) {
        if (try compoundSingleElementMember(b, target, value, op)) |single| {
            const cur = try lowerExpr(b, target);
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
            return null;
        }
    }
    // Compound assigns first try `<op>Assign` as a member
    // call on the target — covers user types declaring
    // `operator fun plusAssign(...)` and built-in mutable
    // collections (MutableList += elem). When the call
    // raises (no method, immutable target), fall through
    // to the rebind path below. Today this fires only
    // when the target is a Path-bound local — Member /
    // Index targets need their own routing.
    // Only attempt `plusAssign`-style member dispatch when the
    // target is NOT a mutable local Path. For a `var` local the
    // primitive rebind path below is what Kotlin actually does
    // (Int has no plusAssign). For a `val` Path the value's type
    // declares plusAssign (operator on a class, or built-in
    // collection mutation), so CallMember is correct.
    // The plusAssign / minusAssign-style member dispatch only
    // fires for a Path target naming a `val` LOCAL (e.g.
    // `val h = Histogram(); h += w` or `val xs = mutableListOf<Int>(); xs += 1`).
    // A Path target whose name doesn't resolve locally is a
    // top-level binding; route it through the BinOp +
    // StoreGlobal path below so top-level `var` compound
    // assigns + delegated-property setters fire.
    // A boxed var or a captured outer binding is an
    // assignable variable, not a `val` whose value type
    // declares an `<op>Assign` operator. Excluding both
    // keeps a second compound-assign (after the first
    // rebinds the name to a plain reg) on the rebind path
    // instead of mis-dispatching `plusAssign` on the Int.
    // A captured outer VAL (knowsOuter, never locally bound, not boxed —
    // boxing covers every captured-and-written `var`) is also on this
    // path: `xs += y` inside a closure over `val xs = mutableListOf(..)`
    // must dispatch `xs.plusAssign(y)` on the capture. Routing it to the
    // rebind path instead loses the write — and when a same-named member
    // field exists, `storeCombinedToTarget`'s member fallback overwrites
    // THAT field with the combined value.
    // A name that is BOTH locally resolvable and known-outer is a captured
    // immutable (a lambda capturing the enclosing fn's parameter): Kotlin
    // can only mean `<op>Assign` on it — the rebind path wrote a fresh
    // value into the capture cell and the caller's map stayed empty
    // (`dest += transform(element)` inside `Flow.associateTo`'s collect).
    // A captured written `var` is boxed and stays excluded.
    const path_is_val = switch (target.*) {
        .Path => |p| p.segments.len == 1 and
            !b.isMutable(p.segments[0].name) and
            !b.isBoxed(p.segments[0].name) and
            (b.resolve(p.segments[0].name) != null or b.knowsOuter(p.segments[0].name)),
        else => false,
    };
    if (op != .Assign and path_is_val) {
        // A bare name the enclosing class declares as a MEMBER (`count++`
        // inside an anon object's method, with `override var count`) is a
        // compound on `this.count` — never an `<op>Assign` dispatch on the
        // member's VALUE (an Int has no plusAssign).
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
            return null;
        }
        const method_name = switch (op) {
            .Add => "plusAssign",
            .Sub => "minusAssign",
            .Mul => "timesAssign",
            .Div => "divAssign",
            .Rem => "remAssign",
            .Assign => unreachable,
        };
        const recv = try lowerExpr(b, target);
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
        return null;
    }
    // Compound assign to a property (`recv.field += x`). Kotlin resolves
    // this in place when the field's type carries the `<op>Assign` operator
    // (built-in mutable collections, a user `operator fun plusAssign`),
    // mutating the field value and NOT reassigning the property — so
    // `map.entries += e` dispatches `entries.plusAssign(e)` on the read-only
    // view (which throws) rather than trying to SET the read-only `entries`.
    // The current value's type is only known at runtime, so emit a single
    // `CompoundField` that reads the field, dispatches `<op>Assign` when the
    // value supports it, and otherwise falls back to read-modify-write
    // (needed for scalar properties like `obj.count += 1`).
    if (op != .Assign) {
        if (target.* == .Member and !target.Member.safe) {
            const m = target.Member;
            const recv = try lowerReceiver(b, m.receiver);
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
            return null;
        }
    }
    const combined: Reg = switch (op) {
        .Assign => v,
        .Add, .Sub, .Mul, .Div, .Rem => blk: {
            const cur0 = try lowerExpr(b, target);
            // `xs += y` / `xs -= y` on a statically broad collection
            // (`Iterable`/`Collection`) rebinds to a `List`; coerce a `Set`
            // runtime value to a list first so the `List`-returning operator
            // is dispatched (mirrors the `lowerBinary` receiver coercion).
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
            // Mark the combine step so a mutable-collection left operand can
            // mutate in place via `<op>Assign`. Only do so when the rebind is
            // NOT viable: a reassignable local (`var`/boxed) target follows
            // Kotlin's `a = a.plus(b)` form, which for a read-only-typed local
            // holding a mutable value (`var x: List = mutableListOf()`) must
            // produce a fresh list and leave the original untouched. A val /
            // member / global target cannot be rebound, so the in-place
            // operator is what Kotlin uses there.
            // A boxed name is a captured-and-written `var`: it is always
            // reassignable through its shared cell, whether or not the name
            // also `resolve`s to a reg in this frame (inside a lambda nested
            // in a property GETTER the capture is reached only through the
            // cell, so `resolve` returns null even though the write-back path
            // rebinds it fine). Treating it as a reassignable local keeps the
            // combine on Kotlin's `a = a.plus(b)` form instead of dispatching
            // the in-place `plusAssign`, which an `Int` does not declare.
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
    try storeCombinedToTarget(b, target, combined);
    return null;
}

/// Emit `delegate.setValue(null, ::prop, value)` for a `var x by D` write-through
/// (the delegate is bound under `dname`). Capture-aware resolve so the write works
/// inside a closure that captured the delegate.
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

// Route the already-combined value to the assignment target: a single
// Path name (local / cell / capture / member / global), a Member field,
// or an Index `set` call. Shared by compound-assign, prefix ++/--, and
// postfix ++/-- so the write-back decision lives in exactly one place.
pub fn storeCombinedToTarget(b: *FuncBuilder, target: *const Expr, combined: Reg) Allocator.Error!void {
    switch (target.*) {
        .Path => |p| {
            if (p.segments.len != 1) {
                try b.push(.{ .Trace = .{ .span = exprSpan(target) } });
                return;
            }
            const seg = p.segments[0].name;
            // The boxed set is computed for the whole body and carries no
            // declaration POSITION, so a name is "boxed" even at sites that
            // precede its `var`. Require the name to actually be in scope as a
            // local here — bound in this frame, or a capture from an enclosing
            // one. Without that, a bare write in a receiver lambda that merely
            // shares a name with a `var` declared FURTHER DOWN wrote that
            // local's cell instead of the receiver's property, and the later
            // declaration then overwrote it:
            //
            //     with(slot) { value = "written" }   // lost
            //     var value = "local"
            //
            // `knowsOuter` is what keeps genuine captures on the cell path: a
            // lambda nested in a property getter reaches its capture only
            // through the cell, so `resolve` is null there even though the
            // write must still go to it.
            const boxed_in_scope = b.isBoxed(seg) and
                (b.resolve(seg) != null or b.knowsOuter(seg));
            if (boxed_in_scope) {
                // A captured-and-written outer var is boxed into a shared
                // `Value.Cell` at its binding site (var decl, function /
                // lambda parameter, or inline-splice parameter), so the
                // write lands on the cell and is visible at the declaration
                // site on every closure-execution path. This subsumes the
                // former captured-outer `StoreGlobal` fallback.
                const cell = try boxedCellReg(b, seg);
                try b.push(.{ .CellSet = .{ .cell = cell, .value = combined } });
            } else if (b.mutableHome(seg)) |home| {
                try b.push(.{ .Move = .{ .dst = home, .src = combined } });
            } else if (b.resolve(seg) != null) {
                try b.rebind(seg, combined);
            } else if (b.hasOwnMember(seg) and b.resolve("this") != null and
                !spliceReceiverHidesMember(b, seg)) {
                // Method-body `this.field` write — route
                // SetField on the receiver so the bare-
                // name assign reaches the instance, not
                // a synthetic global. A private SHADOW of a
                // supertype's same-name property writes ITS OWN
                // owner-mangled cell, never the base class's.
                // NOT taken inside an inline-spliced receiver lambda
                // (`scope.apply { result = ... }`) whose receiver type
                // does not declare the member: `this` is the SPLICE
                // receiver there, and a SetField on it would invent a
                // dynamic field on the wrong object while the enclosing
                // class's property silently keeps its value. The
                // walking store below finds the right owner.
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
                // Unqualified write inside a lambda body or a
                // method/extension body whose name is not a local/
                // param/captured-outer/own-member. By Kotlin scoping
                // it is either a property of the receiver — a member,
                // or an extension-property setter (`var T.x set(…)`)
                // on the receiver's type or a supertype
                // (`receiveType = …` inside `PipelineCall.receiveNullable`)
                // — or a genuine top-level binding. Decide at runtime,
                // symmetric to the read side's LoadFromThisOrGlobal:
                // capture `this` on demand so a receiver-binding invoke
                // populates the slot, then StoreToThisOrGlobal sets the
                // receiver's property when present, else globals.
                const this_idx = try b.recordCapture("this");
                const name_c = try b.module.internConst(b.allocator, .{ .String = seg });
                expr_mod.orEmitAudit(b, "bare_name_assign", "StoreToThisOrGlobal", seg);
                try b.push(.{ .StoreToThisOrGlobal = .{
                    .this_idx = this_idx,
                    .name = name_c,
                    .value = combined,
                    // Hand over the receiver register when lowering has one:
                    // in a spliced inline body it is the only way the runtime
                    // can reach the receiver. Ownership is still checked at
                    // run time, so passing it can never capture a write the
                    // receiver does not declare.
                    .recv = b.resolve("this"),
                } });
            } else {
                // Top-level binding: route through StoreGlobal so
                // the tree-walker setter / delegate fires. A renamed
                // file-private property writes its per-file global.
                const target_name = expr_mod.filePrivatePropRename(b, seg, p.segments[0].span.file.int()) orelse seg;
                const n = try b.module.internConst(b.allocator, .{ .String = target_name });
                try b.push(.{ .StoreGlobal = .{ .name = n, .value = combined } });
            }
            // Write-through for a `var x by D` delegate: if the hidden delegate
            // binding (bound at the decl) is in scope here — directly or as a
            // captured outer inside a closure — dispatch setValue so a MutableState
            // (or any writable delegate) receives the write and it survives
            // recomposition, not just the eager-once local cache above. A stack
            // buffer avoids allocating for the common (non-delegated) case; only a
            // real match heap-dupes a stable name for resolveCapture.
            var namebuf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&namebuf, "{s}$klio_delegate", .{seg})) |dname_stack| {
                if ((b.resolve(dname_stack) != null or b.knowsOuter(dname_stack)) and
                    !b.plainShadowsDelegate(seg, dname_stack))
                {
                    const dname = try b.allocator.dupe(u8, dname_stack);
                    try emitDelegateSetValue(b, dname, seg, combined);
                }
            } else |_| {}
        },
        .Member => |m| {
            const recv = try lowerReceiver(b, m.receiver);
            // Explicit `this.x = v` where the enclosing class declares `x` as a
            // private SHADOW of a supertype's same-name stored property writes
            // ITS OWN owner-mangled cell, matching the bare-name write and read.
            const store_field_name: []const u8 = blk: {
                if (m.receiver.* != .This or m.receiver.This.qualifier != null) break :blk m.name.name;
                const oc = b.ownerClass() orelse break :blk m.name.name;
                var kb: [256]u8 = undefined;
                const probe = std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ oc, m.name.name }) catch break :blk m.name.name;
                break :blk b.module.registry.private_shadow_props.getKey(probe) orelse m.name.name;
            };
            const field = try b.module.internConst(b.allocator, .{ .String = store_field_name });
            // `super.prop = v` lowers to a SetField on `this` (super is not a
            // value), so the setter search would find the OVERRIDING setter and
            // re-enter it. Carry the writing class so the runtime starts the
            // search at its supertypes, the same way a `super.prop` read does.
            const super_owner: ?ir.ConstId = blk: {
                if (m.receiver.* != .Super) break :blk null;
                const oc = b.ownerClass() orelse break :blk null;
                break :blk try b.module.internConst(b.allocator, .{ .String = oc });
            };
            if (m.safe) {
                // `a?.b = v` stores only when the receiver is non-null
                // (dropping the store entirely lost `parent?.count++`
                // updates on every non-null parent).
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
        },
        .Index => |idx| {
            // `m[k] = v` lowers to receiver.set(k, v) so
            // map / mutable-list assignment dispatches
            // through the same call_member path that
            // handles built-in collection mutation.
            const recv = try lowerReceiver(b, idx.receiver);
            // Reserve a contiguous run of slots for keys +
            // value BEFORE lowering the key expressions,
            // since lowering each key may allocate auxiliary
            // registers (e.g. for Const literals) and we
            // need the run to stay tight so read_arg_run
            // picks up the value reg right after the keys.
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
        },
        else => {
            try b.push(.{ .Trace = .{ .span = exprSpan(target) } });
        },
    }
}

fn lowerLocalClassDecl(b: *FuncBuilder, c: *const ast.Class) Allocator.Error!?Reg {
    // Local class declaration inside a function body. Capture
    // the visible scope so the class methods can read names
    // from the enclosing fn (`val factor = 10; class Scaled { … n * factor … }`).
    var visible = try b.visibleNames();
    defer visible.deinit();
    const captured_names = try b.allocator.alloc([]const u8, visible.count());
    var it = visible.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) captured_names[i] = k.*;
    const captures = try b.allocator.alloc(Reg, captured_names.len);
    for (captured_names, captures) |n, *slot| slot.* = try resolveCapture(b, n);
    // Bind the class name to its registered `.Class` value so a `C(args)` call
    // in scope constructs the local class. Kotlin: a local class shadows a
    // same-named top-level function; without the binding the call resolved the
    // function and passed the constructor args to it. The binding also flows
    // into nested lambdas / local functions through the normal capture path.
    const dst = b.allocReg();
    try b.push(.{ .RegisterClass = .{
        .class = FF(ast.Class).fromPtr(c),
        .captured_names = captured_names,
        .captures = captures,
        .dst = dst,
    } });
    try b.bind(c.name.name, dst);
    // A nested lambda's bare `C(args)` must construct this local class
    // through the captured binding, not a same-simple-name module class.
    build.pushLocalClassName(c.name.name);
    // Lowering-time TYPING record: the local class's transitive supertype
    // chain under a function-scoped mangle, so a local initialized from
    // its constructor carries a head that proves Collection-ness to
    // extension binding (`coll.toTypedArray()`); the runtime
    // RegisterClass path stays the executor.
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
                // An empty chain still registers: the KEY's presence is the
                // typing record (a supertype-less local class's methods
                // bind through it).
                const owned = chain.toOwnedSlice(ra) catch null;
                if (owned) |sl| b.module.registry.class_super_names.put(key, sl) catch {};
            } else {
                chain.deinit(ra);
            }
            // The RESERVED-FID METHOD HEADERS: each of the local class's own
            // methods gets a bodyless header row under the mangled owner,
            // so a member call on a local-class-typed receiver binds its
            // virtual slot at lowering; the runtime resolves the slot's
            // by-name fallback to the RegisterClass-registered method.
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

/// The `provideDelegate` convention at a delegated property's creation:
/// `val x by e` first offers `e` the call `provideDelegate(thisRef, ::x)`,
/// and the delegate is its result when a member or extension operator
/// applies (a miss keeps `e`). The host serves the `$provideDelegate` name
/// with exactly that fallback, so the lowering needs no static resolution.
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

/// A destructured name binds like a local: a `var` gets a home register the
/// way `lowerPropertyDecl` gives one to `var x = …`, so `p += 1` updates the
/// slot instead of dispatching `plusAssign` on the value.
fn bindDestructured(b: *FuncBuilder, name: []const u8, value: Reg, mutable: bool) Allocator.Error!void {
    if (b.isBoxed(name)) {
        // Captured `var`: a shared cell, so writes from a nested closure or
        // coroutine are visible here.
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

fn lowerDestructuringDecl(
    b: *FuncBuilder,
    names: []const ast.Ident,
    by_name: bool,
    sources: []const ast.Ident,
    mutable: bool,
    init: *const Expr,
) Allocator.Error!?Reg {
    // `val (a, b, ...) = expr` desugars to repeated
    // `expr.componentN()` calls. `_` placeholders skip the
    // call entirely. Tree walker handles this via
    // eval_stmt; the IR's CallMember + Host dispatch covers
    // the same surface, so we lower it inline.
    const recv = try lowerExpr(b, init);
    // Each name's type is its `componentN()`'s declared return type on the
    // initializer's type, so the destructured names carry a receiver type into
    // dispatch instead of arriving untyped.
    var recv_ty = try expr_mod.staticExprTypeRef(b, init);
    defer if (recv_ty) |*t| t.deinit(b.allocator);
    // The name-based form reads each entry's property off the initializer
    // (`(val a, val n = prop) = x` is `x.a` and `x.prop`).
    if (by_name) {
        // A discarded name-based entry (`_ = prop`) still reads its
        // property: the read is the entry's effect, unlike a positional
        // `_`, which skips its `componentN` call.
        for (names, 0..) |name, i| {
            const field = try b.module.internConst(b.allocator, .{ .String = sources[i].name });
            const dst = b.allocReg();
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
            if (std.mem.eql(u8, name.name, "_")) continue;
            try bindDestructured(b, name.name, dst, mutable);
        }
        return null;
    }
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name.name, "_")) continue;
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
    // The statement is preceded by a `Trace` position marker (stack-trace
    // support); the value materializes in the following `Const`.
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
    // Trace position marker, then the const fused straight into the home
    // slot (the single-use `Const T; Move home <- T` pair coalesces at
    // `finish`).
    try testing.expect(func.blocks[0].insts[0] == .Trace);
    try testing.expect(func.blocks[0].insts.len == 2);
    try testing.expect(func.blocks[0].insts[1] == .Const);
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
    // The assignment's value fuses straight into the home register (the
    // single-use `Const T; Move home <- T` pair coalesces at `finish`).
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

/// Type names whose values are definitely not callable — a local declared
/// with one never shadows a same-named function for a CALL.
fn isDefiniteNonFnTypeName(name: []const u8) bool {
    const names = [_][]const u8{
        "Int",   "Long",   "Short",  "Byte", "Char",  "Boolean",
        "Float", "Double", "String", "UInt", "ULong", "UShort",
        "UByte", "Unit",
    };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
